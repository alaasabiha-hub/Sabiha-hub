-- SOURCE ONLY: metadata and unknown-nonce fencing, outer rollback.
begin;
do $$declare v_owner uuid;v_request uuid:=gen_random_uuid();v_denied boolean;begin
 assert(select kernel_installed and not public_enabled from private.offline_reward_issuer_runtime where singleton);
 assert not has_function_privilege('authenticated','private.place_offline_reward_issue(uuid)','EXECUTE');
 assert not has_function_privilege('service_role','private.prepare_offline_reward_issue(uuid,uuid,uuid,uuid,uuid[])','EXECUTE');
 assert not has_table_privilege('authenticated','private.offline_reward_issue_commands','INSERT');
 assert not has_table_privilege('service_role','private.offline_reward_issue_events','INSERT');
 select s.user_id into strict v_owner from public.staff_profiles s where s.role='owner'and s.is_active and exists(select 1 from auth.sessions sess where sess.user_id=s.user_id and(sess.not_after is null or sess.not_after>clock_timestamp()))limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'session_id',(select id from auth.sessions where user_id=v_owner and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1))::text,true);perform set_config('request.jwt.claim.sub',v_owner::text,true);
 assert private.get_offline_reward_issue(v_request)->>'state'='absent';
 assert private.close_offline_reward_issue(v_request)->>'state'='closed';
 assert private.prepare_offline_reward_issue(v_request,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),array[v_owner])->>'state'='closed';
 assert private.place_offline_reward_issue(v_request)->>'state'='closed';
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 v_denied:=false;begin perform private.get_offline_reward_issue(v_request);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert private.offline_service_visit_readiness()->>'redemption_enabled'='false';
end$$;
rollback;
