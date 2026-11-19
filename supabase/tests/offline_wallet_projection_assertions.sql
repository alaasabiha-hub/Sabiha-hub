-- SOURCE helper for root's REAL offline-kernel fixture; no source/ledger/test bypass.
-- Load before component test; call after earn, after refund-before-reconcile, after reversal.
-- This temporary assertion deliberately does not recreate accepted financial setup.
create function pg_temp.assert_offline_wallet_projection(p_profile uuid,p_earned integer,p_effective_refunded integer,p_ledger_reversed integer,p_unclaimed integer,p_pending_reversal integer)returns void language plpgsql as $$
declare result jsonb;observed integer;
begin
 result:=private.offline_visit_wallet_projection(p_profile);
 assert result->>'state'='available_read_only'and result->>'unit'='service_visits'and result->>'owner_kind'='offline_profile';
 assert(result->>'recorded_earned_visits')::integer=p_earned;
 assert(result->>'effective_refunded_visits')::integer=p_effective_refunded;
 assert(result->>'ledger_reversed_visits')::integer=p_ledger_reversed;
 assert(result->>'actual_refunds_awaiting_reversal')::integer=p_pending_reversal;
 select coalesce(sum((item->>'recorded_unclaimed_valid_visits')::integer),0)into observed from jsonb_array_elements(result->'cohorts')item;
 assert observed=p_unclaimed;
 assert result->'global_spendable_balance'='null'::jsonb and result->'debt_adjusted_spendable_visits'='null'::jsonb and result->>'redemption_enabled'='false';
 assert not(result::text~'(target_customer_ids|target_offline_profile_ids|terms_snapshot|offline_profile_id|customer_id|commission|secret_hash)');
end$$;
