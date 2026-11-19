-- SOURCE ONLY helper loaded into a root-reviewed real earned-credit rollback
-- fixture. Do NOT invent earning rows or relax runtime gates in this helper.
create function pg_temp.assert_offline_consumption_preparation(p_profile uuid,p_car uuid,p_channel uuid,p_gross numeric)returns void language plpgsql as $$
declare v_reservation uuid:=gen_random_uuid();v_nonce uuid:=gen_random_uuid();v_hold jsonb;v_prepared jsonb;v_closed jsonb;v_denied boolean;v_original jsonb;v_counts jsonb;v_next_reservation uuid:=gen_random_uuid();v_next_nonce uuid:=gen_random_uuid();
begin
 select jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions),(select count(*)from private.reward_refund_reviews))into v_counts;
 v_hold:=private.reserve_offline_reward_candidates(v_reservation,p_profile,p_car,p_channel,p_gross);
 v_prepared:=private.prepare_offline_reward_consumption(v_nonce,v_reservation,v_hold->>'fingerprint');
 assert v_prepared->>'state'='prepared'and(v_prepared->>'hold_current')::boolean;
 assert not(v_prepared->>'consumption_enabled')::boolean and not(v_prepared->>'issuer_enabled')::boolean and not(v_prepared->>'financial_consent_recorded')::boolean;
 assert v_prepared#>>'{witness,owner_kind}'='offline_profile'and(v_prepared#>>'{witness,offline_profile_id}')::uuid=p_profile;
 assert(v_prepared#>>'{witness,gross_amount}')::numeric=p_gross and v_prepared#>>'{witness,amount_due}'='0';
 assert private.prepare_offline_reward_consumption(v_nonce,v_reservation,v_hold->>'fingerprint')=v_prepared;
 assert private.get_offline_reward_consumption_preparation(v_nonce)=v_prepared,'UUID-only restart recovers exact server witness';
 v_denied:=false;begin perform private.prepare_offline_reward_consumption(v_nonce,v_reservation,repeat('b',64));exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin perform private.prepare_offline_reward_consumption(gen_random_uuid(),v_reservation,v_hold->>'fingerprint');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'One immutable preparation per hold';
 select witness into v_original from private.offline_reward_consumption_preparations where request_id=v_nonce;
 v_denied:=false;begin update private.offline_reward_consumption_preparations set witness='{}'where request_id=v_nonce;exception when others then v_denied:=true;end;assert v_denied;
 v_closed:=private.close_offline_reward_consumption(v_nonce,'Explicitly close unconsumed private preparation');
 assert v_closed->>'state'='closed'and(v_closed->>'definitive_failure')::boolean;
 assert private.prepare_offline_reward_consumption(v_nonce,v_reservation,v_hold->>'fingerprint')=v_closed;
 assert not exists(select 1 from private.reward_credit_claims where reserve_request_id=v_reservation and released_at is null);
 assert(select witness from private.offline_reward_consumption_preparations where request_id=v_nonce)=v_original;
 -- A release through the existing accepted API must invalidate, never rewrite,
 -- the preparation. The same real credits can be held again only as a NEW hold.
 v_hold:=private.reserve_offline_reward_candidates(v_next_reservation,p_profile,p_car,p_channel,p_gross);
 perform private.prepare_offline_reward_consumption(v_next_nonce,v_next_reservation,v_hold->>'fingerprint');
 perform private.release_offline_reward_reservation(v_next_reservation,'External accepted release invalidates preparation');
 v_prepared:=private.get_offline_reward_consumption_preparation(v_next_nonce);
 assert v_prepared->>'state'='prepared'and not(v_prepared->>'hold_current')::boolean;
 perform private.close_offline_reward_consumption(v_next_nonce,'Close already invalidated private preparation');
 assert v_counts=jsonb_build_array((select count(*)from public.business_invoices),(select count(*)from public.business_payment_events),(select count(*)from private.service_reward_redemptions),(select count(*)from private.reward_refund_reviews));
 set constraints all immediate;set constraints all deferred;
end$$;

-- Invoke after an ACTUAL refund of a held source has committed (before worker
-- reconciliation is also valid). This helper performs no payment/refund itself.
create function pg_temp.assert_refunded_hold_cannot_prepare(p_reservation uuid,p_fingerprint text)returns void language plpgsql as $$
declare v_nonce uuid:=gen_random_uuid();v_denied boolean:=false;
begin
 begin perform private.prepare_offline_reward_consumption(v_nonce,p_reservation,p_fingerprint);exception when object_not_in_prerequisite_state then v_denied:=true;end;
 assert v_denied,'Committed actual source refund must block preparation';
 assert not exists(select 1 from private.offline_reward_consumption_preparations where request_id=v_nonce);
end$$;
