-- SOURCE ONLY: metadata/current-owner guard, entire transaction rolls back.
begin;
do $$declare v_owner uuid;v_denied boolean;begin
 assert not has_function_privilege('authenticated','private.lock_linked_offline_reward_issuer_consent(uuid,uuid)','EXECUTE');
 assert not has_function_privilege('service_role','private.lock_linked_offline_reward_issuer_consent(uuid,uuid)','EXECUTE');
 assert not has_function_privilege('anon','private.lock_linked_offline_reward_issuer_consent(uuid,uuid)','EXECUTE');
 select s.user_id into strict v_owner from public.staff_profiles s where s.is_active and s.role='owner'and exists(select 1 from auth.sessions sess where sess.user_id=s.user_id and(sess.not_after is null or sess.not_after>clock_timestamp()))limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'session_id',(select id from auth.sessions where user_id=v_owner and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1))::text,true);perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_denied:=false;begin perform private.lock_linked_offline_reward_issuer_consent(gen_random_uuid(),gen_random_uuid());exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 assert auth.uid()=v_owner,'Authorizer must never impersonate customer';
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 v_denied:=false;begin perform private.lock_linked_offline_reward_issuer_consent(gen_random_uuid(),gen_random_uuid());exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert private.offline_service_visit_readiness()->>'redemption_enabled'='false';
end$$;
rollback;
