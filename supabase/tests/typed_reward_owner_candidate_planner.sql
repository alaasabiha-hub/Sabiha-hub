-- SOURCE ONLY rollback negative/compatibility tests; root controls LOCAL execution.
begin;
do $$
declare customer uuid;rules_id uuid;expected jsonb;actual jsonb;denied boolean;before_claims bigint;before_reviews bigint;
begin
 select id into strict customer from public.customers order by id limit 1;
 select rules_version_id into strict rules_id from private.loyalty_redemption_rule_versions order by version_no limit 1;
 select count(*)into before_claims from private.reward_credit_claims;select count(*)into before_reviews from private.reward_refund_reviews;
 assert not has_function_privilege('authenticated','private.reward_owner_candidate_lots(text,uuid,uuid,uuid)','EXECUTE');
 assert not has_function_privilege('service_role','private.plan_reward_owner_candidates(text,uuid,uuid,uuid)','EXECUTE');
 select coalesce(jsonb_agg(jsonb_build_object('earning_id',l.earning_id,'credit_terms',l.credit_terms,'earned_at',l.earned_at)order by l.earning_id),'[]'::jsonb)into expected from private.reward_program_lots(customer,rules_id)l;
 select coalesce(jsonb_agg(jsonb_build_object('earning_id',l.earning_id,'credit_terms',l.credit_terms,'earned_at',l.earned_at)order by l.earning_id),'[]'::jsonb)into actual from private.reward_owner_candidate_lots('auth_customer',customer,rules_id,null)l;
 assert actual=expected,'Auth candidate shape/cohorts changed';
 denied:=false;begin perform private.reward_owner_candidate_lots(null,customer,rules_id,null);exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform private.reward_owner_candidate_lots('auth_customer',customer,rules_id,gen_random_uuid());exception when invalid_parameter_value then denied:=true;end;assert denied;
 denied:=false;begin perform private.reward_owner_candidate_lots('offline_profile',customer,rules_id,null);exception when invalid_parameter_value then denied:=true;end;assert denied,'Bare UUID must not infer guest owner';
 assert(select count(*)from private.reward_credit_claims)=before_claims;
 assert(select count(*)from private.reward_refund_reviews)=before_reviews;
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
end$$;
rollback;

