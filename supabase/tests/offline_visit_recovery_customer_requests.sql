-- SOURCE ONLY. Uses actual existing sessions/accounts; all fixtures roll back.
begin;
create function pg_temp.recovery_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
create function pg_temp.reject_recovery_owner_notice()returns trigger language plpgsql as $$begin
 raise exception 'Isolated inbox failure fixture'using errcode='55000';end$$;
do $$
declare customer uuid;other_customer uuid;own uuid;manager uuid;nonce uuid:=gen_random_uuid();failed_nonce uuid:=gen_random_uuid();
 case_id uuid;other_case uuid;consent jsonb;value jsonb;first_value jsonb;changed jsonb;denied boolean;
 new_phone text:='010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');
 claims_before bigint;links_before bigint;cases_before bigint;inbox_before bigint;
begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.deleted_at is null and u.email_confirmed_at is not null and u.email is not null
 and(u.banned_until is null or u.banned_until<=clock_timestamp())
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id)
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))order by c.id limit 1;
 select c.id into strict other_customer from public.customers c join auth.users u on u.id=c.id where c.id<>customer and u.deleted_at is null and u.email_confirmed_at is not null and u.email is not null
 and(u.banned_until is null or u.banned_until<=clock_timestamp())
 and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and not exists(select 1 from private.visit_recovery_customer_requests r where r.requester_id=c.id)
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))order by c.id limit 1;
 select s.user_id into strict own from public.staff_profiles s where role='owner'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 select s.user_id into strict manager from public.staff_profiles s where role='manager'and is_active and exists(select 1 from auth.sessions ses where ses.user_id=s.user_id and(ses.not_after is null or ses.not_after>clock_timestamp()))limit 1;
 select count(*)into claims_before from private.offline_claim_requests;select count(*)into links_before from private.offline_customer_trusted_links;
 select count(*)into cases_before from private.visit_recovery_customer_requests;select count(*)into inbox_before from private.app_inbox_events;
 consent:=jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','ar','text',private.visit_recovery_request_notice('ar'));
 assert not has_table_privilege('authenticated','private.visit_recovery_customer_requests','SELECT');
 assert not has_table_privilege('service_role','private.visit_recovery_submission_requests','INSERT');
 assert not has_function_privilege('anon','public.submit_visit_recovery_request(uuid,jsonb)','EXECUTE');
 assert not has_function_privilege('authenticated','private.visit_recovery_request_identity()','EXECUTE');
 -- Saved QA identities have intentionally invalid placeholder phones. Test denial,
 -- then populate valid isolated phones ONLY inside this outer rollback transaction.
 perform pg_temp.recovery_actor(customer);
 denied:=false;begin perform public.get_my_visit_recovery_request();exception when insufficient_privilege then denied:=true;end;assert denied,'Unusable registered phone accepted';
 update public.customers set phone='+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0')where id in(customer,other_customer);
 assert public.get_my_visit_recovery_request()->>'state'='unavailable';
 assert public.get_my_visit_recovery_request()#>>'{consent,version}'='visit-recovery-v1';
 assert public.get_my_visit_recovery_request()#>>'{consent,notice_ar}'=private.visit_recovery_request_notice('ar');
 denied:=false;begin perform public.submit_visit_recovery_request(nonce,consent||'{"profile_id":"not_allowed"}'::jsonb);exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform public.submit_visit_recovery_request(nonce,consent||'{"accepted":false}'::jsonb);exception when invalid_parameter_value then denied:=true;end;assert denied;
 first_value:=public.submit_visit_recovery_request(nonce,consent);case_id:=(first_value#>>'{case,case_id}')::uuid;
 assert first_value->>'state'='available'and first_value#>>'{case,status}'='awaiting_matching'and first_value#>>'{case,identity_current}'='true';
 assert first_value->>'approval_available'='false'and first_value->>'canonical_claim_created'='false'and first_value->>'link_created'='false';
 assert not(first_value?'phone')and not(first_value?'profile_id')and not(first_value?'email')and not(first_value?'email_hash');
 assert length(first_value->>'pending_text_ar')>0 and length(first_value->>'pending_text_en')>0;
 assert public.submit_visit_recovery_request(nonce,consent)=first_value;
 value:=public.submit_visit_recovery_request(gen_random_uuid(),consent);assert value=first_value;
 assert public.get_my_visit_recovery_request(case_id)=first_value and public.get_my_visit_recovery_request()=first_value;
 assert(select count(*)from private.visit_recovery_customer_requests where requester_id=customer)=1;
 assert(select count(*)from private.app_inbox_events where source_case_id=case_id)=2;
 assert exists(select 1 from private.app_inbox_events where source_case_id=case_id and recipient_kind='customer'and recipient_customer_id=customer and template_code='recovery_received');
 assert exists(select 1 from private.app_inbox_events where source_case_id=case_id and recipient_kind='active_owner_pool'and recipient_customer_id is null and template_code='recovery_submitted');
 denied:=false;begin perform public.submit_visit_recovery_request(nonce,jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',private.visit_recovery_request_notice('en')));exception when invalid_parameter_value then denied:=true;end;assert denied;
 -- A changed actual registered phone is detected, not matched to any old profile.
 begin
  update public.customers set phone=new_phone where id=customer;
  changed:=public.get_my_visit_recovery_request(case_id);assert changed#>>'{case,identity_current}'='false';
  assert public.submit_visit_recovery_request(nonce,consent)=changed;
  assert(select count(*)from private.app_inbox_events where source_case_id=case_id)=2;
  raise exception 'Rollback isolated phone change'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 assert public.get_my_visit_recovery_request(case_id)#>>'{case,identity_current}'='true';
 begin
  update auth.users set email_confirmed_at=null where id=customer;
  denied:=false;begin perform public.get_my_visit_recovery_request(case_id);exception when insufficient_privilege then denied:=true;end;assert denied;
  raise exception 'Rollback isolated email state change'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 -- An invented session UUID never substitutes for a current real Auth session.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'role','authenticated','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.get_my_visit_recovery_request(case_id);exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_actor(other_customer);
 assert public.get_my_visit_recovery_request(case_id)=public.get_my_visit_recovery_request(gen_random_uuid());
 denied:=false;begin perform public.submit_visit_recovery_request(nonce,consent);exception when insufficient_privilege then denied:=true;end;assert denied;
 -- The second notice failing must roll back the new envelope, nonce AND first notice.
 execute 'create trigger qa_recovery_owner_notice_failure before insert on private.app_inbox_events for each row when(new.template_code=''recovery_submitted'')execute function pg_temp.reject_recovery_owner_notice()';
 denied:=false;begin perform public.submit_visit_recovery_request(failed_nonce,consent);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 assert not exists(select 1 from private.visit_recovery_customer_requests where requester_id=other_customer);
 assert not exists(select 1 from private.visit_recovery_submission_requests where request_id=failed_nonce);
 assert(select count(*)from private.app_inbox_events)=inbox_before+2;
 execute 'drop trigger qa_recovery_owner_notice_failure on private.app_inbox_events';
 value:=public.submit_visit_recovery_request(failed_nonce,consent);other_case:=(value#>>'{case,case_id}')::uuid;assert other_case<>case_id;
 perform pg_temp.recovery_actor(manager);
 denied:=false;begin perform public.get_visit_recovery_request_for_review(case_id);exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_actor(own);
 value:=public.get_visit_recovery_request_for_review(case_id);assert value#>>'{case,case_id}'=case_id::text and value->>'approval_available'='false';
 assert not(value?'requester_id')and not(value?'phone')and not(value?'profile_id')and not(value?'email');
 assert public.get_visit_recovery_request_for_review(gen_random_uuid())->>'state'='unavailable';
 assert(select count(*)from private.visit_recovery_customer_requests)=cases_before+2;
 assert(select count(*)from private.app_inbox_events)=inbox_before+4;
 assert(select count(*)from private.offline_claim_requests)=claims_before;
 assert(select count(*)from private.offline_customer_trusted_links)=links_before;
 denied:=false;begin update private.visit_recovery_customer_requests r set phone_hash=extensions.digest('changed','sha256')where r.case_id=other_case;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 raise notice 'PASS source recovery submission rollback fixture';
end$$;
rollback;
