begin;
-- Explicit owner choices only. This migration cannot activate reward redemption.
create table private.loyalty_redemption_rule_versions(
 version_no bigint generated always as identity primary key,rules_version_id uuid not null unique,
 policy_version_id uuid not null references private.loyalty_policy_versions(version_id),branch_id uuid not null references public.business_branches(branch_id),offer_id uuid not null references public.business_offers(offer_id),
 rules jsonb not null,terms_snapshot jsonb not null,created_by uuid not null references public.staff_profiles(user_id),created_at timestamptz not null default clock_timestamp(),
 check(jsonb_typeof(rules)='object' and rules ?& array['pooling','expiry','cancellation','refunded_contribution'] and rules-array['pooling','expiry','cancellation','refunded_contribution']='{}'::jsonb
 and coalesce(rules->>'pooling' in ('policy_version','offer_branch'),false) and coalesce(rules->>'expiry' in ('no_expiry','snapshot_offer_end'),false)
 and coalesce(rules->>'cancellation' in ('restore_visits','forfeit_visits'),false) and coalesce(rules->>'refunded_contribution' in ('offset_future_visits','freeze_for_owner_review'),false)));
create index redemption_rules_policy_latest on private.loyalty_redemption_rule_versions(policy_version_id,version_no desc);
create table private.loyalty_redemption_rule_requests(request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.loyalty_redemption_rule_versions enable row level security;
alter table private.loyalty_redemption_rule_requests enable row level security;
revoke all on private.loyalty_redemption_rule_versions,private.loyalty_redemption_rule_requests from public,anon,authenticated,service_role;
create trigger immutable_redemption_rules before update or delete on private.loyalty_redemption_rule_versions for each row execute function private.immutable_loyalty_policy();
create trigger immutable_redemption_rule_request before update or delete on private.loyalty_redemption_rule_requests for each row execute function private.immutable_loyalty_policy();
create function private.get_loyalty_redemption_rules(p_policy_version uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare v private.loyalty_policy_versions;o public.business_offers;r public.business_catalog_items;current_rules private.loyalty_redemption_rule_versions;
 service_id uuid;threshold integer;save_blockers text[]:='{}';blockers text[]:=array['redemption_quote_not_implemented','booking_redemption_not_implemented','visit_reservation_not_implemented','visit_consumption_not_implemented','visit_release_not_implemented','reward_invoice_document_state_not_implemented','refunded_contribution_resolution_not_implemented'];terms_ok boolean;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select * into v from private.loyalty_policy_versions where version_id=p_policy_version;
 if v.version_id is null then raise exception 'Actual saved loyalty policy version required' using errcode='22023';end if;
 select * into o from public.business_offers where offer_id=v.offer_id;
 service_id:=(v.policy_snapshot->>'reward_item_id')::uuid;threshold:=(v.policy_snapshot->>'threshold_visits')::integer;
 select * into r from public.business_catalog_items where item_id=service_id;
 select * into current_rules from private.loyalty_redemption_rule_versions where policy_version_id=v.version_id order by version_no desc limit 1;
 if exists(select 1 from private.loyalty_policy_versions newer where newer.branch_id=v.branch_id and newer.version_no>v.version_no) then save_blockers:=array_append(save_blockers,'policy_not_current');end if;
 if not coalesce(o.is_active and o.is_public,false) then save_blockers:=array_append(save_blockers,'offer_not_active_or_public');end if;
 if o.offer_type is distinct from 'visit_reward' or o.reward_item_id is distinct from service_id or o.visits_required is distinct from threshold
 or (o.branch_id is not null and o.branch_id<>v.branch_id)
 or coalesce(to_jsonb(o.branch_id),'null'::jsonb) is distinct from v.policy_snapshot->'offer_branch_id'
 or coalesce(to_jsonb(o.target_customer_ids),'null'::jsonb) is distinct from v.policy_snapshot->'target_customer_ids'
 or o.starts_at is distinct from (v.policy_snapshot->>'offer_starts_at')::timestamptz or o.ends_at is distinct from (v.policy_snapshot->>'offer_ends_at')::timestamptz then save_blockers:=array_append(save_blockers,'offer_terms_changed');end if;
 if threshold is null or threshold not between 1 and 100000 then save_blockers:=array_append(save_blockers,'threshold_invalid');end if;
 if service_id is null then save_blockers:=array_append(save_blockers,'reward_service_missing');
 elsif r.item_id is null or r.branch_id<>v.branch_id or r.item_type<>'service' or not r.is_active or not r.is_public then save_blockers:=array_append(save_blockers,'reward_service_unavailable');end if;
 terms_ok:=cardinality(save_blockers)=0 and current_rules.rules_version_id is not null;
 blockers:=blockers||save_blockers;
 if current_rules.rules_version_id is null then blockers:=array_append(blockers,'redemption_rules_not_saved');end if;
 if not v.enabled then blockers:=array_append(blockers,'policy_not_enabled');end if;
 if not exists(select 1 from private.loyalty_visit_activations where policy_version_id=v.version_id) then blockers:=array_append(blockers,'earning_not_activated');end if;
 if current_rules.rules->>'expiry'='snapshot_offer_end' then
  if v.policy_snapshot->>'offer_ends_at' is null then terms_ok:=false;blockers:=array_append(blockers,'expiry_deadline_missing');
  elsif (v.policy_snapshot->>'offer_ends_at')::timestamptz<=clock_timestamp() then terms_ok:=false;blockers:=array_append(blockers,'expiry_deadline_passed');end if;
 end if;
 if current_rules.rules->>'refunded_contribution'='freeze_for_owner_review' then blockers:=array_append(blockers,'owner_refund_review_resolution_not_implemented');end if;
 return jsonb_build_object('policy_version_id',v.version_id,'policy_version_no',v.version_no,'branch_id',v.branch_id,'offer_id',v.offer_id,'threshold_visits',threshold,
 'reward_service',case when service_id is null then null else jsonb_build_object('id',service_id,'name',r.name,'is_active',coalesce(r.is_active,false),'is_public',coalesce(r.is_public,false),'branch_id',r.branch_id) end,
 'offer',jsonb_build_object('name',v.policy_snapshot->>'offer_name','starts_at',v.policy_snapshot->'offer_starts_at','ends_at',v.policy_snapshot->'offer_ends_at','current_is_active',o.is_active,'current_is_public',o.is_public),
 'current',case when current_rules.rules_version_id is null then null else to_jsonb(current_rules) end,'rules_saved',current_rules.rules_version_id is not null,'configuration_valid',cardinality(save_blockers)=0,'terms_valid',terms_ok,
 'redemption_enabled',false,'readiness','rules_only','blockers',to_jsonb(blockers),'save_blockers',to_jsonb(save_blockers),
 'supported_rules',jsonb_build_object('pooling',jsonb_build_array('policy_version','offer_branch'),'expiry',jsonb_build_array('no_expiry','snapshot_offer_end'),'cancellation',jsonb_build_array('restore_visits','forfeit_visits'),'refunded_contribution',jsonb_build_array('offset_future_visits','freeze_for_owner_review')),
 'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.version_no desc) from(select * from private.loyalty_redemption_rule_versions where policy_version_id=v.version_id order by version_no desc limit 50)h),'[]'::jsonb));
end;$$;
create function private.save_loyalty_redemption_rules(p_request uuid,p_policy_version uuid,p_expected_rules_version uuid,p_rules jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v private.loyalty_policy_versions;prior private.loyalty_redemption_rule_requests;latest uuid;payload jsonb;context jsonb;snapshot jsonb;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_policy_version is null or p_rules is null or jsonb_typeof(p_rules)<>'object' or not p_rules ?& array['pooling','expiry','cancellation','refunded_contribution']
 or p_rules-array['pooling','expiry','cancellation','refunded_contribution']<>'{}'::jsonb
 or not coalesce(p_rules->>'pooling' in ('policy_version','offer_branch'),false) or not coalesce(p_rules->>'expiry' in ('no_expiry','snapshot_offer_end'),false)
 or not coalesce(p_rules->>'cancellation' in ('restore_visits','forfeit_visits'),false) or not coalesce(p_rules->>'refunded_contribution' in ('offset_future_visits','freeze_for_owner_review'),false) then raise exception 'Choose all four explicitly supported redemption rules; no defaults are applied' using errcode='22023';end if;
 payload:=jsonb_build_object('policy_version_id',p_policy_version,'expected_rules_version',p_expected_rules_version,'rules',p_rules);
 perform pg_advisory_xact_lock(hashtextextended('redemption-rule-request:'||p_request::text,0));
 select * into prior from private.loyalty_redemption_rule_requests where request_id=p_request;
 if prior.request_id is not null then
  if prior.actor_id<>auth.uid() then raise exception 'Redemption rules request access denied' using errcode='42501';end if;
  if prior.payload<>payload then raise exception 'Request identity reused with different redemption terms' using errcode='22023';end if;
  return prior.result;
 end if;
 select * into v from private.loyalty_policy_versions where version_id=p_policy_version;
 if v.version_id is null then raise exception 'Actual saved loyalty policy version required' using errcode='22023';end if;
 -- Shares the policy writer lock: a concurrent new policy cannot leave rules bound silently to superseded terms.
 perform pg_advisory_xact_lock(hashtextextended('loyalty-policy-branch:'||v.branch_id::text,0));
 perform 1 from public.business_offers where offer_id=v.offer_id for share;
 perform 1 from public.business_catalog_items where item_id=(v.policy_snapshot->>'reward_item_id')::uuid for share;
 context:=private.get_loyalty_redemption_rules(v.version_id);
 if jsonb_array_length(context->'save_blockers')>0 then raise exception 'Redemption configuration unavailable: %',context->'save_blockers' using errcode='55000';end if;
 select rules_version_id into latest from private.loyalty_redemption_rule_versions where policy_version_id=v.version_id order by version_no desc limit 1;
 if latest is distinct from p_expected_rules_version then raise exception 'Redemption rules changed; reload before saving' using errcode='40001';end if;
 if p_rules->>'expiry'='snapshot_offer_end' and v.policy_snapshot->>'offer_ends_at' is null then raise exception 'The frozen offer has no expiry deadline; choose explicit no-expiry or save new offer/policy terms' using errcode='22023';end if;
 if p_rules->>'expiry'='snapshot_offer_end' and (v.policy_snapshot->>'offer_ends_at')::timestamptz<=clock_timestamp() then raise exception 'The frozen reward expiry deadline has passed' using errcode='55000';end if;
 snapshot:=jsonb_build_object('rules_schema_version',1,'unit','service_visits','policy_version_id',v.version_id,'branch_id',v.branch_id,'offer_id',v.offer_id,'threshold_visits',context->'threshold_visits','reward_service',context->'reward_service','offer',context->'offer','target_customer_ids',v.policy_snapshot->'target_customer_ids','eligible_service_ids',v.eligible_service_ids,'rules',p_rules,'effect_scope','future_redemption_transactions_only','redemption_enabled',false);
 insert into private.loyalty_redemption_rule_versions(rules_version_id,policy_version_id,branch_id,offer_id,rules,terms_snapshot,created_by) values(p_request,v.version_id,v.branch_id,v.offer_id,p_rules,snapshot,auth.uid());
 result:=private.get_loyalty_redemption_rules(v.version_id);
 insert into private.loyalty_redemption_rule_requests(request_id,actor_id,payload,result) values(p_request,auth.uid(),payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data) values(auth.uid()::text,auth.uid(),'save_loyalty_redemption_rules','loyalty_policy_versions',v.version_id::text,v.branch_id,context->'current',result->'current');
 return result;
end;$$;
create function public.get_loyalty_redemption_rules(p_policy_version uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_loyalty_redemption_rules(p_policy_version);$$;
create function public.save_loyalty_redemption_rules(p_request uuid,p_policy_version uuid,p_expected_rules_version uuid,p_rules jsonb) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_loyalty_redemption_rules(p_request,p_policy_version,p_expected_rules_version,p_rules);$$;
revoke all on function private.get_loyalty_redemption_rules(uuid),public.get_loyalty_redemption_rules(uuid),private.save_loyalty_redemption_rules(uuid,uuid,uuid,jsonb),public.save_loyalty_redemption_rules(uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function private.get_loyalty_redemption_rules(uuid),public.get_loyalty_redemption_rules(uuid),private.save_loyalty_redemption_rules(uuid,uuid,uuid,jsonb),public.save_loyalty_redemption_rules(uuid,uuid,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
