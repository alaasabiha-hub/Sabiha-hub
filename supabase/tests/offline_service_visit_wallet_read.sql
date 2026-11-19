-- SOURCE ONLY linked-read authorization fixture; root controls LOCAL execution.
-- No earning, allocation, debt settlement, Auth user, HR update or financial mutation.
begin;
do $$
declare own uuid;customer uuid;other uuid;branch uuid:=gen_random_uuid();session_id uuid:=gen_random_uuid();other_session uuid:=gen_random_uuid();
 intake jsonb;reg jsonb;claim_consent jsonb;history_consent jsonb;wallet_consent jsonb;request_id uuid:=gen_random_uuid();claim_id uuid:=gen_random_uuid();link_id uuid;
 result jsonb;repeated jsonb;before_ledger text;before_terms text;denied boolean;consent_request uuid:=gen_random_uuid();c record;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select u.id into strict customer from auth.users u join public.customers p on p.id=u.id where u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<clock_timestamp())
 and not exists(select 1 from private.offline_customer_trusted_links l where l.auth_user_id=u.id and l.revoked_at is null)
 and(select count(*)from private.offline_claim_requests r where r.actor_id=u.id and r.created_at>clock_timestamp()-interval'1 hour')<5
 and(select count(*)from private.offline_claim_requests r where r.actor_id=u.id and r.created_at>clock_timestamp()-interval'1 day')<20
 and not exists(select 1 from public.staff_profiles s where s.user_id=u.id)order by u.id limit 1;
 select p.id into strict other from public.customers p where p.id<>customer and not exists(select 1 from public.staff_profiles s where s.user_id=p.id)limit 1;
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.id),''))into before_ledger from private.canonical_loyalty_visits e;
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.earning_id),''))into before_terms from private.reward_earning_terms e;
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert not has_table_privilege('authenticated','private.offline_visit_wallet_read_consents','SELECT');
 assert not has_function_privilege('authenticated','private.offline_visit_wallet_projection(uuid)','EXECUTE');
 assert not has_function_privilege('anon','public.get_my_offline_service_visit_wallet()','EXECUTE');
 insert into auth.sessions(id,user_id,created_at,updated_at,not_after)values(session_id,customer,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval'1 hour'),(other_session,other,clock_timestamp(),clock_timestamp(),clock_timestamp()+interval'1 hour');
 insert into public.business_branches(branch_id,name_ar,name_en)values(branch,'اختبار موافقة عرض الزيارات','Wallet read scope QA');
 reg:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 claim_consent:=jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en'));
 history_consent:=jsonb_build_object('accepted',true,'version','offline-history-v1','language','en','text',private.offline_history_notice('en'));
 wallet_consent:=jsonb_build_object('accepted',true,'version','offline-wallet-read-v1','language','en','text',private.offline_visit_wallet_read_notice('en'));
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);
 intake:=public.register_offline_customer(request_id,branch,'QA wallet read identity','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA WALLET1"}',reg);
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',session_id)::text,true);
 assert public.get_my_offline_service_visit_wallet()->>'state'='review_required';
 result:=public.request_offline_customer_claim(claim_id,(intake->>'enrollment_receipt_id')::uuid,intake->>'enrollment_secret','original_receipt',claim_consent);assert result->>'status'='pending_owner_review';
 perform set_config('request.jwt.claim.sub',own::text,true);perform set_config('request.jwt.claims','{}',true);
 result:=public.decide_offline_customer_claim(gen_random_uuid(),claim_id,'approve_with_secret','Wallet component original receipt verified');link_id:=(result->>'link_id')::uuid;
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',session_id)::text,true);
 perform public.accept_my_offline_history_scope(gen_random_uuid(),history_consent);
 assert public.get_my_offline_service_visit_wallet()->>'state'='consent_required','History scope must not authorize financial read';
 denied:=false;begin perform public.accept_my_offline_wallet_read_scope(consent_request,history_consent);exception when invalid_parameter_value then denied:=true;end;assert denied;
 result:=public.accept_my_offline_wallet_read_scope(consent_request,wallet_consent);repeated:=public.accept_my_offline_wallet_read_scope(consent_request,wallet_consent);assert repeated=result;
 denied:=false;begin perform public.accept_my_offline_wallet_read_scope(consent_request,wallet_consent||'{"accepted":false}');exception when invalid_parameter_value then denied:=true;end;assert denied;
 assert public.get_my_offline_service_visit_wallet()->>'state'='acceptance_pending';
 execute 'reset role';
 -- Only this test-owned outer ROLLBACK may relax the independent read disabled check.
 for c in select conname from pg_constraint where conrelid='private.offline_visit_wallet_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%read_enabled%'loop
 execute format('alter table private.offline_visit_wallet_runtime drop constraint %I',c.conname);end loop;
 update private.offline_visit_wallet_runtime set read_enabled=true where singleton;
 execute 'set local role authenticated';
 result:=public.get_my_offline_service_visit_wallet();assert result->>'state'='available_read_only'and result->>'unit'='service_visits'and result->>'owner_kind'='offline_profile';
 assert result->>'recorded_earned_visits'='0'and result->'cohorts'='[]'::jsonb,'Linking must not invent or transfer credits';
 assert result @>'{"redemption_enabled":false,"ownership_transferred":false,"points_conversion_supported":false,"global_spendable_balance":null,"debt_adjusted_spendable_visits":null}';
 assert not(result?'offline_profile_id')and not(result?'target_customer_ids')and not(result?'target_offline_profile_ids');
 perform set_config('request.jwt.claim.sub',other::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',other,'session_id',other_session)::text,true);
 assert public.get_my_offline_service_visit_wallet()->>'state'='review_required';
 denied:=false;begin perform public.accept_my_offline_wallet_read_scope(consent_request,wallet_consent);exception when insufficient_privilege then denied:=true;end;assert denied;
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',other_session)::text,true);
 assert public.get_my_offline_service_visit_wallet()->>'state'='review_required','Foreign session cannot reuse a scope';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',session_id)::text,true);
 execute 'reset role';
 begin
 insert into private.offline_customer_contacts(profile_id,phone_e164,country_context)values((intake->>'offline_profile_id')::uuid,'+20212345678','EG');
 execute 'set local role authenticated';assert public.get_my_offline_service_visit_wallet()->>'state'='review_required';raise exception 'rollback changed contact'using errcode='PZ051';
 exception when sqlstate'PZ051'then null;end;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);perform set_config('request.jwt.claims','{}',true);
 perform public.revoke_offline_customer_link(gen_random_uuid(),link_id,'Wallet read access withdrawn for component QA');
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'session_id',session_id)::text,true);
 assert public.get_my_offline_service_visit_wallet()->>'state'='review_required';
 denied:=false;begin perform public.accept_my_offline_wallet_read_scope(consent_request,wallet_consent);exception when insufficient_privilege then denied:=true;end;assert denied,'Consent replay must recheck revocation';
 execute 'reset role';
 assert before_ledger=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.id),''))from private.canonical_loyalty_visits e);
 assert before_terms=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.earning_id),''))from private.reward_earning_terms e);
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton),'Read acceptance must not enable earning';
end$$;
rollback;
