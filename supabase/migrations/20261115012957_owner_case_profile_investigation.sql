begin;
-- Investigation only. No claim/proposal/link/receipt/credit/identity writer.
create index offline_car_exact_plate_candidates on private.offline_customer_car_refs(plate_key,profile_id);
create table private.visit_recovery_investigation_queries(
 query_id uuid primary key,owner_id uuid not null references auth.users(id),case_id uuid not null references private.visit_recovery_customer_requests(case_id),
 criterion_kind text not null check(criterion_kind in('registered_phone','exact_plate')),criterion_hash bytea not null check(octet_length(criterion_hash)=32),
 payload_hash bytea not null check(octet_length(payload_hash)=32),purpose text not null check(length(purpose)between 10 and 300),
 result_limit integer not null check(result_limit between 1 and 25),candidate_ids uuid[]not null check(cardinality(candidate_ids)<=25),has_more boolean not null,
 created_at timestamptz not null default clock_timestamp());
create table private.visit_recovery_investigation_detail_reads(
 request_id uuid primary key,query_id uuid not null references private.visit_recovery_investigation_queries(query_id),owner_id uuid not null references auth.users(id),
 profile_id uuid not null references private.offline_customer_profiles(profile_id),payload_hash bytea not null check(octet_length(payload_hash)=32),
 purpose text not null check(length(purpose)between 10 and 300),created_at timestamptz not null default clock_timestamp());
alter table private.visit_recovery_investigation_queries enable row level security;
alter table private.visit_recovery_investigation_detail_reads enable row level security;
revoke all on private.visit_recovery_investigation_queries,private.visit_recovery_investigation_detail_reads from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_investigation_query before update or delete on private.visit_recovery_investigation_queries for each row execute function private.immutable_visit_recovery_submission();
create trigger immutable_visit_recovery_investigation_detail before update or delete on private.visit_recovery_investigation_detail_reads for each row execute function private.immutable_visit_recovery_submission();

create function private.visit_recovery_investigation_case(p_case uuid)returns private.visit_recovery_customer_requests
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;begin
 perform private.require_offline_channel_owner();
 select *into c from private.visit_recovery_customer_requests where case_id=p_case;
 if not found then raise exception 'Review case unavailable'using errcode='42501';end if;
 -- Same real identity share locks as the accepted canonical bridge, BEFORE case
 -- row lock; never acquire canonical claim/profile/request mutexes from a reader.
 if not private.visit_recovery_case_identity_current(c)then raise exception 'Current case identity required'using errcode='55000';end if;
 select *into strict c from private.visit_recovery_customer_requests where case_id=p_case for share;
 if c.status not in('awaiting_matching','more_info')or not private.visit_recovery_case_identity_current(c)then raise exception 'Current active case required'using errcode='55000';end if;
 return c;
end$$;
create function private.visit_recovery_investigation_criterion(p_case private.visit_recovery_customer_requests,p_plate text)
returns table(criterion_kind text,criterion_key text,criterion_hash bytea)
language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if p_plate is null then
 criterion_kind:='registered_phone';select private.offline_phone_key(phone,'EG')into criterion_key from public.customers where id=p_case.requester_id;
 if criterion_key is null or extensions.digest('registered-customer-phone-v1:'||criterion_key,'sha256')is distinct from p_case.phone_hash then raise exception 'Current registered case phone required'using errcode='55000';end if;
 else
 -- EXACT canonical intake plate algorithm/limits from applied165824; no fuzzy
 -- matching, wildcard operator, new normalization guess or historical rewrite.
 if length(p_plate)>40 or p_plate~'[[:cntrl:]]'then raise exception 'Exact reception plate required'using errcode='22023';end if;
 criterion_kind:='exact_plate';criterion_key:=upper(regexp_replace(translate(trim(p_plate),'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789'),'[[:space:]-]','','g'));
 if length(criterion_key)not between 2 and 32 then raise exception 'Exact reception plate required'using errcode='22023';end if;
 end if;
 criterion_hash:=extensions.digest(criterion_kind||':'||criterion_key,'sha256');return next;
end$$;
create function private.visit_recovery_profile_matches(p_profile uuid,p_kind text,p_key text)returns boolean
language sql stable set search_path=pg_catalog as $$select case p_kind
 when'registered_phone'then exists(select 1 from private.offline_customer_contacts c where c.profile_id=p_profile and c.phone_e164=p_key)
 when'exact_plate'then exists(select 1 from private.offline_customer_car_refs c where c.profile_id=p_profile and c.plate_key=p_key)else false end$$;
create function private.visit_recovery_candidate_projection(p_profile uuid,p_requester uuid,p_detail boolean)returns jsonb
language sql stable set search_path=pg_catalog as $$
select jsonb_build_object('profile_reference',p.profile_id,'name',p.full_name,'created_at',p.created_at,
 'branch',jsonb_build_object('branch_id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en),
 'contacts',(select coalesce(jsonb_agg(jsonb_build_object('phone',x.phone_e164,'verification',x.verification)order by x.created_at,x.contact_id),'[]')from(select c.*from private.offline_customer_contacts c where c.profile_id=p.profile_id order by c.created_at,c.contact_id limit case when p_detail then 25 else 5 end)x),
 'contacts_truncated',(select count(*)>case when p_detail then 25 else 5 end from private.offline_customer_contacts c where c.profile_id=p.profile_id),
 'cars',(select coalesce(jsonb_agg(jsonb_build_object('car_reference',x.car_ref_id,'plate_number',x.plate_key,'brand',x.car_snapshot->'brand','model',x.car_snapshot->'model','year',x.car_snapshot->'year','color',x.car_snapshot->'color')order by x.created_at,x.car_ref_id),'[]')from(select c.*from private.offline_customer_car_refs c where c.profile_id=p.profile_id order by c.created_at,c.car_ref_id limit case when p_detail then 25 else 5 end)x),
 'cars_truncated',(select count(*)>case when p_detail then 25 else 5 end from private.offline_customer_car_refs c where c.profile_id=p.profile_id),
 'real_receipt_available',exists(select 1 from private.offline_customer_enrollment_receipts e where e.profile_id=p.profile_id),
 'receipt_ever_linked',exists(select 1 from private.offline_customer_enrollment_receipts e join private.offline_customer_trusted_links l on l.receipt_id=e.receipt_id where e.profile_id=p.profile_id),
 'active_profile_link',exists(select 1 from private.offline_customer_trusted_links l where l.profile_id=p.profile_id and l.revoked_at is null),
 'active_requester_link',exists(select 1 from private.offline_customer_trusted_links l where l.auth_user_id=p_requester and l.revoked_at is null),
 'independent_proof_required',true,'candidate_is_identity_proof',false,'proposal_enabled',false,'linking_enabled',false)
from private.offline_customer_profiles p join public.business_branches b on b.branch_id=p.created_branch_id where p.profile_id=p_profile;
$$;

create function private.search_visit_recovery_candidates(p_query uuid,p_case uuid,p_purpose text,p_plate text default null,p_limit integer default 10)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;c private.visit_recovery_customer_requests;k record;prior private.visit_recovery_investigation_queries;hash bytea;ids uuid[];extra uuid[];items jsonb;more boolean;begin
 if p_query is null or p_case is null or p_limit is null or p_limit not between 1 and 25 or length(trim(coalesce(p_purpose,'')))not between 10 and 300 then raise exception 'Stable case investigation and explicit purpose required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Investigation requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-investigation:'||p_query::text,0));
 actor:=private.require_offline_channel_owner();c:=private.visit_recovery_investigation_case(p_case);
 select *into strict k from private.visit_recovery_investigation_criterion(c,p_plate);
 hash:=extensions.digest(jsonb_build_object('case_id',p_case,'criterion',encode(k.criterion_hash,'hex'),'purpose',trim(p_purpose),'limit',p_limit)::text,'sha256');
 select *into prior from private.visit_recovery_investigation_queries where query_id=p_query;
 if found then
 if prior.owner_id<>actor then raise exception 'Own investigation unavailable'using errcode='42501';end if;
 if prior.payload_hash is distinct from hash then raise exception 'Investigation identity changed'using errcode='22023';end if;
 ids:=prior.candidate_ids;more:=prior.has_more;
 else
 select coalesce(array_agg(profile_id order by created_at desc,profile_id desc),'{}'::uuid[])into extra from(
 select p.profile_id,p.created_at from private.offline_customer_profiles p join(
 select contact.profile_id from private.offline_customer_contacts contact where k.criterion_kind='registered_phone'and contact.phone_e164=k.criterion_key
 union select car.profile_id from private.offline_customer_car_refs car where k.criterion_kind='exact_plate'and car.plate_key=k.criterion_key)matched on matched.profile_id=p.profile_id order by p.created_at desc,p.profile_id desc limit p_limit+1)bounded;
 more:=cardinality(extra)>p_limit;ids:=extra[1:p_limit];
 insert into private.visit_recovery_investigation_queries(query_id,owner_id,case_id,criterion_kind,criterion_hash,payload_hash,purpose,result_limit,candidate_ids,has_more)
 values(p_query,actor,p_case,k.criterion_kind,k.criterion_hash,hash,trim(p_purpose),p_limit,ids,more)returning *into prior;
 end if;
 select coalesce(jsonb_agg(private.visit_recovery_candidate_projection(id,c.requester_id,false)order by ord),'[]')into items from unnest(ids)with ordinality selected(id,ord)
 where private.visit_recovery_profile_matches(id,k.criterion_kind,k.criterion_key);
 -- Recheck real role/session and immutable case identity at the return boundary.
 perform private.require_offline_channel_owner();perform private.visit_recovery_investigation_case(p_case);
 return jsonb_build_object('query_id',p_query,'case_id',p_case,'searched_at',prior.created_at,'checked_at',clock_timestamp(),'criterion_kind',k.criterion_kind,
 'candidate_count',jsonb_array_length(items),'candidates',items,'has_more',more,'limit',p_limit,'candidate_is_identity_proof',false,'proposal_enabled',false,'linking_enabled',false);
end$$;

create function private.get_visit_recovery_candidate(p_request uuid,p_query uuid,p_profile uuid,p_purpose text,p_plate text default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;q private.visit_recovery_investigation_queries;c private.visit_recovery_customer_requests;k record;prior private.visit_recovery_investigation_detail_reads;hash bytea;item jsonb;begin
 if p_request is null or p_query is null or p_profile is null or length(trim(coalesce(p_purpose,'')))not between 10 and 300 then raise exception 'Exact investigation/detail purpose required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Investigation requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-investigation-detail:'||p_request::text,0));actor:=private.require_offline_channel_owner();
 select *into q from private.visit_recovery_investigation_queries where query_id=p_query and owner_id=actor;
 if not found or not(p_profile=any(q.candidate_ids))then raise exception 'Recorded case candidate unavailable'using errcode='42501';end if;
 c:=private.visit_recovery_investigation_case(q.case_id);select *into strict k from private.visit_recovery_investigation_criterion(c,p_plate);
 if k.criterion_hash is distinct from q.criterion_hash or not private.visit_recovery_profile_matches(p_profile,k.criterion_kind,k.criterion_key)then raise exception 'Recorded case candidate unavailable'using errcode='42501';end if;
 hash:=extensions.digest(jsonb_build_object('query_id',p_query,'profile_id',p_profile,'purpose',trim(p_purpose),'criterion',encode(k.criterion_hash,'hex'))::text,'sha256');
 select *into prior from private.visit_recovery_investigation_detail_reads where request_id=p_request;
 if found then
 if prior.owner_id<>actor then raise exception 'Own detail receipt unavailable'using errcode='42501';end if;
 if prior.payload_hash is distinct from hash then raise exception 'Detail request identity changed'using errcode='22023';end if;
 else insert into private.visit_recovery_investigation_detail_reads(request_id,query_id,owner_id,profile_id,payload_hash,purpose)values(p_request,p_query,actor,p_profile,hash,trim(p_purpose));end if;
 -- Scope predicate and whitelisted projection share ONE RC statement snapshot.
 select private.visit_recovery_candidate_projection(p_profile,c.requester_id,true)into item
 where private.visit_recovery_profile_matches(p_profile,k.criterion_kind,k.criterion_key);
 if item is null then raise exception 'Recorded case candidate unavailable'using errcode='42501';end if;
 perform private.require_offline_channel_owner();perform private.visit_recovery_investigation_case(q.case_id);
 return jsonb_build_object('request_id',p_request,'query_id',p_query,'case_id',q.case_id,'checked_at',clock_timestamp(),'candidate',item,'candidate_is_identity_proof',false,'proposal_enabled',false,'linking_enabled',false);
end$$;
revoke all on function private.visit_recovery_investigation_case(uuid),private.visit_recovery_investigation_criterion(private.visit_recovery_customer_requests,text),private.visit_recovery_profile_matches(uuid,text,text),private.visit_recovery_candidate_projection(uuid,uuid,boolean),private.search_visit_recovery_candidates(uuid,uuid,text,text,integer),private.get_visit_recovery_candidate(uuid,uuid,uuid,text,text)from public,anon,authenticated,service_role;
grant execute on function private.search_visit_recovery_candidates(uuid,uuid,text,text,integer),private.get_visit_recovery_candidate(uuid,uuid,uuid,text,text)to authenticated;
create function public.search_visit_recovery_candidates(p_query uuid,p_case uuid,p_purpose text,p_plate text default null,p_limit integer default 10)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.search_visit_recovery_candidates(p_query,p_case,p_purpose,p_plate,p_limit)$$;
create function public.get_visit_recovery_candidate(p_request uuid,p_query uuid,p_profile uuid,p_purpose text,p_plate text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_visit_recovery_candidate(p_request,p_query,p_profile,p_purpose,p_plate)$$;
revoke all on function public.search_visit_recovery_candidates(uuid,uuid,text,text,integer),public.get_visit_recovery_candidate(uuid,uuid,uuid,text,text)from public,anon,service_role;
grant execute on function public.search_visit_recovery_candidates(uuid,uuid,text,text,integer),public.get_visit_recovery_candidate(uuid,uuid,uuid,text,text)to authenticated;
notify pgrst,'reload schema';
commit;
