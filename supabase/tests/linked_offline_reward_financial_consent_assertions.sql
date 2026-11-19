-- SOURCE ONLY; load inside root-reviewed outer-ROLLBACK real linked/earned fixture.
-- p_customer is an existing confirmed QA Auth customer with actual approved claim
-- link. p_proposal was created by the private owner proposer from an ACTUAL 22019
-- preparation. This helper never manufactures Auth/link/credit/consent evidence.
create function pg_temp.assert_linked_offline_financial_consent(p_customer uuid,p_proposal uuid)returns void language plpgsql as $$
declare v_claims text:=current_setting('request.jwt.claims',true);v_sub text:=current_setting('request.jwt.claim.sub',true);v_session uuid;v_view jsonb;v_nonce uuid:=gen_random_uuid();v_revoke uuid:=gen_random_uuid();v_unknown uuid:=gen_random_uuid();v_consent jsonb;v_first jsonb;v_denied boolean;v_counts jsonb;
begin
 select sess.id into strict v_session from auth.sessions sess join auth.users u on u.id=sess.user_id join public.customers c on c.id=u.id where u.id=p_customer and u.email_confirmed_at is not null and u.deleted_at is null and(sess.not_after is null or sess.not_after>clock_timestamp())order by sess.created_at desc limit 1;
 assert exists(select 1 from private.offline_customer_trusted_links where auth_user_id=p_customer and revoked_at is null),'Real accepted link required';
 select jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions),(select count(*)from private.offline_history_scope_consents),(select count(*)from private.offline_visit_wallet_read_consents))into v_counts;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_customer,'session_id',v_session)::text,true);perform set_config('request.jwt.claim.sub',p_customer::text,true);
 execute 'set local role authenticated';
 v_view:=public.get_my_offline_reward_financial_proposal(p_proposal);
 assert v_view->>'state'='proposal'and not(v_view->>'redemption_enabled')::boolean and not(v_view->>'reward_issued')::boolean;
 assert(v_view#>>'{terms,gross_amount}')::numeric>0 and v_view#>'{terms,gross_amount}'=v_view#>'{terms,reward_discount}'and v_view#>>'{terms,amount_due}'='0';
 assert (v_view->'terms')-array['service','branch','unit','visits','gross_amount','reward_discount','amount_due','currency','rules','expires_at']='{}'::jsonb,'No identity/allocation/private source disclosure';
 assert(public.get_my_offline_reward_financial_proposal(null))->>'proposal_id'=p_proposal::text,'Own latest proposal discoverable without another customer reference';
 assert public.get_my_offline_reward_financial_proposal(gen_random_uuid())->>'state'='unavailable';
 assert public.get_my_offline_reward_financial_consent(v_nonce)->>'state'='absent';
 v_consent:=jsonb_build_object('accepted',true,'version','offline-reward-financial-v1','language','ar','text',v_view#>>'{consent,notice_ar}');
 v_denied:=false;begin perform public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent||'{"version":"offline-wallet-read-v1"}');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied,'Read consent cannot authorize financial use';
 v_denied:=false;begin perform public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,repeat('a',64),v_consent);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_first:=public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent);
 assert v_first->>'state'='consent_recorded'and not(v_first->>'issuer_enabled')::boolean;
 assert public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent)=v_first;
 assert public.get_my_offline_reward_financial_consent(v_nonce)=v_first,'Restart recovers exact server-retained assent';
 v_denied:=false;begin perform public.accept_my_offline_reward_financial_consent(v_nonce,p_proposal,v_view->>'fingerprint',v_consent||'{"language":"en"}');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 assert public.revoke_my_offline_reward_financial_consent(v_revoke,v_nonce)->>'state'='revoked';
 assert public.revoke_my_offline_reward_financial_consent(v_revoke,v_nonce)->>'state'='revoked';
 assert public.revoke_my_offline_reward_financial_consent(gen_random_uuid(),v_nonce)->>'state'='revoked';
 v_denied:=false;begin perform public.revoke_my_offline_reward_financial_consent(v_revoke,v_unknown);exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 assert public.revoke_my_offline_reward_financial_consent(gen_random_uuid(),v_unknown)->>'state'='revoked';
 assert public.accept_my_offline_reward_financial_consent(v_unknown,p_proposal,v_view->>'fingerprint',v_consent)->>'state'='revoked','Unknown nonce tombstone fences delayed acceptance';
 execute 'reset role';
 assert(select consent from private.offline_reward_financial_consents where request_id=v_nonce)=v_consent;
 v_denied:=false;begin delete from private.offline_reward_financial_consents where request_id=v_nonce;exception when others then v_denied:=true;end;assert v_denied;
 assert v_counts=jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions),(select count(*)from private.offline_history_scope_consents),(select count(*)from private.offline_visit_wallet_read_consents));
 perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);
end$$;

-- Existing OTHER customer/session only; no new account/link or guessed identity.
create function pg_temp.assert_other_customer_financial_scope_denied(p_other uuid,p_proposal uuid,p_consent_request uuid)returns void language plpgsql as $$
declare v_claims text:=current_setting('request.jwt.claims',true);v_sub text:=current_setting('request.jwt.claim.sub',true);v_session uuid;v_denied boolean:=false;v_result jsonb;
begin
 select id into strict v_session from auth.sessions where user_id=p_other and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_other,'session_id',v_session)::text,true);perform set_config('request.jwt.claim.sub',p_other::text,true);
 execute 'set local role authenticated';
 begin v_result:=public.get_my_offline_reward_financial_proposal(p_proposal);v_denied:=v_result->>'state'='unavailable';exception when insufficient_privilege then v_denied:=true;end;
 assert v_denied,'Foreign actual customer must receive no proposal terms';
 v_denied:=false;begin perform public.get_my_offline_reward_financial_consent(p_consent_request);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 execute 'reset role';perform set_config('request.jwt.claims',coalesce(v_claims,'{}'),true);perform set_config('request.jwt.claim.sub',coalesce(v_sub,''),true);
end$$;
