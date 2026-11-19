begin;
-- Internal planning only; not an operator endpoint and not a balance reservation.
create function private.quote_sealed_mixed_loyalty(p_branch uuid,p_intent uuid,p_policy uuid,p_points bigint)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;i private.cashier_loyalty_draft_intents;v private.mixed_points_policy_versions;status jsonb;result jsonb;
begin
 actor:=private.cashier_cart_actor(p_branch);
 status:=private.get_cashier_loyalty_draft_intent(p_branch,p_intent);
 if status->>'state'is distinct from'current'then raise exception 'Current sealed draft required'using errcode='40001';end if;
 select *into i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=actor and branch_id=p_branch;
 select v0.*into v from private.mixed_points_policy_versions v0 join private.mixed_points_policy_current c on c.version_id=v0.version_id where c.branch_id=p_branch and v0.version_id=p_policy for share of c;
 if not found then raise exception 'Explicit current owner policy required'using errcode='40001';end if;
 if v.rules->>'allow_walk_in'is distinct from'true'then raise exception 'Walk-in loyalty not permitted'using errcode='42501';end if;
 status:=private.get_cashier_loyalty_draft_intent(p_branch,p_intent);
 if status->>'state'is distinct from'current'then raise exception 'Seal expired while waiting'using errcode='40001';end if;
 result:=private.mixed_loyalty_discount_core(i.witness->'quote',v.rules,p_points);
 return result||jsonb_build_object('intent_id',p_intent,'intent_fingerprint',i.fingerprint,'policy_version_id',p_policy,'policy_version',v.version,'consent_authorized',false,'balance_reserved',false,'redemption_enabled',false);
end$$;
revoke all on function private.quote_sealed_mixed_loyalty(uuid,uuid,uuid,bigint)from public,anon,authenticated,service_role;
create function private.mixed_loyalty_customer_terms(p_plan jsonb)returns jsonb
language sql immutable security invoker set search_path=pg_catalog as $$
 select jsonb_build_object('currency','EGP','points',p_plan->'loyalty_points','value_basis',p_plan->'loyalty_value_basis','amount_due',p_plan->'total','payable_discount',p_plan->'loyalty_payable_reduction',
 'lines',(select jsonb_agg(jsonb_build_object('name',v->'name','name_en',v->'name_en','quantity',v->'quantity','net_amount',v->'net_amount_exact','tax_amount',v->'tax_amount_exact','loyalty_discount',v->'loyalty_gross_discount_exact','amount',v->'refundable_amount')order by v->>'line_id')from jsonb_array_elements(p_plan->'lines')v),
 'payment_confirmed',false,'balance_reserved',false)
$$;
revoke all on function private.mixed_loyalty_customer_terms(jsonb)from public,anon,authenticated,service_role;
commit;
