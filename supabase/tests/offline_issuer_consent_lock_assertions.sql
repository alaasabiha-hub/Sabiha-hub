-- SOURCE ONLY helper for root-reviewed genuine original-receipt claim, actual
-- earned credit, held quote, 22019 preparation and 23736 proposal fixture.
create function pg_temp.assert_live_offline_issuer_consent(p_customer uuid,p_preparation uuid,p_proposal uuid,p_revoke boolean default true)returns uuid language plpgsql as $$
declare v_owner uuid:=auth.uid();v_claims text:=current_setting('request.jwt.claims',true);v_sub text:=current_setting('request.jwt.claim.sub',true);v_session uuid;v_nonce uuid:=gen_random_uuid();v_consent jsonb;v_view jsonb;v_authority jsonb;v_denied boolean;v_counts jsonb;v_claim_hash text;
begin
 select id into strict v_session from auth.sessions where user_id=p_customer and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_customer,'session_id',v_session)::text,true);perform set_config('request.jwt.claim.sub',p_customer::text,true);
 execute 'set local role authenticated';
 v_view:=public.get_my_offline_reward_financial_proposal(p_proposal);assert v_view->>'state'='proposal';
 v_consent:=jsonb_build_object('accepted',true,'version','offline-reward-financial-v1','language','en','text',v_view#>>'{consent,notice_en}');
 assert public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent)->>'state'='consent_recorded';
 v_denied:=false;begin perform private.lock_linked_offline_reward_issuer_consent(p_preparation,v_nonce);exception when insufficient_privilege then v_denied:=true;end;assert v_denied,'Customer cannot execute internal operator kernel';
 execute 'reset role';
 perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);
 select jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_orders),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions))into v_counts;
 select md5(coalesce(string_agg(to_jsonb(c)::text,''order by claim_id),''))into v_claim_hash from private.reward_credit_claims c;
 v_authority:=private.lock_linked_offline_reward_issuer_consent(p_preparation,v_nonce);
 assert auth.uid()=v_owner and v_owner<>p_customer,'No customer Auth impersonation';
 assert v_authority->>'state'='locked_consent_valid'and(v_authority->>'operator_id')::uuid=v_owner and(v_authority->>'customer_id')::uuid=p_customer;
 assert(v_authority->>'authorized_xid')::bigint=txid_current()and(v_authority->>'same_transaction_only')::boolean;
 assert not(v_authority->>'issuer_enabled')::boolean and not(v_authority->>'reward_issued')::boolean;
 assert(v_authority->>'preparation_id')::uuid=p_preparation and(v_authority->>'consent_request_id')::uuid=v_nonce;
 assert v_authority->'witness'=(select witness from private.offline_reward_consumption_preparations where request_id=p_preparation);
 assert private.lock_linked_offline_reward_issuer_consent(p_preparation,v_nonce)=v_authority,'Same transaction exact validation replay';
 v_denied:=false;begin perform private.lock_linked_offline_reward_issuer_consent(gen_random_uuid(),v_nonce);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 assert v_counts=jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_orders),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions));
 assert v_claim_hash=(select md5(coalesce(string_agg(to_jsonb(c)::text,''order by claim_id),''))from private.reward_credit_claims c),'Authorization cannot consume or release credits';
 if p_revoke then
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_customer,'session_id',v_session)::text,true);perform set_config('request.jwt.claim.sub',p_customer::text,true);
 execute 'set local role authenticated';perform public.revoke_my_offline_reward_financial_consent(gen_random_uuid(),v_nonce);execute 'reset role';
 perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);
 v_denied:=false;begin perform private.lock_linked_offline_reward_issuer_consent(p_preparation,v_nonce);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Actual customer withdrawal must defeat operator authorization';
 end if;
 return v_nonce;
end$$;
