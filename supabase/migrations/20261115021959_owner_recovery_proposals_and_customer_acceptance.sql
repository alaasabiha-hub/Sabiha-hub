begin;
-- Selection and consent adapter only. EXISTING canonical creator/bridge/reviewer
-- remains authoritative; never change auth.uid/JWT, identities or credit owners.
create table private.visit_recovery_owner_proposals(
 proposal_id uuid primary key,owner_id uuid not null references auth.users(id),query_id uuid not null references private.visit_recovery_investigation_queries(query_id),
 case_id uuid not null references private.visit_recovery_customer_requests(case_id),profile_id uuid not null references private.offline_customer_profiles(profile_id),
 receipt_id uuid not null references private.offline_customer_enrollment_receipts(receipt_id),case_email_hash bytea not null,case_phone_hash bytea not null,case_confirmed_at timestamptz not null,contact_hash bytea not null,
 evidence_type text not null check(evidence_type in('in_person_original_service_documents','in_person_independent_continuity_witness')),reason text not null check(length(reason)between 10 and 500),
 payload_hash bytea not null,consent_snapshot jsonb not null,created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default(clock_timestamp()+interval'24 hours'));
create index recovery_proposals_case on private.visit_recovery_owner_proposals(case_id,created_at desc);
create table private.visit_recovery_proposal_closures(proposal_id uuid primary key,owner_id uuid not null references auth.users(id),closed_at timestamptz not null default clock_timestamp());
create table private.visit_recovery_proposal_acceptances(
 request_id uuid primary key,actor_id uuid not null references public.customers(id),proposal_id uuid not null unique references private.visit_recovery_owner_proposals(proposal_id),
 payload_hash bytea not null,consent jsonb not null,claim_id uuid not null unique references private.offline_claim_requests(request_id),attachment_id uuid unique references private.visit_recovery_attachment_requests(request_id),result jsonb not null,created_at timestamptz not null default clock_timestamp());
create table private.visit_recovery_acceptance_closures(request_id uuid primary key,actor_id uuid not null references public.customers(id),closed_at timestamptz not null default clock_timestamp());
do $$declare name text;begin foreach name in array array['visit_recovery_owner_proposals','visit_recovery_proposal_closures','visit_recovery_proposal_acceptances','visit_recovery_acceptance_closures']loop
 execute format('alter table private.%I enable row level security',name);execute format('revoke all on private.%I from public,anon,authenticated,service_role',name);
 execute format('create trigger immutable_%I before update or delete on private.%I for each row execute function private.immutable_visit_recovery_submission()',name,name);end loop;end$$;

create function private.visit_recovery_proposal_notice(p_language text)returns text language sql immutable set search_path=pg_catalog as $$select case p_language
 when'en'then'I accept this owner-selected file for independent identity review of my recovery request. This does not approve linking, marketing, reward spending or history access. Final owner proof review is still required.'
 when'ar'then'أوافق على مراجعة الهوية المستقلة للملف الذي اختاره المالك لطلب استعادة زياراتي. لا تعني هذه الموافقة ربط الحساب أو التسويق أو استبدال المكافآت أو الوصول للسجل. تبقى مراجعة المالك النهائية للإثبات مطلوبة.'end$$;
create function private.visit_recovery_proposal_state(p private.visit_recovery_owner_proposals)returns text language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;begin
 if exists(select 1 from private.visit_recovery_proposal_closures where proposal_id=p.proposal_id)then return'closed';end if;
 if exists(select 1 from private.visit_recovery_proposal_acceptances where proposal_id=p.proposal_id)then return(select case when result->>'state'='accepted'then'accepted'else'review_required'end from private.visit_recovery_proposal_acceptances where proposal_id=p.proposal_id);end if;
 if p.expires_at<=clock_timestamp()then return'expired';end if;
 if not exists(select 1 from public.staff_profiles s join auth.users u on u.id=s.user_id where s.user_id=p.owner_id and s.is_active and s.role='owner'and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp()))then return'unavailable';end if;
 select *into c from private.visit_recovery_customer_requests where case_id=p.case_id;
 if c.case_id is null or c.status not in('awaiting_matching','more_info')or c.email_hash is distinct from p.case_email_hash or c.phone_hash is distinct from p.case_phone_hash or c.email_confirmed_at is distinct from p.case_confirmed_at
 or not private.visit_recovery_case_identity_current(c)or private.offline_claim_contact_hash(p.profile_id)is distinct from p.contact_hash then return'unavailable';end if;
 if exists(select 1 from private.visit_recovery_case_claims where case_id=p.case_id)or exists(select 1 from private.offline_customer_trusted_links where receipt_id=p.receipt_id or(profile_id=p.profile_id and revoked_at is null)or(auth_user_id=c.requester_id and revoked_at is null))then return'unavailable';end if;
 return'open';end$$;
create function private.owner_visit_recovery_proposal_snapshot(p_proposal uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.require_offline_channel_owner();p private.visit_recovery_owner_proposals;closed private.visit_recovery_proposal_closures;begin
 select *into p from private.visit_recovery_owner_proposals where proposal_id=p_proposal;
 if found then if p.owner_id<>actor then raise exception 'Own proposal unavailable'using errcode='42501';end if;
 return jsonb_build_object('proposal_id',p_proposal,'case_id',p.case_id,'state',private.visit_recovery_proposal_state(p),'profile_reference',p.profile_id,'query_id',p.query_id,'evidence_type',p.evidence_type,'private_reason',p.reason,'created_at',p.created_at,'expires_at',p.expires_at,'link_created',false);end if;
 select *into closed from private.visit_recovery_proposal_closures where proposal_id=p_proposal;
 if found and closed.owner_id<>actor then raise exception 'Own proposal unavailable'using errcode='42501';end if;
 return jsonb_build_object('proposal_id',p_proposal,'state',case when closed.proposal_id is null then'absent'else'closed'end,'definitive_failure',closed.proposal_id is not null);
end$$;

create function private.prepare_visit_recovery_proposal(p_proposal uuid,p_query uuid,p_profile uuid,p_evidence_type text,p_reason text,p_attested boolean,p_plate text default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;q private.visit_recovery_investigation_queries;c private.visit_recovery_customer_requests;k record;p private.visit_recovery_owner_proposals;receipt uuid;hash bytea;begin
 if p_proposal is null or p_query is null or p_profile is null or p_attested is distinct from true or p_evidence_type is null or p_evidence_type not in('in_person_original_service_documents','in_person_independent_continuity_witness')or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Actual independent evidence and explicit attestation required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-proposal:'||p_proposal::text,0));actor:=private.require_offline_channel_owner();
 if exists(select 1 from private.visit_recovery_proposal_closures where proposal_id=p_proposal)then return private.owner_visit_recovery_proposal_snapshot(p_proposal);end if;
 select *into q from private.visit_recovery_investigation_queries where query_id=p_query and owner_id=actor;
 if not found or not(p_profile=any(q.candidate_ids))then raise exception 'Recorded candidate unavailable'using errcode='42501';end if;
 hash:=extensions.digest(jsonb_build_object('query',p_query,'profile',p_profile,'evidence',p_evidence_type,'reason',trim(p_reason),'attested',p_attested,'plate_input',p_plate,'criterion',encode(q.criterion_hash,'hex'))::text,'sha256');
 select *into p from private.visit_recovery_owner_proposals where proposal_id=p_proposal;
 if found then if p.owner_id<>actor then raise exception 'Own proposal unavailable'using errcode='42501';end if;if p.payload_hash is distinct from hash then raise exception 'Proposal identity changed'using errcode='22023';end if;return private.owner_visit_recovery_proposal_snapshot(p_proposal);end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-proposal-case:'||q.case_id::text,0));
 c:=private.visit_recovery_investigation_case(q.case_id);select *into strict k from private.visit_recovery_investigation_criterion(c,p_plate);
 if k.criterion_hash is distinct from q.criterion_hash or not private.visit_recovery_profile_matches(p_profile,k.criterion_kind,k.criterion_key)then raise exception 'Recorded candidate unavailable'using errcode='42501';end if;
 if exists(select 1 from private.visit_recovery_case_claims where case_id=c.case_id)or exists(select 1 from private.visit_recovery_owner_proposals existing where existing.case_id=c.case_id and private.visit_recovery_proposal_state(existing)in('open','accepted'))then raise exception 'Case already has canonical review or an open proposal'using errcode='55000';end if;
 select receipt_id into receipt from private.offline_customer_enrollment_receipts where profile_id=p_profile;
 if receipt is null or exists(select 1 from private.offline_customer_trusted_links where receipt_id=receipt or(profile_id=p_profile and revoked_at is null)or(auth_user_id=c.requester_id and revoked_at is null))then raise exception 'Independent evidence requires separate review'using errcode='55000';end if;
 insert into private.visit_recovery_owner_proposals(proposal_id,owner_id,query_id,case_id,profile_id,receipt_id,case_email_hash,case_phone_hash,case_confirmed_at,contact_hash,evidence_type,reason,payload_hash,consent_snapshot)
 values(p_proposal,actor,p_query,c.case_id,p_profile,receipt,c.email_hash,c.phone_hash,c.email_confirmed_at,private.offline_claim_contact_hash(p_profile),p_evidence_type,trim(p_reason),hash,jsonb_build_object('version','visit-recovery-proposal-v1','notice_ar',private.visit_recovery_proposal_notice('ar'),'notice_en',private.visit_recovery_proposal_notice('en'),'canonical_version','offline-claim-v1','canonical_notice_ar',private.offline_claim_notice('ar'),'canonical_notice_en',private.offline_claim_notice('en')));
 return private.owner_visit_recovery_proposal_snapshot(p_proposal);
end$$;
create function private.get_visit_recovery_proposal(p_proposal uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$begin
 if p_proposal is null then raise exception 'Exact proposal required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-proposal:'||p_proposal::text,0));return private.owner_visit_recovery_proposal_snapshot(p_proposal);end$$;
create function private.close_visit_recovery_proposal(p_proposal uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;p private.visit_recovery_owner_proposals;begin
 if p_proposal is null then raise exception 'Exact proposal required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-proposal:'||p_proposal::text,0));actor:=private.require_offline_channel_owner();
 select *into p from private.visit_recovery_owner_proposals where proposal_id=p_proposal;
 if found and p.owner_id<>actor then raise exception 'Own proposal unavailable'using errcode='42501';end if;
 if not exists(select 1 from private.visit_recovery_proposal_acceptances where proposal_id=p_proposal)then
 insert into private.visit_recovery_proposal_closures(proposal_id,owner_id)values(p_proposal,actor)on conflict do nothing;end if;
 return private.owner_visit_recovery_proposal_snapshot(p_proposal);
end$$;

create function private.get_my_visit_recovery_proposal(p_case uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare ident record;c private.visit_recovery_customer_requests;p private.visit_recovery_owner_proposals;state text;begin
 select *into strict ident from private.visit_recovery_request_identity();
 select *into c from private.visit_recovery_customer_requests where case_id=p_case and requester_id=ident.actor_id;
 if not found then raise exception 'Own recovery request unavailable'using errcode='42501';end if;
 if c.email_hash is distinct from ident.email_hash or c.phone_hash is distinct from ident.phone_hash or c.email_confirmed_at is distinct from ident.email_confirmed_at then raise exception 'Current recovery identity required'using errcode='55000';end if;
 select *into p from private.visit_recovery_owner_proposals where case_id=p_case order by created_at desc,proposal_id desc limit 1;
 if not found then return jsonb_build_object('case_id',p_case,'state','unavailable','proposal',null,'approval_required',true,'link_created',false);end if;
 state:=private.visit_recovery_proposal_state(p);
 -- No preapproval profile, receipt, old contact, name, car or owner reason.
 return jsonb_build_object('case_id',p_case,'state',state,'proposal',jsonb_build_object('proposal_id',p.proposal_id,'expires_at',p.expires_at),'consent_version',p.consent_snapshot->>'version',
 'notice_ar',p.consent_snapshot->>'notice_ar','notice_en',p.consent_snapshot->>'notice_en','canonical_consent_version',p.consent_snapshot->>'canonical_version','canonical_notice_ar',p.consent_snapshot->>'canonical_notice_ar','canonical_notice_en',p.consent_snapshot->>'canonical_notice_en',
 'acceptance_request_id',(select request_id from private.visit_recovery_proposal_acceptances where proposal_id=p.proposal_id and actor_id=ident.actor_id),
 'approval_required',true,'link_created',false);
end$$;

create function private.get_my_visit_recovery_acceptance(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;prior private.visit_recovery_proposal_acceptances;closed private.visit_recovery_acceptance_closures;begin
 if p_request is null then raise exception 'Exact request required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-accept:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-request:'||p_request::text,0));actor:=private.app_inbox_actor();
 select *into prior from private.visit_recovery_proposal_acceptances where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;return prior.result;end if;
 select *into closed from private.visit_recovery_acceptance_closures where request_id=p_request;
 if found and closed.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;
 if exists(select 1 from private.offline_claim_requests where request_id=p_request)then
 if not exists(select 1 from private.offline_claim_requests where request_id=p_request and actor_id=actor)then raise exception 'Own acceptance unavailable'using errcode='42501';end if;
 return jsonb_build_object('request_id',p_request,'state','manual_review_required','definitive_failure',false);end if;
 return jsonb_build_object('request_id',p_request,'state',case when closed.request_id is null then'absent'else'closed'end,'definitive_failure',closed.request_id is not null);
end$$;
create function private.close_my_visit_recovery_acceptance(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;prior private.visit_recovery_proposal_acceptances;closed private.visit_recovery_acceptance_closures;begin
 if p_request is null then raise exception 'Exact request required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-accept:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('offline-claim-request:'||p_request::text,0));actor:=private.app_inbox_actor();
 select *into prior from private.visit_recovery_proposal_acceptances where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;return prior.result;end if;
 select *into closed from private.visit_recovery_acceptance_closures where request_id=p_request;
 if found and closed.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;
 if exists(select 1 from private.offline_claim_requests where request_id=p_request)then
 if not exists(select 1 from private.offline_claim_requests where request_id=p_request and actor_id=actor)then raise exception 'Own acceptance unavailable'using errcode='42501';end if;
 return jsonb_build_object('request_id',p_request,'state','manual_review_required','definitive_failure',false);end if;
 if not exists(select 1 from public.customers where id=actor)then raise exception 'Own customer account required'using errcode='42501';end if;
 insert into private.visit_recovery_acceptance_closures(request_id,actor_id)values(p_request,actor)on conflict do nothing;
 return jsonb_build_object('request_id',p_request,'state','closed','definitive_failure',true);
end$$;

create function private.accept_my_visit_recovery_proposal(p_request uuid,p_proposal uuid,p_consent jsonb,p_claim_consent jsonb)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid:=auth.uid();p private.visit_recovery_owner_proposals;c private.visit_recovery_customer_requests;ident record;prior private.visit_recovery_proposal_acceptances;
 hash bytea;language_code text;claim jsonb;attached jsonb;result jsonb;actual private.offline_claim_requests;attachment uuid:=gen_random_uuid();closed private.visit_recovery_acceptance_closures;begin
 if actor is null or p_request is null or p_proposal is null then raise exception 'Actual customer and exact request required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'READ COMMITTED required'using errcode='25001';end if;
 language_code:=p_consent->>'language';
 if p_consent is null or jsonb_typeof(p_consent)<>'object'or p_consent-array['accepted','version','text','language']<>'{}'or not(p_consent@>'{"accepted":true,"version":"visit-recovery-proposal-v1"}')or language_code is null or language_code not in('ar','en')or nullif(p_consent->>'text','')is null then raise exception 'Actual frozen proposal consent required'using errcode='22023';end if;
 -- Validate canonical notice BEFORE creator call; creator independently validates
 -- this unchanged exact payload. Never synthesize the customer's consent.
 if p_claim_consent is null or jsonb_typeof(p_claim_consent)<>'object'or p_claim_consent-array['accepted','version','text','language']<>'{}'or not(p_claim_consent@>'{"accepted":true,"version":"offline-claim-v1"}')or coalesce(p_claim_consent->>'language','')not in('ar','en')or nullif(p_claim_consent->>'text','')is null then raise exception 'Actual canonical identity consent required'using errcode='22023';end if;
 hash:=extensions.digest(jsonb_build_object('proposal',p_proposal,'consent',p_consent,'canonical_consent',p_claim_consent)::text,'sha256');
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-accept:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-proposal:'||p_proposal::text,0));
 -- Canonical request BEFORE Auth/profile/identity. Do NOT call investigation_case
 -- here: its Auth/case locks would invert the accepted canonical writer order.
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-request:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-auth:'||actor::text,0));
 select *into p from private.visit_recovery_owner_proposals where proposal_id=p_proposal;
 if not found then raise exception 'Own proposal unavailable'using errcode='42501';end if;
 select *into c from private.visit_recovery_customer_requests where case_id=p.case_id and requester_id=actor;
 if not found then raise exception 'Own proposal unavailable'using errcode='42501';end if;
 if p_consent->>'text'is distinct from p.consent_snapshot->>('notice_'||language_code)or p_claim_consent->>'text'is distinct from p.consent_snapshot->>('canonical_notice_'||(p_claim_consent->>'language'))then raise exception 'Exact frozen displayed notices required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-receipt:'||p.receipt_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-claim-profile:'||p.profile_id::text,0));
 -- Same existing canonical approval/bridge contact-set freeze before Auth rows.
 lock table private.offline_customer_contacts in share mode;
 select *into strict ident from private.visit_recovery_request_identity();
 select *into prior from private.visit_recovery_proposal_acceptances where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;if prior.payload_hash is distinct from hash then raise exception 'Acceptance identity changed'using errcode='22023';end if;return prior.result;end if;
 select *into closed from private.visit_recovery_acceptance_closures where request_id=p_request;
 if found then if closed.actor_id<>actor then raise exception 'Own acceptance unavailable'using errcode='42501';end if;raise exception 'Acceptance permanently closed'using errcode='55000';end if;
 if exists(select 1 from private.offline_claim_requests where request_id=p_request)then raise exception 'Request already belongs to another canonical path'using errcode='22023';end if;
 if exists(select 1 from private.visit_recovery_proposal_acceptances where proposal_id=p_proposal)then raise exception 'Proposal already has an acceptance receipt'using errcode='55000';end if;
 if c.email_hash is distinct from ident.email_hash or c.phone_hash is distinct from ident.phone_hash or c.email_confirmed_at is distinct from ident.email_confirmed_at or private.visit_recovery_proposal_state(p)<>'open'then raise exception 'Proposal unavailable for current independent review'using errcode='55000';end if;
 -- Existing creator executes as the REAL caller (auth.uid untouched), preserving
 -- global actor/receipt quotas, one-time receipt and no automatic approval.
 claim:=private.request_offline_customer_claim(p_request,p.receipt_id,null,'lost_secret_review',p_claim_consent);
 select *into strict actual from private.offline_claim_requests where request_id=p_request and actor_id=actor;
 if actual.profile_id=p.profile_id and actual.outcome='pending_owner_review'then
 attached:=private.attach_my_visit_recovery_claim(attachment,p.case_id,p_request);
 end if;
 -- A bridge call/result alone is not a successful mapping witness. Verify the
 -- own live case, expected pending status, exact mapping and actual attachment
 -- receipt before reporting accepted or storing its foreign-key association.
 if attached#>>'{case,case_id}'=p.case_id::text
 and attached#>>'{case,status}'in('awaiting_matching','more_info')
 and exists(select 1 from private.visit_recovery_customer_requests live_case
 join private.visit_recovery_case_claims mapping on mapping.case_id=live_case.case_id
 join private.offline_claim_requests live_claim on live_claim.request_id=mapping.claim_id
 join private.visit_recovery_attachment_requests witness on witness.case_id=live_case.case_id and witness.claim_id=live_claim.request_id
 where live_case.case_id=p.case_id and live_case.requester_id=actor and live_case.status=attached#>>'{case,status}'
 and live_claim.request_id=p_request and live_claim.actor_id=actor and live_claim.profile_id=p.profile_id
 and witness.request_id=attachment and witness.actor_id=actor)then
 result:=jsonb_build_object('request_id',p_request,'proposal_id',p_proposal,'case_id',p.case_id,'state','accepted','claim_id',p_request,'canonical_status',claim->>'status','attached',true,'approval_required',true,'link_created',false);
 else
 -- Preserve ordinary failed quota/proof OR unverified bridge result. Raising
 -- here would roll back counters and permit retries. Disclose no candidate facts.
 attachment:=null;result:=jsonb_build_object('request_id',p_request,'proposal_id',p_proposal,'case_id',p.case_id,'state','review_required','claim_id',p_request,'attached',false,'approval_required',true,'link_created',false);
 end if;
 insert into private.visit_recovery_proposal_acceptances(request_id,actor_id,proposal_id,payload_hash,consent,claim_id,attachment_id,result)values(p_request,actor,p_proposal,hash,p_consent,p_request,attachment,result);
 return result;
end$$;

revoke all on function private.visit_recovery_proposal_notice(text),private.visit_recovery_proposal_state(private.visit_recovery_owner_proposals),private.owner_visit_recovery_proposal_snapshot(uuid)from public,anon,authenticated,service_role;
revoke all on function private.prepare_visit_recovery_proposal(uuid,uuid,uuid,text,text,boolean,text)from public,anon,authenticated,service_role;
grant execute on function private.prepare_visit_recovery_proposal(uuid,uuid,uuid,text,text,boolean,text)to authenticated;
create function public.prepare_visit_recovery_proposal(p_proposal uuid,p_query uuid,p_profile uuid,p_evidence_type text,p_reason text,p_attested boolean,p_plate text default null)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.prepare_visit_recovery_proposal(p_proposal,p_query,p_profile,p_evidence_type,p_reason,p_attested,p_plate)$$;
revoke all on function public.prepare_visit_recovery_proposal(uuid,uuid,uuid,text,text,boolean,text)from public,anon,service_role;
grant execute on function public.prepare_visit_recovery_proposal(uuid,uuid,uuid,text,text,boolean,text)to authenticated;
revoke all on function private.get_visit_recovery_proposal(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_visit_recovery_proposal(uuid)to authenticated;
create function public.get_visit_recovery_proposal(p_proposal uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_visit_recovery_proposal(p_proposal)$$;
revoke all on function public.get_visit_recovery_proposal(uuid)from public,anon,service_role;
grant execute on function public.get_visit_recovery_proposal(uuid)to authenticated;
revoke all on function private.close_visit_recovery_proposal(uuid)from public,anon,authenticated,service_role;
grant execute on function private.close_visit_recovery_proposal(uuid)to authenticated;
create function public.close_visit_recovery_proposal(p_proposal uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.close_visit_recovery_proposal(p_proposal)$$;
revoke all on function public.close_visit_recovery_proposal(uuid)from public,anon,service_role;
grant execute on function public.close_visit_recovery_proposal(uuid)to authenticated;
revoke all on function private.get_my_visit_recovery_proposal(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_my_visit_recovery_proposal(uuid)to authenticated;
create function public.get_my_visit_recovery_proposal(p_case uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_my_visit_recovery_proposal(p_case)$$;
revoke all on function public.get_my_visit_recovery_proposal(uuid)from public,anon,service_role;
grant execute on function public.get_my_visit_recovery_proposal(uuid)to authenticated;
revoke all on function private.get_my_visit_recovery_acceptance(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_my_visit_recovery_acceptance(uuid)to authenticated;
create function public.get_my_visit_recovery_acceptance(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_my_visit_recovery_acceptance(p_request)$$;
revoke all on function public.get_my_visit_recovery_acceptance(uuid)from public,anon,service_role;
grant execute on function public.get_my_visit_recovery_acceptance(uuid)to authenticated;
revoke all on function private.close_my_visit_recovery_acceptance(uuid)from public,anon,authenticated,service_role;
grant execute on function private.close_my_visit_recovery_acceptance(uuid)to authenticated;
create function public.close_my_visit_recovery_acceptance(p_request uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.close_my_visit_recovery_acceptance(p_request)$$;
revoke all on function public.close_my_visit_recovery_acceptance(uuid)from public,anon,service_role;
grant execute on function public.close_my_visit_recovery_acceptance(uuid)to authenticated;
revoke all on function private.accept_my_visit_recovery_proposal(uuid,uuid,jsonb,jsonb)from public,anon,authenticated,service_role;
grant execute on function private.accept_my_visit_recovery_proposal(uuid,uuid,jsonb,jsonb)to authenticated;
create function public.accept_my_visit_recovery_proposal(p_request uuid,p_proposal uuid,p_consent jsonb,p_claim_consent jsonb)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.accept_my_visit_recovery_proposal(p_request,p_proposal,p_consent,p_claim_consent)$$;
revoke all on function public.accept_my_visit_recovery_proposal(uuid,uuid,jsonb,jsonb)from public,anon,service_role;
grant execute on function public.accept_my_visit_recovery_proposal(uuid,uuid,jsonb,jsonb)to authenticated;
notify pgrst,'reload schema';
commit;
