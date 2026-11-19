begin;
-- DISABLED schema foundation only. No earning writer, backfill, scheduler or transfer.
create table private.offline_service_visit_runtime(
 singleton boolean primary key default true check(singleton),installed_at timestamptz not null default clock_timestamp(),
 earning_enabled boolean not null default false check(not earning_enabled));
insert into private.offline_service_visit_runtime(singleton,earning_enabled)values(true,false);
alter table private.offline_service_visit_runtime enable row level security;
revoke all on private.offline_service_visit_runtime from public,anon,authenticated,service_role;

-- Existing immutable versions remain NULL: old policies never implicitly cover guests.
alter table private.loyalty_policy_versions add column offline_channel_terms jsonb;
create function private.valid_offline_service_visit_terms(p_terms jsonb)returns boolean language plpgsql immutable set search_path=pg_catalog as $$
declare element jsonb;ids uuid[]:=array[]::uuid[];parsed uuid;
begin
 if p_terms is null then return true;end if;
 if jsonb_typeof(p_terms)<>'object'or not p_terms?&array['unit','source_channel','eligibility_basis','enabled','target_offline_profile_ids']
 or p_terms-array['unit','source_channel','eligibility_basis','enabled','target_offline_profile_ids']<>'{}'::jsonb
 or p_terms->>'unit'is distinct from 'service_visits'or p_terms->>'source_channel'is distinct from 'offline_walk_in'
 or p_terms->>'eligibility_basis'is distinct from 'order_created_time'or jsonb_typeof(p_terms->'enabled')<>'boolean'then return false;end if;
 if p_terms->'target_offline_profile_ids'='null'::jsonb then return true;end if;
 if jsonb_typeof(p_terms->'target_offline_profile_ids')<>'array'or jsonb_array_length(p_terms->'target_offline_profile_ids')not between 1 and 100 then return false;end if;
 for element in select value from jsonb_array_elements(p_terms->'target_offline_profile_ids')loop
  if jsonb_typeof(element)<>'string'then return false;end if;
  begin parsed:=(element#>>'{}')::uuid;exception when invalid_text_representation then return false;end;
  if parsed::text is distinct from(element#>>'{}')or parsed=any(ids)then return false;end if;
  ids:=array_append(ids,parsed);
 end loop;
 return true;
end$$;
alter table private.loyalty_policy_versions add constraint valid_offline_channel_terms check(private.valid_offline_service_visit_terms(offline_channel_terms));
create function private.guard_offline_service_visit_policy()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.offline_channel_terms is null then return new;end if;
 if not private.valid_offline_service_visit_terms(new.offline_channel_terms)
 or new.request_payload->'offline_channel_terms'is distinct from new.offline_channel_terms then raise exception 'Explicit versioned offline channel terms required'using errcode='22023';end if;
 if new.offline_channel_terms->'target_offline_profile_ids'<>'null'::jsonb and exists(
 select 1 from jsonb_array_elements_text(new.offline_channel_terms->'target_offline_profile_ids')target(id)
 where not exists(select 1 from private.offline_customer_profiles p where p.profile_id=target.id::uuid))then raise exception 'Actual offline profile targets required'using errcode='22023';end if;
 return new;
end$$;
create trigger guard_explicit_offline_service_visit_policy before insert on private.loyalty_policy_versions for each row execute function private.guard_offline_service_visit_policy();

create table private.offline_service_visit_order_snapshots(
 order_id uuid primary key references private.offline_walk_in_subjects(order_id),offline_profile_id uuid not null references private.offline_customer_profiles(profile_id),
 car_ref_id uuid not null references private.offline_customer_car_refs(car_ref_id),branch_id uuid not null references public.business_branches(branch_id),
 catalog_item_id uuid not null references public.business_catalog_items(item_id),policy_version_id uuid not null references private.loyalty_policy_versions(version_id),
 rules_reference_id uuid references private.loyalty_redemption_rule_versions(rules_version_id),
 policy_snapshot jsonb not null,channel_terms_snapshot jsonb not null,rules_snapshot jsonb,
 eligibility_basis text not null check(eligibility_basis='order_created_time'),declared_eligible boolean not null,
 earning_authorized boolean not null default false check(not earning_authorized),captured_at timestamptz not null default clock_timestamp());
alter table private.offline_service_visit_order_snapshots enable row level security;
revoke all on private.offline_service_visit_order_snapshots from public,anon,authenticated,service_role;
create trigger immutable_offline_service_visit_snapshot before update or delete on private.offline_service_visit_order_snapshots for each row execute function private.immutable_canonical_visit();

-- Same canonical ledger, same original IDs/FKs/unique earn and reversal indices.
alter table private.canonical_loyalty_visits add column offline_profile_id uuid references private.offline_customer_profiles(profile_id),
 add column source_channel text not null default 'booking'check(source_channel in('booking','offline_walk_in')),
 add column offline_order_snapshot_id uuid references private.offline_service_visit_order_snapshots(order_id);
alter table private.canonical_loyalty_visits alter column customer_id drop not null;
alter table private.canonical_loyalty_visits alter column booking_id drop not null;
alter table private.canonical_loyalty_visits add constraint canonical_visit_typed_owner_source check(
 (source_channel='booking'and customer_id is not null and booking_id is not null and offline_profile_id is null and offline_order_snapshot_id is null)
 or(source_channel='offline_walk_in'and customer_id is null and booking_id is null and offline_profile_id is not null and offline_order_snapshot_id is not null and offline_order_snapshot_id=order_id));
create index canonical_visit_offline_owner on private.canonical_loyalty_visits(offline_profile_id,created_at)where offline_profile_id is not null;

create function private.guard_offline_canonical_visit_insert()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.source_channel='offline_walk_in'or new.offline_profile_id is not null or new.offline_order_snapshot_id is not null then
  -- Deliberately no privileged/test bypass. A future reviewed migration must install
  -- the complete earning/refund/wallet/consent kernel before this fence can change.
  raise exception 'Offline service visit earning is not implemented or activated'using errcode='55000';
 end if;
 if new.kind='refund'and exists(select 1 from private.canonical_loyalty_visits e where e.id=new.reverses_earning and(e.source_channel<>'booking'or e.customer_id is distinct from new.customer_id or e.booking_id is distinct from new.booking_id or e.order_id is distinct from new.order_id or e.invoice_id is distinct from new.invoice_id or e.branch_id is distinct from new.branch_id or e.policy_version_id is distinct from new.policy_version_id or e.activation_id is distinct from new.activation_id))then raise exception 'Canonical reversal owner/source mismatch'using errcode='55000';end if;
 return new;
end$$;
create trigger guard_offline_canonical_visit_insert before insert on private.canonical_loyalty_visits for each row execute function private.guard_offline_canonical_visit_insert();

create function private.capture_offline_service_visit_terms()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare policy private.loyalty_policy_versions;rules private.loyalty_redemption_rule_versions;installed timestamptz;eligible boolean;
begin
 select installed_at into installed from private.offline_service_visit_runtime where singleton;
 -- Only the live creator transaction may capture a NEW typed order. Never backfill.
 if installed is null or new.created_at<installed or new.creator_xid<>txid_current()then return new;end if;
 select * into policy from private.loyalty_policy_versions p where p.branch_id=new.branch_id order by p.version_no desc limit 1;
 if policy.version_id is null or policy.offline_channel_terms is null then return new;end if;
 eligible:=policy.enabled and coalesce((policy.offline_channel_terms->>'enabled')::boolean,false)
 and new.service_id=any(policy.eligible_service_ids)
 and exists(select 1 from public.business_offers o where o.offer_id=policy.offer_id and o.is_active and o.is_public and(o.branch_id is null or o.branch_id=new.branch_id))
 and exists(select 1 from public.business_catalog_items c where c.item_id=new.service_id and c.branch_id=new.branch_id and c.item_type='service'and c.is_active and c.is_public)
 and(policy.policy_snapshot->>'offer_starts_at'is null or new.created_at>=(policy.policy_snapshot->>'offer_starts_at')::timestamptz)
 and(policy.policy_snapshot->>'offer_ends_at'is null or new.created_at<=(policy.policy_snapshot->>'offer_ends_at')::timestamptz)
 and(policy.offline_channel_terms->'target_offline_profile_ids'='null'::jsonb or policy.offline_channel_terms->'target_offline_profile_ids' @> to_jsonb(array[new.profile_id]));
 select r.* into rules from private.loyalty_redemption_rule_versions r join private.reward_rule_activations a using(rules_version_id)where r.policy_version_id=policy.version_id order by r.version_no desc limit 1;
 insert into private.offline_service_visit_order_snapshots(order_id,offline_profile_id,car_ref_id,branch_id,catalog_item_id,policy_version_id,rules_reference_id,policy_snapshot,channel_terms_snapshot,rules_snapshot,eligibility_basis,declared_eligible,earning_authorized)
 values(new.order_id,new.profile_id,new.car_ref_id,new.branch_id,new.service_id,policy.version_id,rules.rules_version_id,policy.policy_snapshot,policy.offline_channel_terms,
 case when rules.rules_version_id is null then null else jsonb_build_object('rules_version_id',rules.rules_version_id,'version_no',rules.version_no,'rules',rules.rules,'terms_snapshot',rules.terms_snapshot,'reference_only',true)end,'order_created_time',coalesce(eligible,false),false);
 return new;
end$$;
create trigger capture_offline_service_visit_terms after insert on private.offline_walk_in_subjects for each row execute function private.capture_offline_service_visit_terms();

create function private.canonical_service_visit_owner(p_earning uuid)returns table(owner_kind text,owner_id uuid)language sql stable security definer set search_path=pg_catalog as $$
 select case when e.customer_id is not null then 'auth_customer'else'offline_profile'end,coalesce(e.customer_id,e.offline_profile_id)from private.canonical_loyalty_visits e where e.id=p_earning$$;
create function private.offline_service_visit_readiness()returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('unit','service_visits','typed_owner_schema_installed',true,'future_order_snapshot_installed',true,
 'earning_enabled',false,'redemption_enabled',false,'offline_wallet_access',false,'points_conversion',false,'existing_engine_reused',true,
 'blockers',jsonb_build_array('owner_offline_channel_configuration_not_implemented','offline_activation_cutoff_not_implemented','shared_typed_earning_and_refund_kernel_not_implemented','typed_rules_wallet_allocator_debt_not_implemented','separate_wallet_and_spend_consent_not_implemented','reward_worker_commission_recognition_not_implemented','offline_quote_prepared_issuer_recovery_not_implemented','full_concurrency_and_customer_acceptance_pending'))$$;
revoke all on function private.valid_offline_service_visit_terms(jsonb),private.guard_offline_service_visit_policy(),private.guard_offline_canonical_visit_insert(),private.capture_offline_service_visit_terms(),private.canonical_service_visit_owner(uuid),private.offline_service_visit_readiness()from public,anon,authenticated,service_role;

-- Stable pre-extension policy JSON contract; no stored snapshot/hash is rewritten.
create function private.legacy_loyalty_policy_response(p_value private.loyalty_policy_versions)returns jsonb language sql stable security invoker set search_path=pg_catalog as $$
 select jsonb_build_object('version_no',(p_value).version_no,'version_id',(p_value).version_id,'branch_id',(p_value).branch_id,'offer_id',(p_value).offer_id,
 'eligible_service_ids',(p_value).eligible_service_ids,'enabled',(p_value).enabled,'policy_snapshot',(p_value).policy_snapshot,'request_payload',(p_value).request_payload,
 'created_by',(p_value).created_by,'created_at',(p_value).created_at)$$;
revoke all on function private.legacy_loyalty_policy_response(private.loyalty_policy_versions)from public,anon,authenticated,service_role;
create or replace function private.get_loyalty_policy(p_branch uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_active and (p_branch is null or branch_id=p_branch) order by is_default desc,branch_id limit 1;
 if b is null then raise exception 'Active branch required';end if;
 return jsonb_build_object('branch_id',b,'unit','service_visits','automatic_earning_implemented',false,'redemption_implemented',false,
 'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',branch_id,'name_ar',name_ar,'name_en',name_en)),'[]') from public.business_branches where is_active),
 'offers',(select coalesce(jsonb_agg(jsonb_build_object('id',offer_id,'name',name,'visits_required',visits_required,'is_active',is_active,'is_public',is_public,'starts_at',starts_at,'ends_at',ends_at,'branch_id',branch_id,'name_en',name_en,'reward_item_id',reward_item_id,'reward_value',reward_value)),'[]') from public.business_offers where offer_type='visit_reward' and visits_required is not null and (branch_id=b or branch_id is null)),
 'services',(select coalesce(jsonb_agg(jsonb_build_object('id',item_id,'name',name,'is_active',is_active,'is_public',is_public)),'[]') from public.business_catalog_items where branch_id=b and item_type='service'),
 'current',(select private.legacy_loyalty_policy_response(v) from private.loyalty_policy_versions v where branch_id=b order by version_no desc limit 1),
 'history',(select coalesce(jsonb_agg(to_jsonb(x) order by version_no desc),'[]') from (select v.version_id,v.version_no,v.enabled,v.offer_id,v.eligible_service_ids,v.created_at,v.created_by,(select count(*) from private.booking_loyalty_policy_snapshots s where s.policy_version_id=v.version_id) captured_bookings from private.loyalty_policy_versions v where branch_id=b order by version_no desc limit 50)x));
end $$;
create or replace function private.save_loyalty_policy(p_request uuid,p_branch uuid,p_offer uuid,p_services uuid[],p_enabled boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior private.loyalty_policy_versions;o public.business_offers;payload jsonb;snapshot jsonb;result jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_branch is null or p_offer is null or p_enabled is null or p_services is null or cardinality(p_services) not between 1 and 100 or array_position(p_services,null) is not null or (select count(distinct x) from unnest(p_services)x)<>cardinality(p_services) then raise exception 'Select explicit branch, visit offer, unique actual services and enabled state';end if;
 payload:=jsonb_build_object('branch_id',p_branch,'offer_id',p_offer,'service_ids',p_services,'enabled',p_enabled);
 perform pg_advisory_xact_lock(hashtextextended('loyalty-request:'||p_request::text,0));
 select * into prior from private.loyalty_policy_versions where version_id=p_request;
 if prior.version_id is not null then if prior.created_by<>auth.uid() or prior.request_payload<>payload then raise exception 'Request identity reused with different inputs';end if;return private.legacy_loyalty_policy_response(prior);end if;
 perform pg_advisory_xact_lock(hashtextextended('loyalty-policy-branch:'||p_branch::text,0));
 perform 1 from public.business_branches where branch_id=p_branch and is_active for share;
 if not found then raise exception 'Active branch required';end if;
 perform 1 from public.business_catalog_items where item_id=any(p_services) and branch_id=p_branch and item_type='service' order by item_id for share;
 select * into o from public.business_offers where offer_id=p_offer and offer_type='visit_reward' and visits_required is not null for share;
 if o.offer_id is null then raise exception 'Actual visit reward offer required';end if;
 if o.branch_id is not null and o.branch_id<>p_branch then raise exception 'Visit offer belongs to another branch';end if;
 if p_enabled and (not o.is_active or not o.is_public or o.starts_at>clock_timestamp() or o.ends_at<clock_timestamp()) then raise exception 'Published currently active visit offer required to enable';end if;
 if exists(select 1 from unnest(p_services) id where not exists(select 1 from public.business_catalog_items c where c.item_id=id and c.branch_id=p_branch and c.item_type='service' and (not p_enabled or c.is_active and c.is_public))) then raise exception 'Choose actual services in this branch; enabled policy requires active public services';end if;
 snapshot:=jsonb_build_object('unit','service_visits','offer_id',o.offer_id,'offer_name',o.name,'threshold_visits',o.visits_required,'offer_starts_at',o.starts_at,'offer_ends_at',o.ends_at,'reward_item_id',o.reward_item_id,'reward_value',o.reward_value,'offer_branch_id',o.branch_id,'target_customer_ids',o.target_customer_ids,'eligibility_basis','booking_created_time','eligible_service_ids',p_services,'branch_id',p_branch,'enabled',p_enabled,'effective_scope','new_bookings_created_after_version','automatic_earning_implemented',false,'redemption_implemented',false);
 insert into private.managed_visit_reward_offers(offer_id,managed_by) values(p_offer,auth.uid()) on conflict(offer_id) do nothing;
 insert into private.loyalty_policy_versions(version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by) values(p_request,p_branch,p_offer,p_services,p_enabled,snapshot,payload,auth.uid()) returning private.legacy_loyalty_policy_response(loyalty_policy_versions.*) into result;return result;
end $$;

commit;
