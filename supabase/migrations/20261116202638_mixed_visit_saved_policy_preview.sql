begin;
-- Internal preview using an actual saved current owner policy.
-- No reservation, assent, issuance or public execution is enabled.
create function private.preview_saved_mixed_visit_candidates(p_branch uuid,p_intent uuid,p_rules uuid,p_channel uuid,p_line text,p_units bigint,p_policy uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;i private.cashier_loyalty_draft_intents;rules private.loyalty_redemption_rule_versions;
 settings private.owner_mixed_visit_policy_versions;state jsonb;kind text;subject uuid;needed numeric;candidate_count bigint;rules_for_math jsonb;quote jsonb;clear boolean;fp text;
begin
 actor:=private.cashier_cart_actor(p_branch);
 if private.active_staff_role()is distinct from'owner'then raise exception 'Live owner preview required'using errcode='42501';end if;
 if p_intent is null or p_rules is null or p_line is null or p_units is null or p_units<=0 or p_policy is null then raise exception 'Exact draft, benefit, units and saved owner policy required'using errcode='22023';end if;
 select v.*into settings from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules for share of c;
 if not found or settings.version_id<>p_policy then raise exception 'Current saved owner visit policy required'using errcode='40001';end if;
 if settings.terms->>'allow_walk_in'is distinct from'true'then raise exception 'Owner has not permitted mixed walk-in visit coverage'using errcode='42501';end if;
 state:=private.get_cashier_loyalty_draft_intent(p_branch,p_intent);
 if state->>'state'is distinct from'current'then raise exception 'Review and reseal current draft first'using errcode='40001';end if;
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=p_intent and actor_id=actor and branch_id=p_branch;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=p_rules and branch_id=p_branch;
 if not found or(i.witness->>'subject_kind'='app_customer'and not exists(select 1 from private.reward_rule_activations where rules_version_id=p_rules))then raise exception 'Actual activated benefit terms required'using errcode='22023';end if;
 if settings.source_terms_hash<>encode(extensions.digest(rules.terms_snapshot::text,'sha256'),'hex')then raise exception 'Owner policy benefit terms mismatch'using errcode='40001';end if;
 if rules.rules->>'expiry'='snapshot_offer_end'and coalesce((rules.terms_snapshot#>>'{offer,ends_at}')::timestamptz<=clock_timestamp(),true)then raise exception 'Benefit snapshot expired'using errcode='55000';end if;
 kind:=case i.witness->>'subject_kind'when'app_customer'then'auth_customer'when'offline_profile'then'offline_profile'else null end;
 subject:=(i.witness->>'subject')::uuid;
 if kind is null then raise exception 'Typed bound customer required'using errcode='22023';end if;
 if kind='auth_customer'then
 if p_channel is not null then raise exception 'Auth customer cannot borrow an offline channel'using errcode='22023';end if;
 clear:=coalesce((private.reward_program_blockers(subject,p_rules)->>'eligible')::boolean,false);
 else
 if p_channel is null or not exists(select 1 from private.offline_visit_channel_versions c join private.offline_visit_channel_activations a on a.channel_version_id=c.version_id where c.version_id=p_channel and c.rules_version_id=p_rules and c.branch_id=p_branch and c.enabled)then raise exception 'Actual activated offline benefit channel required'using errcode='22023';end if;
 clear:=private.offline_reward_debt_clear(subject,p_rules);
 end if;
 -- This is the existing typed selector: no legacy point conversion, adoption,
 -- phone matching, cached balance or private source UUIDs returned to clients.
 select count(*)into candidate_count from private.reward_owner_candidate_lots(kind,subject,p_rules,p_channel);
 needed:=(rules.terms_snapshot->>'threshold_visits')::numeric*p_units;
 if needed is null or needed<=0 or needed<>trunc(needed)then raise exception 'Actual visit threshold required'using errcode='22023';end if;
 if not clear or candidate_count<needed then return jsonb_build_object('unit','service_visits','preview_only',true,'candidate_threshold_met',false,'candidate_count',candidate_count,'required_visits',needed,'review_required',not clear,'quote',null,'balance_reserved',false,'consent_authorized',false,'redemption_enabled',false,'tax_choice_saved',true,'owner_policy_id',settings.version_id);end if;
 rules_for_math:=settings.terms||jsonb_build_object('reward_item_id',rules.terms_snapshot#>>'{reward_service,id}','threshold_visits',rules.terms_snapshot->'threshold_visits');
 quote:=private.mixed_visit_coverage_core(i.witness->'quote',rules_for_math,p_line,p_units);
 fp:=encode(extensions.digest(jsonb_build_object('intent',i.fingerprint,'rules_version',p_rules,'channel',p_channel,'line',p_line,'units',p_units,'owner_policy_id',settings.version_id,'source_terms_hash',settings.source_terms_hash,'quote',quote)::text,'sha256'),'hex');
 perform private.require_typed_reward_document_session(actor);
 if private.active_staff_role()is distinct from'owner'then raise exception 'Live owner preview required'using errcode='42501';end if;
 return jsonb_build_object('unit','service_visits','preview_only',true,'candidate_threshold_met',true,'candidate_count',candidate_count,'required_visits',needed,'rules_version_id',p_rules,'intent_fingerprint',i.fingerprint,'preview_fingerprint',fp,'quote',quote,'expires_at',i.expires_at,'balance_reserved',false,'consent_authorized',false,'redemption_enabled',false,'tax_choice_saved',true,'owner_policy_id',settings.version_id,'issuance_blockers',jsonb_build_array('atomic_relock_reservation_and_source_refund_resync_required','verbal_assent_invoice_and_collection_adapters_required','covered_unit_work_refund_and_cancellation_adapters_required'));
end$$;
revoke all on function private.preview_saved_mixed_visit_candidates(uuid,uuid,uuid,uuid,text,bigint,uuid)from public,anon,authenticated,service_role;
commit;
