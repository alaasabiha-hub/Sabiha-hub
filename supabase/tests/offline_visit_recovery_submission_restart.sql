-- SOURCE ONLY. Existing confirmed QA accounts + actual live sessions. ROLLBACK
-- restores every row; no Auth account, candidate match, claim, link or reward.
begin;
create function pg_temp.recovery_restart_actor(p_actor uuid)returns void language plpgsql as $$declare sid uuid;begin
 select id into strict sid from auth.sessions where user_id=p_actor and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'role','authenticated','session_id',sid)::text,true);
end$$;
do $$
declare customer uuid;other_customer uuid;actor uuid;consent jsonb;alternate jsonb;value jsonb;receipt jsonb;submitted jsonb;
 closed_nonce uuid:=gen_random_uuid();accepted_nonce uuid:=gen_random_uuid();second_nonce uuid:=gen_random_uuid();rolled_nonce uuid:=gen_random_uuid();
 case_ref uuid;cases_before bigint;submissions_before bigint;inbox_before bigint;notices_after bigint;claims_before bigint;links_before bigint;
 stamp timestamptz;denied boolean;v_phone text;
begin
 select c.id into strict customer from public.customers c join auth.users u on u.id=c.id where u.deleted_at is null and u.email_confirmed_at is not null and nullif(trim(u.email),'')is not null
 and(u.banned_until is null or u.banned_until<=clock_timestamp())and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))order by c.id limit 1;
 select c.id into strict other_customer from public.customers c join auth.users u on u.id=c.id where c.id<>customer and u.deleted_at is null and u.email_confirmed_at is not null and nullif(trim(u.email),'')is not null
 and(u.banned_until is null or u.banned_until<=clock_timestamp())and not exists(select 1 from public.staff_profiles s where s.user_id=c.id)
 and exists(select 1 from auth.sessions ses where ses.user_id=c.id and(ses.not_after is null or ses.not_after>clock_timestamp()))order by c.id limit 1;
 -- Only invalid QA placeholders are populated, inside outer ROLLBACK. Never
 -- infer a profile/phone match or persist a real customer's contact change.
 foreach actor in array array[customer,other_customer]loop
 if exists(select 1 from public.customers c where c.id=actor and private.offline_phone_key(c.phone,'EG')is null)then
 loop
 v_phone:='+2010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');
 exit when not exists(select 1 from public.customers where phone=v_phone);
 end loop;
 update public.customers set phone=v_phone where id=actor;
 end if;end loop;
 consent:=jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','en','text',private.visit_recovery_request_notice('en'));
 alternate:=jsonb_build_object('accepted',true,'version','visit-recovery-v1','language','ar','text',private.visit_recovery_request_notice('ar'));
 select count(*)into claims_before from private.offline_claim_requests;select count(*)into links_before from private.offline_customer_trusted_links;
 select count(*)into cases_before from private.visit_recovery_customer_requests;select count(*)into submissions_before from private.visit_recovery_submission_requests;select count(*)into inbox_before from private.app_inbox_events;
 assert not has_table_privilege('authenticated','private.visit_recovery_submission_closures','SELECT');
 assert not has_table_privilege('service_role','private.visit_recovery_submission_closures','INSERT');
 assert not has_function_privilege('anon','public.get_my_visit_recovery_submission(uuid)','EXECUTE');
 assert not has_function_privilege('service_role','public.close_my_visit_recovery_submission(uuid)','EXECUTE');
 assert has_function_privilege('authenticated','public.get_my_visit_recovery_submission(uuid)','EXECUTE');
 perform pg_temp.recovery_restart_actor(customer);
 value:=public.get_my_visit_recovery_submission(closed_nonce);
 assert value->>'state'='absent'and value->>'definitive_failure'='false'and value->'payload'='null'::jsonb and value->'result'='null'::jsonb;
 -- Close-first permanently fences a delayed valid producer; no envelope/notices.
 receipt:=public.close_my_visit_recovery_submission(closed_nonce);
 assert receipt->>'state'='closed'and receipt->>'definitive_failure'='true'and receipt->>'request_id'=closed_nonce::text;
 select closed_at into strict stamp from private.visit_recovery_submission_closures where request_id=closed_nonce;
 assert public.close_my_visit_recovery_submission(closed_nonce)=receipt;
 assert public.get_my_visit_recovery_submission(closed_nonce)=receipt;
 assert public.submit_visit_recovery_request(closed_nonce,consent)=receipt;
 assert(select closed_at=stamp from private.visit_recovery_submission_closures where request_id=closed_nonce);
 assert not exists(select 1 from private.visit_recovery_submission_requests where request_id=closed_nonce);
 assert(select count(*)from private.visit_recovery_customer_requests)=cases_before;
 assert(select count(*)from private.app_inbox_events)=inbox_before;
 -- Submit-first survives restart: exact nonce, actual stored consent and current
 -- case result, even if an older open case was reused rather than replaced.
 submitted:=public.submit_visit_recovery_request(accepted_nonce,consent);case_ref:=(submitted#>>'{case,case_id}')::uuid;
 select count(*)into notices_after from private.app_inbox_events;
 receipt:=public.get_my_visit_recovery_submission(accepted_nonce);
 assert receipt->>'state'='accepted'and receipt->>'request_id'=accepted_nonce::text and receipt->>'definitive_failure'='false';
 assert receipt->'payload'=jsonb_build_object('consent',consent)and receipt->'result'=submitted;
 assert receipt#>>'{result,case,case_id}'=case_ref::text;
 assert not(receipt?'phone')and not(receipt?'email')and not(receipt?'profile_id')and not(receipt?'email_hash');
 assert public.close_my_visit_recovery_submission(accepted_nonce)=receipt,'Accepted submission was cancelled/hidden';
 assert public.submit_visit_recovery_request(accepted_nonce,consent)=submitted;
 assert not exists(select 1 from private.visit_recovery_submission_closures where request_id=accepted_nonce);
 assert(select count(*)from private.app_inbox_events)=notices_after;
 denied:=false;begin perform public.submit_visit_recovery_request(accepted_nonce,alternate);exception when invalid_parameter_value then denied:=true;end;assert denied;
 assert public.get_my_visit_recovery_submission(accepted_nonce)->'payload'=jsonb_build_object('consent',consent);
 -- Current notice/another nonce cannot be substituted for original consent.
 value:=public.submit_visit_recovery_request(second_nonce,alternate);
 assert value#>>'{case,case_id}'=case_ref::text;
 assert public.get_my_visit_recovery_submission(second_nonce)->'payload'=jsonb_build_object('consent',alternate);
 assert public.get_my_visit_recovery_submission(accepted_nonce)->'payload'=jsonb_build_object('consent',consent);
 assert(select count(*)from private.app_inbox_events)=notices_after;
 assert public.get_my_visit_recovery_submission(gen_random_uuid())->>'state'='absent','Reader adopted a latest case for an unknown nonce';
 -- Closed tombstones are immutable and never recreated/reactivated.
 denied:=false;begin update private.visit_recovery_submission_closures set closed_at=clock_timestamp()+interval'1 minute'where request_id=closed_nonce;exception when object_not_in_prerequisite_state then denied:=true;end;assert denied;
 -- A rolled-back close is not a committed fence; later actual producer may win.
 begin
 assert public.close_my_visit_recovery_submission(rolled_nonce)->>'state'='closed';
 raise exception 'Rollback isolated close'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 assert public.get_my_visit_recovery_submission(rolled_nonce)->>'state'='absent';
 perform public.submit_visit_recovery_request(rolled_nonce,consent);
 assert public.close_my_visit_recovery_submission(rolled_nonce)->>'state'='accepted';
 -- Contact drift never rewrites the original receipt or grants identity rights.
 begin
 loop
 v_phone:='+2010'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%100000000)::text,8,'0');
 exit when not exists(select 1 from public.customers where phone=v_phone);
 end loop;
 update public.customers set phone=v_phone where id=customer;
 value:=public.get_my_visit_recovery_submission(accepted_nonce);
 assert value->>'state'='accepted'and value->'payload'=jsonb_build_object('consent',consent);
 assert value#>>'{result,case,identity_current}'='false';
 raise exception 'Rollback isolated phone drift'using errcode='P9901';
 exception when sqlstate'P9901'then null;end;
 -- Exact existing session required, not merely an Auth UUID or forged metadata.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'role','authenticated','session_id',gen_random_uuid())::text,true);
 denied:=false;begin perform public.get_my_visit_recovery_submission(accepted_nonce);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.close_my_visit_recovery_submission(gen_random_uuid());exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_restart_actor(other_customer);
 denied:=false;begin perform public.get_my_visit_recovery_submission(accepted_nonce);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.close_my_visit_recovery_submission(accepted_nonce);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.get_my_visit_recovery_submission(closed_nonce);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.close_my_visit_recovery_submission(closed_nonce);exception when insufficient_privilege then denied:=true;end;assert denied;
 denied:=false;begin perform public.submit_visit_recovery_request(closed_nonce,consent);exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.recovery_restart_actor(customer);
 assert public.get_my_visit_recovery_submission(accepted_nonce)->'payload'=jsonb_build_object('consent',consent);
 assert(select count(*)from private.visit_recovery_submission_requests)=submissions_before+3;
 assert(select count(*)from private.offline_claim_requests)=claims_before;
 assert(select count(*)from private.offline_customer_trusted_links)=links_before;
 assert(select count(*)from private.app_inbox_events)=notices_after;
 raise notice 'PASS recovery restart receipt, exact consent, close fence, accepted preservation, session/cross-actor denial; fixture rollback only';
end$$;
rollback;
