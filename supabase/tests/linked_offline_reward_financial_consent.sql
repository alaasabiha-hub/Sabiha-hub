-- SOURCE ONLY; standalone outer rollback. No Auth/link/earning/financial creation.
begin;
do $$declare v_owner uuid;v_denied boolean;begin
 assert not has_table_privilege('authenticated','private.offline_reward_financial_proposals','SELECT');
 assert not has_table_privilege('authenticated','private.offline_reward_financial_consents','INSERT');
 assert not has_function_privilege('authenticated','private.propose_offline_reward_financial_consent(uuid,uuid)','EXECUTE');
 assert not has_function_privilege('service_role','public.accept_my_offline_reward_financial_consent(uuid,uuid,text,jsonb)','EXECUTE');
 assert has_function_privilege('authenticated','public.get_my_offline_reward_financial_proposal(uuid)','EXECUTE');
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner)::text,true);perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_denied:=false;begin perform public.accept_my_offline_reward_financial_consent(gen_random_uuid(),gen_random_uuid(),repeat('a',64),'{}');exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Owner cannot attest customer assent';
 perform set_config('request.jwt.claims','{}',true);perform set_config('request.jwt.claim.sub','',true);
 v_denied:=false;begin perform public.get_my_offline_reward_financial_proposal(gen_random_uuid());exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Anonymous cannot see a proposal';
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert private.offline_service_visit_readiness()->>'redemption_enabled'='false';
end$$;
rollback;
