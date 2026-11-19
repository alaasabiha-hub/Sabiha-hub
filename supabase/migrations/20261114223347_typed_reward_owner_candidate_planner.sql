begin;
-- Private candidate component only. No schema nullability/claim/debt/spend enable change.
create function private.reward_owner_candidate_lots(p_owner_kind text,p_owner uuid,p_rules uuid,p_channel uuid default null)
returns table(earning_id uuid,credit_terms jsonb,earned_at timestamptz)language plpgsql stable security definer set search_path=pg_catalog as $$
declare selected private.offline_visit_channel_versions;selected_rules private.loyalty_redemption_rule_versions;
begin
 if p_owner is null or p_rules is null or p_owner_kind is null or p_owner_kind not in('auth_customer','offline_profile')then raise exception 'Explicit typed owner/rules required'using errcode='22023';end if;
 if p_owner_kind='auth_customer'then
  if p_channel is not null or not exists(select 1 from public.customers where id=p_owner)then raise exception 'Actual Auth owner without offline channel required'using errcode='22023';end if;
  -- Exact accepted Auth cohort/expiry selector; do not substitute an offline UUID.
  return query select l.earning_id,l.credit_terms,l.earned_at from private.reward_program_lots(p_owner,p_rules)l;return;
 end if;
 if p_channel is null or not exists(select 1 from private.offline_customer_profiles where profile_id=p_owner)then raise exception 'Actual offline owner/channel required'using errcode='22023';end if;
 select *into selected from private.offline_visit_channel_versions where version_id=p_channel and rules_version_id=p_rules;
 select *into selected_rules from private.loyalty_redemption_rule_versions where rules_version_id=p_rules;
 if selected.version_id is null or not selected.enabled or selected_rules.rules_version_id is null
 or not exists(select 1 from private.offline_visit_channel_activations where channel_version_id=selected.version_id)
 or(selected.target_offline_profile_ids is not null and not(p_owner=any(selected.target_offline_profile_ids)))then return;end if;
 -- Frozen ORIGINAL expiry/rules and explicit selected overlay; never latest/adopt here.
 return query
 select e.id,t.details,e.created_at
 from private.canonical_loyalty_visits e
 join private.offline_service_visit_order_snapshots s on s.order_id=e.offline_order_snapshot_id and s.offline_profile_id=e.offline_profile_id and s.earning_authorized
 join private.offline_visit_channel_versions original on original.version_id=s.channel_version_id
 join private.offline_visit_channel_activations a on a.activation_id=e.offline_activation_id and a.channel_version_id=original.version_id
 join private.reward_earning_terms bound on bound.earning_id=e.id and bound.rules_version_id=original.rules_version_id
 join private.loyalty_redemption_rule_versions frozen_rules on frozen_rules.rules_version_id=bound.rules_version_id
 cross join lateral(select private.reward_credit_terms(e.id,p_rules)details)t
 where e.source_channel='offline_walk_in'and e.customer_id is null and e.offline_profile_id=p_owner and e.kind='earn'
 and e.branch_id=selected.branch_id and frozen_rules.branch_id=selected_rules.branch_id and frozen_rules.offer_id=selected_rules.offer_id
 and selected.version_no>=original.version_no
 and(selected_rules.rules->>'pooling'='offer_branch'or e.policy_version_id=selected.policy_version_id)
 and private.reward_credit_refund(e.id)is null
 and not exists(select 1 from private.canonical_loyalty_visits rev where rev.reverses_earning=e.id and rev.kind='refund')
 and not exists(select 1 from private.reward_credit_claims c where c.earning_id=e.id and c.released_at is null)
 and coalesce((t.details->>'valid')::boolean,false)and coalesce((t.details->>'adoption_required')::boolean,false)=false
 order by(t.details->>'expires_at')::timestamptz nulls last,e.created_at,e.id;
end$$;

create function private.plan_reward_owner_candidates(p_owner_kind text,p_owner uuid,p_rules uuid,p_channel uuid default null)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare rules private.loyalty_redemption_rule_versions;needed integer;ids uuid[];allocations jsonb;recorded_debt jsonb;pending_refund_claims integer;
begin
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=p_rules;
 if rules.rules_version_id is null then raise exception 'Actual immutable rules required'using errcode='22023';end if;
 needed:=(rules.terms_snapshot->>'threshold_visits')::integer;
 if needed is null or needed not between 1 and 1000 then raise exception 'Bounded actual visit threshold required'using errcode='22023';end if;
 select coalesce(array_agg(l.earning_id order by l.ordinality),'{}'::uuid[]),coalesce(jsonb_agg(jsonb_build_object('earning_id',l.earning_id,'credit_terms',l.credit_terms)order by l.ordinality),'[]'::jsonb)
 into ids,allocations from(select candidate.*,row_number()over(order by(candidate.credit_terms->>'expires_at')::timestamptz nulls last,candidate.earned_at,candidate.earning_id)ordinality
 from private.reward_owner_candidate_lots(p_owner_kind,p_owner,p_rules,p_channel)candidate
 order by(candidate.credit_terms->>'expires_at')::timestamptz nulls last,candidate.earned_at,candidate.earning_id limit needed)l;
 if p_owner_kind='auth_customer'then
 recorded_debt:=private.reward_program_blockers(p_owner,p_rules);
 select count(distinct c.claim_id)into pending_refund_claims from private.reward_credit_claims c join private.service_reward_redemptions d on d.redemption_id=c.redemption_id join private.service_reward_quotes q on q.quote_id=d.quote_id
 where c.customer_id=p_owner and c.kind='reward'and c.released_at is null and d.state in('covered','forfeited')
 and d.branch_id=rules.branch_id and(q.terms_snapshot->>'offer_id')::uuid=rules.offer_id and private.reward_credit_refund(c.earning_id)is not null
 and not exists(select 1 from private.reward_refund_reviews review where review.original_claim_id=c.claim_id and review.refund_payment_id=private.reward_credit_refund(c.earning_id));
 else recorded_debt:=null;pending_refund_claims:=null;end if;
 return jsonb_build_object('plan_only',true,'unit','service_visits','owner_kind',p_owner_kind,'selected_channel_version_id',p_channel,'rules_version_id',p_rules,
 'required_visits',needed,'candidate_count',cardinality(ids),'threshold_met',cardinality(ids)=needed,'candidate_ids',ids,'allocation_candidates',allocations,
 'reservation_created',false,'commit_eligible',false,'spendable_balance',null,'debt_adjusted_balance',null,
 'recorded_auth_debt',recorded_debt,'auth_refunded_claims_awaiting_sync',pending_refund_claims,
 'debt_state',case when p_owner_kind='offline_profile'then'typed_debt_kernel_not_implemented'else'read_only_not_synchronized'end,
 'blockers',jsonb_build_array('candidate_plan_is_not_a_quote_or_reservation','actual_refund_resync_and_relock_required','typed_claim_quote_redemption_review_schema_pending','independent_financial_consent_pending','coverage_issuer_commission_pending'));
end$$;
revoke all on function private.reward_owner_candidate_lots(text,uuid,uuid,uuid),private.plan_reward_owner_candidates(text,uuid,uuid,uuid)from public,anon,authenticated,service_role;
commit;
