-- Load in root's real offline component fixture for POSITIVE real-writer assertions.
-- Call after earning with p_expected_count=1, after actual refund with=0 (before/after reversal).
create function pg_temp.assert_offline_candidate_planner(p_profile uuid,p_rules uuid,p_channel uuid,p_expected_count integer)returns void language plpgsql as $$
declare before_claims bigint;before_reviews bigint;actual integer;plan jsonb;denied boolean;
begin
 select count(*)into before_claims from private.reward_credit_claims;select count(*)into before_reviews from private.reward_refund_reviews;
 select count(*)into actual from private.reward_owner_candidate_lots('offline_profile',p_profile,p_rules,p_channel);assert actual=p_expected_count;
 plan:=private.plan_reward_owner_candidates('offline_profile',p_profile,p_rules,p_channel);
 assert plan @>'{"plan_only":true,"unit":"service_visits","reservation_created":false,"commit_eligible":false,"spendable_balance":null,"debt_adjusted_balance":null}';
 assert(plan->>'candidate_count')::integer=least(p_expected_count,(plan->>'required_visits')::integer);
 assert not exists(select 1 from jsonb_array_elements(plan->'allocation_candidates')candidate where candidate#>>'{credit_terms,adoption_required}'is distinct from'false');
 assert not exists(select 1 from private.reward_owner_candidate_lots('offline_profile',p_profile,p_rules,p_channel)lot join private.canonical_loyalty_visits e on e.id=lot.earning_id where e.customer_id is not null or e.offline_profile_id is distinct from p_profile or e.source_channel<>'offline_walk_in');
 denied:=false;begin perform private.reward_owner_candidate_lots('auth_customer',p_profile,p_rules,p_channel);exception when invalid_parameter_value then denied:=true;end;assert denied,'Wrong namespace/channel must reject even if UUIDs collide';
 assert(select count(*)from private.reward_credit_claims)=before_claims;
 assert(select count(*)from private.reward_refund_reviews)=before_reviews;
end$$;
