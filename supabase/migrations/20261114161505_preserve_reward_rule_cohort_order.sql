begin;
-- A later earning cohort cannot escape its terms by selecting an older rule.
-- Explicit offer/branch pooling still lets a new consented benefit use older credits.
create or replace function private.reward_credit_terms(p_earning uuid,p_proposed_rules uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare original uuid;frozen_rules private.loyalty_redemption_rule_versions;selected_rules private.loyalty_redemption_rule_versions;latest_activated uuid;deadline timestamptz;
begin
 select * into selected_rules from private.loyalty_redemption_rule_versions where rules_version_id=p_proposed_rules;
 if selected_rules.rules_version_id is null then return jsonb_build_object('valid',false,'reason','explicit_rules_required');end if;
 select rules_version_id into original from private.reward_earning_terms where earning_id=p_earning;
 if original is null then
 select rules.rules_version_id into latest_activated from private.loyalty_redemption_rule_versions rules join private.reward_rule_activations activation using(rules_version_id)where rules.policy_version_id=selected_rules.policy_version_id order by rules.version_no desc limit 1;
 if latest_activated is distinct from p_proposed_rules then return jsonb_build_object('valid',false,'reason','latest_activated_rules_required_for_adoption');end if;
 frozen_rules:=selected_rules;
 else
 select * into frozen_rules from private.loyalty_redemption_rule_versions where rules_version_id=original;
 if frozen_rules.rules_version_id is null then return jsonb_build_object('valid',false,'reason','original_rules_missing');end if;
 if selected_rules.version_no<frozen_rules.version_no then return jsonb_build_object('valid',false,'reason','newer_bound_rules_required');end if;
 end if;
 if frozen_rules.rules->>'expiry'='snapshot_offer_end' then
 deadline:=(frozen_rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz;
 if deadline is null then return jsonb_build_object('valid',false,'reason','frozen_expiry_missing');end if;
 end if;
 return jsonb_build_object('valid',deadline is null or deadline>clock_timestamp(),'expires_at',deadline,'adoption_required',original is null,'original_rules_version_id',original,'effective_rules_version_id',frozen_rules.rules_version_id);
end $$;
-- Existing execute restrictions remain unchanged by CREATE OR REPLACE.
commit;
