begin;
-- Safe review increment ONLY: more-information/rejection on UNMAPPED cases.
-- No canonical claim/proposal/link/approval writer or historical notification hook.
alter table private.visit_recovery_customer_requests drop constraint visit_recovery_customer_requests_status_check;
alter table private.visit_recovery_customer_requests add constraint visit_recovery_customer_requests_status_check check(status in('awaiting_matching','more_info','rejected','linked','revoked'));
drop index private.one_open_visit_recovery_request;
create unique index one_open_visit_recovery_request on private.visit_recovery_customer_requests(requester_id)where status in('awaiting_matching','more_info');
create table private.visit_recovery_case_claims(
 case_id uuid primary key references private.visit_recovery_customer_requests(case_id),claim_id uuid not null unique references private.offline_claim_requests(request_id),
 created_at timestamptz not null default clock_timestamp());
-- Reserved bridge identity only. No client or public function can insert a map.
alter table private.visit_recovery_case_claims enable row level security;
revoke all on private.visit_recovery_case_claims from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_case_claim before update or delete on private.visit_recovery_case_claims for each row execute function private.immutable_visit_recovery_submission();
create table private.visit_recovery_review_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb,
 state text not null check(state in('open','succeeded','closed')),result jsonb,created_at timestamptz not null default clock_timestamp(),finished_at timestamptz,
 check((state='open'and payload is not null and result is null and finished_at is null)or(state='succeeded'and payload is not null and result is not null and finished_at is not null)or(state='closed'and result='{"status":"closed"}'::jsonb and finished_at is not null)));
create table private.visit_recovery_owner_decisions(
 request_id uuid primary key references private.visit_recovery_review_commands(request_id),case_id uuid not null references private.visit_recovery_customer_requests(case_id),
 owner_id uuid not null references auth.users(id),action text not null check(action in('more_info','reject')),
 expected_status text not null check(expected_status in('awaiting_matching','more_info')),status_after text not null check(status_after in('more_info','rejected')),
 private_reason text not null check(length(private_reason)between 10 and 500),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),
 check((action='more_info'and expected_status='awaiting_matching'and status_after='more_info')or(action='reject'and status_after='rejected')));
alter table private.visit_recovery_review_commands enable row level security;
alter table private.visit_recovery_owner_decisions enable row level security;
revoke all on private.visit_recovery_review_commands,private.visit_recovery_owner_decisions from public,anon,authenticated,service_role;
create trigger immutable_visit_recovery_owner_decision before update or delete on private.visit_recovery_owner_decisions for each row execute function private.immutable_visit_recovery_submission();

create function private.guard_visit_recovery_case_status()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'or(to_jsonb(new)-'status')is distinct from(to_jsonb(old)-'status')then raise exception 'Recovery case identity is immutable'using errcode='55000';end if;
 if old.status not in('awaiting_matching','more_info')or new.status not in('more_info','rejected')or old.status=new.status
 or exists(select 1 from private.visit_recovery_case_claims m where m.case_id=old.case_id)
 or not exists(select 1 from private.visit_recovery_owner_decisions d where d.case_id=old.case_id and d.owner_id=auth.uid()and d.expected_status=old.status and d.status_after=new.status and d.creator_xid=txid_current())then
 raise exception 'Actual unmapped owner review witness required; canonical bridge unavailable'using errcode='55000';end if;
 return new;
end$$;
revoke all on function private.guard_visit_recovery_case_status()from public,anon,authenticated,service_role;
drop trigger immutable_visit_recovery_request on private.visit_recovery_customer_requests;
create trigger guard_visit_recovery_case_status before update or delete on private.visit_recovery_customer_requests for each row execute function private.guard_visit_recovery_case_status();
create function private.guard_visit_recovery_review_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Review nonce and receipts are retained'using errcode='55000';end if;
 if old.state<>'open'or new.state not in('succeeded','closed')or(to_jsonb(new)-array['state','result','finished_at'])is distinct from(to_jsonb(old)-array['state','result','finished_at'])then raise exception 'Review payload and terminal receipt are immutable'using errcode='55000';end if;
 if new.state='succeeded'and not exists(select 1 from private.visit_recovery_owner_decisions d where d.request_id=new.request_id and d.owner_id=new.actor_id and d.creator_xid=txid_current())then raise exception 'Actual owner decision required'using errcode='55000';end if;
 return new;
end$$;
revoke all on function private.guard_visit_recovery_review_command()from public,anon,authenticated,service_role;
create trigger guard_visit_recovery_review_command before update or delete on private.visit_recovery_review_commands for each row execute function private.guard_visit_recovery_review_command();

create function private.visit_recovery_owner()returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();begin
 if private.active_staff_role()is distinct from'owner'then raise exception 'Current active owner required'using errcode='42501';end if;return actor;
end$$;
revoke all on function private.visit_recovery_owner()from public,anon,authenticated,service_role;
create function private.visit_recovery_review_snapshot(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.visit_recovery_owner();c private.visit_recovery_review_commands;begin
 select * into c from private.visit_recovery_review_commands where request_id=p_request;
 if not found then return jsonb_build_object('state','absent','request_id',p_request,'definitive_failure',false);end if;
 if c.actor_id<>actor then raise exception 'Own review command unavailable'using errcode='42501';end if;
 return jsonb_build_object('state',c.state,'request_id',c.request_id,'payload',c.payload,'result',c.result);
end$$;
revoke all on function private.visit_recovery_review_snapshot(uuid)from public,anon,authenticated,service_role;
create function private.prepare_visit_recovery_review(p_request uuid,p_case uuid,p_expected_status text,p_action text,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;payload jsonb;prior private.visit_recovery_review_commands;c private.visit_recovery_customer_requests;begin
 if p_request is null or p_case is null or p_expected_status is null or p_expected_status not in('awaiting_matching','more_info')or p_action is null or p_action not in('more_info','reject')or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact supported case review required'using errcode='22023';end if;
 payload:=jsonb_build_object('case_id',p_case,'expected_status',p_expected_status,'action',p_action,'private_reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-review:'||p_request::text,0));actor:=private.visit_recovery_owner();
 select * into prior from private.visit_recovery_review_commands where request_id=p_request;
 if found then
 if prior.actor_id<>actor then raise exception 'Own review command unavailable'using errcode='42501';end if;
 if prior.payload is not null and prior.payload<>payload then raise exception 'Review nonce reused with different fields'using errcode='22023';end if;
 return private.visit_recovery_review_snapshot(p_request);end if;
 select * into c from private.visit_recovery_customer_requests where case_id=p_case;
 if not found then raise exception 'Case unavailable'using errcode='42501';end if;
 if c.status<>p_expected_status then raise exception 'Case state changed'using errcode='40001';end if;
 if exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id)then raise exception 'Mapped case requires canonical proof bridge'using errcode='55000';end if;
 if p_action='more_info'and c.status<>'awaiting_matching'then raise exception 'More information already requested'using errcode='55000';end if;
 insert into private.visit_recovery_review_commands(request_id,actor_id,payload,state)values(p_request,actor,payload,'open');
 return private.visit_recovery_review_snapshot(p_request);
end$$;
create function private.get_visit_recovery_review(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$begin
 if p_request is null then raise exception 'Exact review nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-review:'||p_request::text,0));return private.visit_recovery_review_snapshot(p_request);
end$$;
create function private.close_visit_recovery_review(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;prior private.visit_recovery_review_commands;begin
 if p_request is null then raise exception 'Exact review nonce required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-review:'||p_request::text,0));actor:=private.visit_recovery_owner();
 select * into prior from private.visit_recovery_review_commands where request_id=p_request;
 if not found then insert into private.visit_recovery_review_commands(request_id,actor_id,state,result,finished_at)values(p_request,actor,'closed','{"status":"closed"}',clock_timestamp());
 elsif prior.actor_id<>actor then raise exception 'Own review command unavailable'using errcode='42501';
 elsif prior.state='open'then update private.visit_recovery_review_commands set state='closed',result='{"status":"closed"}',finished_at=clock_timestamp()where request_id=p_request;end if;
 return private.visit_recovery_review_snapshot(p_request);
end$$;
create function private.apply_visit_recovery_review(p_request uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;command private.visit_recovery_review_commands;c private.visit_recovery_customer_requests;target uuid;action_code text;after_status text;outcome jsonb;begin
 if p_request is null then raise exception 'Exact prepared review nonce required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Case review requires READ COMMITTED'using errcode='55000';end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-review:'||p_request::text,0));actor:=private.visit_recovery_owner();
 select * into command from private.visit_recovery_review_commands where request_id=p_request;
 if not found or command.actor_id<>actor then raise exception 'Own prepared review unavailable'using errcode='42501';end if;
 if command.state<>'open'then return private.visit_recovery_review_snapshot(p_request);end if;
 target:=(command.payload->>'case_id')::uuid;select * into c from private.visit_recovery_customer_requests where case_id=target;
 if not found then raise exception 'Case unavailable'using errcode='42501';end if;
 -- Same actor-envelope mutex as submission; NEVER calls canonical claim APIs under it.
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||c.requester_id::text,0));
 select * into c from private.visit_recovery_customer_requests where case_id=target for update;
 if exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id)then raise exception 'Mapped case requires canonical proof bridge'using errcode='55000';end if;
 if c.status<>command.payload->>'expected_status'then raise exception 'Case state changed'using errcode='40001';end if;
 action_code:=command.payload->>'action';after_status:=case when action_code='more_info'then'more_info'else'rejected'end;
 if c.status not in('awaiting_matching','more_info')or(action_code='more_info'and c.status<>'awaiting_matching')then raise exception 'Case cannot take this review action'using errcode='55000';end if;
 insert into private.visit_recovery_owner_decisions(request_id,case_id,owner_id,action,expected_status,status_after,private_reason,creator_xid)
 values(p_request,c.case_id,actor,action_code,c.status,after_status,command.payload->>'private_reason',txid_current());
 update private.visit_recovery_customer_requests set status=after_status where case_id=c.case_id;
 perform private.append_visit_recovery_inbox(p_request,c.case_id,'customer',c.requester_id,case when action_code='more_info'then'recovery_more_info'else'recovery_rejected'end);
 outcome:=jsonb_build_object('case_id',c.case_id,'action',action_code,'case_status',after_status,'approval_available',false);
 update private.visit_recovery_review_commands set state='succeeded',result=outcome,finished_at=clock_timestamp()where request_id=p_request;
 return private.visit_recovery_review_snapshot(p_request);
end$$;

create function private.visit_recovery_customer_status_snapshot(p_case private.visit_recovery_customer_requests,p_identity_current boolean)
returns jsonb language plpgsql stable set search_path=pg_catalog as $$
declare value jsonb:=private.visit_recovery_customer_snapshot(p_case,p_identity_current);t jsonb;begin
 if p_case.status in('more_info','rejected')then
 t:=private.app_inbox_template(case when p_case.status='more_info'then'recovery_more_info'else'recovery_rejected'end);
 value:=value||jsonb_build_object('pending_title_ar',t->>'title_ar','pending_title_en',t->>'title_en','pending_text_ar',t->>'body_ar','pending_text_en',t->>'body_en',
 'receipt_message_ar',t->>'body_ar','receipt_message_en',t->>'body_en','status_label_ar',t->>'title_ar','status_label_en',t->>'title_en');end if;
 return value;
end$$;
revoke all on function private.visit_recovery_customer_status_snapshot(private.visit_recovery_customer_requests,boolean)from public,anon,authenticated,service_role;
create function private.visit_recovery_owner_case_item(p_case uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare c private.visit_recovery_customer_requests;customer public.customers;current_identity boolean;mapped boolean;begin
 select * into c from private.visit_recovery_customer_requests where case_id=p_case;
 if not found then return null;end if;
 select * into customer from public.customers where id=c.requester_id;
 select exists(select 1 from auth.users u where u.id=c.requester_id and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())
 and u.email_confirmed_at=c.email_confirmed_at and extensions.digest(lower(trim(u.email)),'sha256')=c.email_hash
 and extensions.digest('registered-customer-phone-v1:'||private.offline_phone_key(customer.phone,'EG'),'sha256')=c.phone_hash)into current_identity;
 select exists(select 1 from private.visit_recovery_case_claims m where m.case_id=c.case_id)into mapped;
 return jsonb_build_object('case_id',c.case_id,'status',c.status,'created_at',c.created_at,'identity_current',current_identity,
 'requester_name',customer.full_name,'registered_phone',customer.phone,'canonical_claim_mapped',mapped,
 'more_info_available',not mapped and c.status='awaiting_matching','reject_available',not mapped and c.status in('awaiting_matching','more_info'),'approval_available',false);
end$$;
revoke all on function private.visit_recovery_owner_case_item(uuid)from public,anon,authenticated,service_role;
create or replace function private.get_visit_recovery_request_for_review(p_case uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare item jsonb;begin
 perform private.visit_recovery_owner();item:=private.visit_recovery_owner_case_item(p_case);
 return jsonb_build_object('state',case when item is null then'unavailable'else'available'end,'case',item,'approval_available',false);
end$$;
create function private.list_visit_recovery_requests(p_status text default null,p_before_created_at timestamptz default null,p_before_case uuid default null,p_limit integer default 25)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare items jsonb;more boolean;last_item jsonb;begin
 perform private.visit_recovery_owner();
 if p_limit is null or p_limit not between 1 and 50 or(p_before_created_at is null)<>(p_before_case is null)or(p_status is not null and p_status not in('awaiting_matching','more_info','rejected','linked','revoked'))then raise exception 'Valid bounded owner case cursor required'using errcode='22023';end if;
 with page as(select c.* from private.visit_recovery_customer_requests c where(p_status is null or c.status=p_status)
 and(p_before_created_at is null or(c.created_at,c.case_id)<(p_before_created_at,p_before_case))order by c.created_at desc,c.case_id desc limit p_limit+1),
 limited as(select * from page order by created_at desc,case_id desc limit p_limit)
 select coalesce(jsonb_agg(private.visit_recovery_owner_case_item(case_id)order by created_at desc,case_id desc),'[]'::jsonb),(select count(*)>p_limit from page)into items,more from limited;
 last_item:=items->(jsonb_array_length(items)-1);
 return jsonb_build_object('items',items,'next_cursor',case when more then jsonb_build_object('created_at',last_item->'created_at','case_id',last_item->'case_id')else null end,'approval_available',false);
end$$;

revoke all on function private.prepare_visit_recovery_review(uuid,uuid,text,text,text),private.get_visit_recovery_review(uuid),private.close_visit_recovery_review(uuid),private.apply_visit_recovery_review(uuid),private.list_visit_recovery_requests(text,timestamptz,uuid,integer)from public,anon,service_role;
grant execute on function private.prepare_visit_recovery_review(uuid,uuid,text,text,text),private.get_visit_recovery_review(uuid),private.close_visit_recovery_review(uuid),private.apply_visit_recovery_review(uuid),private.list_visit_recovery_requests(text,timestamptz,uuid,integer)to authenticated;
create function public.prepare_visit_recovery_review(p_request uuid,p_case uuid,p_expected_status text,p_action text,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_visit_recovery_review(p_request,p_case,p_expected_status,p_action,p_reason)$$;
create function public.get_visit_recovery_review(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_visit_recovery_review(p_request)$$;
create function public.close_visit_recovery_review(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_visit_recovery_review(p_request)$$;
create function public.apply_visit_recovery_review(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.apply_visit_recovery_review(p_request)$$;
create function public.list_visit_recovery_requests(p_status text default null,p_before_created_at timestamptz default null,p_before_case uuid default null,p_limit integer default 25)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_visit_recovery_requests(p_status,p_before_created_at,p_before_case,p_limit)$$;
revoke all on function public.prepare_visit_recovery_review(uuid,uuid,text,text,text),public.get_visit_recovery_review(uuid),public.close_visit_recovery_review(uuid),public.apply_visit_recovery_review(uuid),public.list_visit_recovery_requests(text,timestamptz,uuid,integer)from public,anon,service_role;
grant execute on function public.prepare_visit_recovery_review(uuid,uuid,text,text,text),public.get_visit_recovery_review(uuid),public.close_visit_recovery_review(uuid),public.apply_visit_recovery_review(uuid),public.list_visit_recovery_requests(text,timestamptz,uuid,integer)to authenticated;
-- Exact static refreshes from APPLIED225006 SHA256 be2a08399823c0cb2ed147500c1fbb0d3a261cdbb1004d695f5b57cf2cd43982.
-- Preserve original READ COMMITTED, pure server notice, receipt and identity checks.
create or replace function private.submit_visit_recovery_request(p_request uuid,p_consent jsonb)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare ident record;prior private.visit_recovery_submission_requests;c private.visit_recovery_customer_requests;
 normalized jsonb;language_code text;created boolean:=false;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Recovery submissions require READ COMMITTED'using errcode='25001';end if;
 if p_request is null or p_consent is null or jsonb_typeof(p_consent)<>'object'
 or not(p_consent?&array['accepted','version','language','text'])or p_consent-array['accepted','version','language','text']<>'{}'::jsonb
 or not(p_consent @> '{"accepted":true,"version":"visit-recovery-v1"}'::jsonb)then
 raise exception 'Explicit recovery request consent required'using errcode='22023';end if;
 language_code:=p_consent->>'language';
 if language_code is null or language_code not in('ar','en')or p_consent->>'text'is distinct from private.visit_recovery_request_notice(language_code)then
 raise exception 'Actual recovery request notice required'using errcode='22023';end if;
 normalized:=jsonb_build_object('consent',p_consent);
 -- One global request identity, then actual identity locks, then one actor envelope.
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-submit:'||p_request::text,0));
 select * into strict ident from private.visit_recovery_request_identity();
 select * into prior from private.visit_recovery_submission_requests where request_id=p_request;
 if found then
 if prior.actor_id<>ident.actor_id then raise exception 'Recovery request unavailable'using errcode='42501';end if;
 if prior.payload<>normalized then raise exception 'Recovery request identity reused with changed consent'using errcode='22023';end if;
 return private.get_my_visit_recovery_request(prior.case_id);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-recovery-customer:'||ident.actor_id::text,0));
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and status in('awaiting_matching','more_info');
 if not found then
 insert into private.visit_recovery_customer_requests(requester_id,email_hash,email_confirmed_at,phone_hash,consent)
 values(ident.actor_id,ident.email_hash,ident.email_confirmed_at,ident.phone_hash,p_consent)returning * into c;created:=true;
 end if;
 insert into private.visit_recovery_submission_requests(request_id,actor_id,payload,case_id)values(p_request,ident.actor_id,normalized,c.case_id);
 if created then
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'customer',ident.actor_id,'recovery_received');
 perform private.append_visit_recovery_inbox(c.submission_event_id,c.case_id,'active_owner_pool',null,'recovery_submitted');
 end if;
 -- Existing open case is returned, never silently replaced or re-fingerprinted.
 return private.get_my_visit_recovery_request(c.case_id);
end$$;

create or replace function private.get_my_visit_recovery_request(p_case uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare ident record;c private.visit_recovery_customer_requests;begin
 select * into strict ident from private.visit_recovery_request_identity();
 select * into c from private.visit_recovery_customer_requests where requester_id=ident.actor_id and(p_case is null or case_id=p_case)order by created_at desc,case_id desc limit 1;
 if not found then return jsonb_build_object('state','unavailable','case',null,'consent',jsonb_build_object('version','visit-recovery-v1','notice_ar',private.visit_recovery_request_notice('ar'),'notice_en',private.visit_recovery_request_notice('en')));end if;
 return private.visit_recovery_customer_status_snapshot(c,c.email_hash=ident.email_hash and c.email_confirmed_at=ident.email_confirmed_at and c.phone_hash=ident.phone_hash);
end$$;
notify pgrst,'reload schema';
commit;
