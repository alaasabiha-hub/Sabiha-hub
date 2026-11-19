begin;
-- Component draft, production disabled. No public configuration/enable RPC.
create table private.offline_visit_channel_versions(
 version_id uuid primary key,version_no bigint generated always as identity unique,
 policy_version_id uuid not null references private.loyalty_policy_versions(version_id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),
 branch_id uuid not null references public.business_branches(branch_id),eligible_service_ids uuid[]not null check(cardinality(eligible_service_ids)between 1 and 100),
 target_offline_profile_ids uuid[],enabled boolean not null,terms_snapshot jsonb not null,created_by uuid not null references public.staff_profiles(user_id),created_at timestamptz not null default clock_timestamp());
create table private.offline_visit_channel_activations(
 activation_id uuid primary key,channel_version_id uuid not null unique references private.offline_visit_channel_versions(version_id),
 activated_by uuid not null references public.staff_profiles(user_id),activated_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['offline_visit_channel_versions','offline_visit_channel_activations']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_offline_channel before update or delete on private.%I for each row execute function private.immutable_canonical_visit()',t);end loop;end$$;
create function private.offline_visit_base_terms_current(p_policy uuid,p_rules uuid)returns boolean language sql volatile security definer set search_path=pg_catalog as $$
select exists(select 1 from private.loyalty_policy_versions p join private.loyalty_redemption_rule_versions r on r.policy_version_id=p.version_id
 join public.business_offers o on o.offer_id=p.offer_id where p.version_id=p_policy and r.rules_version_id=p_rules and r.branch_id=p.branch_id and r.offer_id=p.offer_id and p.enabled and o.offer_type='visit_reward'and o.is_active and o.is_public
 and exists(select 1 from public.business_catalog_items reward where reward.item_id=o.reward_item_id and reward.branch_id=p.branch_id and reward.item_type='service'and reward.is_active and reward.is_public)
 and not exists(select 1 from private.loyalty_policy_versions newer where newer.branch_id=p.branch_id and newer.version_no>p.version_no)
 and not exists(select 1 from private.loyalty_redemption_rule_versions newer where newer.policy_version_id=p.version_id and newer.version_no>r.version_no)
 and o.visits_required=(p.policy_snapshot->>'threshold_visits')::integer and o.name=p.policy_snapshot->>'offer_name'
 and o.reward_item_id is not distinct from(p.policy_snapshot->>'reward_item_id')::uuid and o.reward_value is not distinct from(p.policy_snapshot->>'reward_value')::numeric
 and coalesce(to_jsonb(o.branch_id),'null'::jsonb)=p.policy_snapshot->'offer_branch_id'
 and coalesce(to_jsonb(o.target_customer_ids),'null'::jsonb)=p.policy_snapshot->'target_customer_ids'
 and o.starts_at is not distinct from(p.policy_snapshot->>'offer_starts_at')::timestamptz and o.ends_at is not distinct from(p.policy_snapshot->>'offer_ends_at')::timestamptz
 and(o.starts_at is null or o.starts_at<=clock_timestamp())and(o.ends_at is null or o.ends_at>=clock_timestamp()))$$;
create function private.guard_offline_visit_channel()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare p private.loyalty_policy_versions;r private.loyalty_redemption_rule_versions;expected jsonb;
begin
 if private.active_staff_role()is distinct from'owner'or auth.uid()is distinct from new.created_by then raise exception 'Actual owner channel configuration required'using errcode='42501';end if;
 select * into p from private.loyalty_policy_versions where version_id=new.policy_version_id;
 select * into r from private.loyalty_redemption_rule_versions where rules_version_id=new.rules_version_id and policy_version_id=p.version_id;
 if r.rules_version_id is null or new.branch_id is distinct from p.branch_id or array_position(new.eligible_service_ids,null)is not null
 or(select count(distinct x)from unnest(new.eligible_service_ids)x)<>cardinality(new.eligible_service_ids)
 or exists(select 1 from unnest(new.eligible_service_ids)x where not(x=any(p.eligible_service_ids)))then raise exception 'Actual same-policy channel services/rules required'using errcode='22023';end if;
 if new.target_offline_profile_ids is not null and(cardinality(new.target_offline_profile_ids)not between 1 and 100 or array_position(new.target_offline_profile_ids,null)is not null
 or(select count(distinct x)from unnest(new.target_offline_profile_ids)x)<>cardinality(new.target_offline_profile_ids)
 or exists(select 1 from unnest(new.target_offline_profile_ids)x where not exists(select 1 from private.offline_customer_profiles f where f.profile_id=x)))then raise exception 'Actual explicit typed audience required'using errcode='22023';end if;
 expected:=jsonb_build_object('unit','service_visits','source_channel','offline_walk_in','eligibility_basis','order_created_time','policy_snapshot',p.policy_snapshot,'rules',r.rules,'rules_terms_snapshot',r.terms_snapshot);
 if new.terms_snapshot is distinct from expected or(new.enabled and not private.offline_visit_base_terms_current(p.version_id,r.rules_version_id))then raise exception 'Current explicit frozen channel terms required'using errcode='55000';end if;
 new.created_at:=clock_timestamp();return new;
end$$;
create trigger guard_offline_visit_channel before insert on private.offline_visit_channel_versions for each row execute function private.guard_offline_visit_channel();
create function private.guard_offline_visit_channel_activation()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if private.active_staff_role()is distinct from'owner'or new.activated_by is distinct from auth.uid()then raise exception 'Actual owner required'using errcode='42501';end if;
 if not coalesce((select earning_enabled from private.offline_service_visit_runtime where singleton),false)then raise exception 'Offline production earning remains disabled'using errcode='55000';end if;
 if not exists(select 1 from private.offline_visit_channel_versions v where v.version_id=new.channel_version_id and v.enabled and private.offline_visit_base_terms_current(v.policy_version_id,v.rules_version_id)
 and not exists(select 1 from private.offline_visit_channel_versions n where n.branch_id=v.branch_id and n.version_no>v.version_no))then raise exception 'Current independent channel version required'using errcode='55000';end if;
 new.activated_at:=clock_timestamp();return new;
end$$;
create trigger guard_offline_visit_channel_activation before insert on private.offline_visit_channel_activations for each row execute function private.guard_offline_visit_channel_activation();
alter table private.offline_service_visit_order_snapshots add column channel_version_id uuid references private.offline_visit_channel_versions(version_id),add column offline_activation_id uuid references private.offline_visit_channel_activations(activation_id),add column overlay_snapshot jsonb;
alter table private.offline_service_visit_order_snapshots drop constraint offline_service_visit_order_snapshots_earning_authorized_check;
alter table private.offline_service_visit_order_snapshots add constraint offline_snapshot_authorization_proof check(not earning_authorized or(channel_version_id is not null and offline_activation_id is not null and overlay_snapshot is not null and declared_eligible));
alter table private.canonical_loyalty_visits add column offline_activation_id uuid references private.offline_visit_channel_activations(activation_id);
alter table private.canonical_loyalty_visits alter column activation_id drop not null;
alter table private.canonical_loyalty_visits add constraint canonical_independent_channel_activation check(
 (source_channel='booking'and activation_id is not null and offline_activation_id is null)
 or(source_channel='offline_walk_in'and activation_id is null and offline_activation_id is not null));
create or replace function private.capture_offline_service_visit_terms()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v private.offline_visit_channel_versions;a private.offline_visit_channel_activations;eligible boolean;
begin
 if coalesce((select earning_enabled from private.offline_service_visit_runtime where singleton),false)and new.creator_xid=txid_current()then
 select * into v from private.offline_visit_channel_versions where branch_id=new.branch_id order by version_no desc limit 1;
 select * into a from private.offline_visit_channel_activations where channel_version_id=v.version_id and activated_at<=new.created_at;
 if v.version_id is not null and v.enabled and a.activation_id is not null and private.offline_visit_base_terms_current(v.policy_version_id,v.rules_version_id)then
 eligible:=new.service_id=any(v.eligible_service_ids)and(v.target_offline_profile_ids is null or new.profile_id=any(v.target_offline_profile_ids))
 and exists(select 1 from public.business_catalog_items c where c.item_id=new.service_id and c.branch_id=new.branch_id and c.is_active and c.is_public and c.item_type='service');
 insert into private.offline_service_visit_order_snapshots(order_id,offline_profile_id,car_ref_id,branch_id,catalog_item_id,policy_version_id,rules_reference_id,policy_snapshot,channel_terms_snapshot,rules_snapshot,eligibility_basis,declared_eligible,earning_authorized,channel_version_id,offline_activation_id,overlay_snapshot)
 values(new.order_id,new.profile_id,new.car_ref_id,new.branch_id,new.service_id,v.policy_version_id,v.rules_version_id,v.terms_snapshot->'policy_snapshot',
 jsonb_build_object('unit','service_visits','source_channel','offline_walk_in','eligibility_basis','order_created_time','enabled',v.enabled,'target_offline_profile_ids',v.target_offline_profile_ids),
 v.terms_snapshot->'rules_terms_snapshot','order_created_time',coalesce(eligible,false),coalesce(eligible,false),v.version_id,a.activation_id,v.terms_snapshot);
 return new;end if;end if;
declare policy private.loyalty_policy_versions;rules private.loyalty_redemption_rule_versions;installed timestamptz;fallback_eligible boolean;
begin
 select installed_at into installed from private.offline_service_visit_runtime where singleton;
 -- Only the live creator transaction may capture a NEW typed order. Never backfill.
 if installed is null or new.created_at<installed or new.creator_xid<>txid_current()then return new;end if;
 select * into policy from private.loyalty_policy_versions p where p.branch_id=new.branch_id order by p.version_no desc limit 1;
 if policy.version_id is null or policy.offline_channel_terms is null then return new;end if;
 fallback_eligible:=policy.enabled and coalesce((policy.offline_channel_terms->>'enabled')::boolean,false)
 and new.service_id=any(policy.eligible_service_ids)
 and exists(select 1 from public.business_offers o where o.offer_id=policy.offer_id and o.is_active and o.is_public and(o.branch_id is null or o.branch_id=new.branch_id))
 and exists(select 1 from public.business_catalog_items c where c.item_id=new.service_id and c.branch_id=new.branch_id and c.item_type='service'and c.is_active and c.is_public)
 and(policy.policy_snapshot->>'offer_starts_at'is null or new.created_at>=(policy.policy_snapshot->>'offer_starts_at')::timestamptz)
 and(policy.policy_snapshot->>'offer_ends_at'is null or new.created_at<=(policy.policy_snapshot->>'offer_ends_at')::timestamptz)
 and(policy.offline_channel_terms->'target_offline_profile_ids'='null'::jsonb or policy.offline_channel_terms->'target_offline_profile_ids' @> to_jsonb(array[new.profile_id]));
 select r.* into rules from private.loyalty_redemption_rule_versions r join private.reward_rule_activations a using(rules_version_id)where r.policy_version_id=policy.version_id order by r.version_no desc limit 1;
 insert into private.offline_service_visit_order_snapshots(order_id,offline_profile_id,car_ref_id,branch_id,catalog_item_id,policy_version_id,rules_reference_id,policy_snapshot,channel_terms_snapshot,rules_snapshot,eligibility_basis,declared_eligible,earning_authorized)
 values(new.order_id,new.profile_id,new.car_ref_id,new.branch_id,new.service_id,policy.version_id,rules.rules_version_id,policy.policy_snapshot,policy.offline_channel_terms,
 case when rules.rules_version_id is null then null else jsonb_build_object('rules_version_id',rules.rules_version_id,'version_no',rules.version_no,'rules',rules.rules,'terms_snapshot',rules.terms_snapshot,'reference_only',true)end,'order_created_time',coalesce(fallback_eligible,false),false);
 return new;
end;
end$$;
create function private.evaluate_booked_loyalty_visit(p_order uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare o public.business_orders;b public.bookings;s private.booking_loyalty_policy_snapshots;a private.loyalty_visit_activations;eb private.loyalty_earning_snapshot_bindings;i public.business_invoices;p public.business_payment_events;n bigint;
begin
 if not private.loyalty_visit_scheduler_ready() then return jsonb_build_object('eligible',false,'reason','scheduler_disabled');end if;
 select * into o from public.business_orders where order_id=p_order;
 if o.order_id is null or o.order_type<>'service' or o.booking_id is null then return jsonb_build_object('eligible',false,'reason','canonical_service_order_required');end if;
 select * into b from public.bookings where id=o.booking_id;
 select * into s from private.booking_loyalty_policy_snapshots where booking_id=o.booking_id;
 if s.booking_id is null then return jsonb_build_object('eligible',false,'reason','no_frozen_policy');end if;
 select * into eb from private.loyalty_earning_snapshot_bindings where booking_id=s.booking_id;
 select * into a from private.loyalty_visit_activations where activation_id=eb.activation_id and policy_version_id=s.policy_version_id;
 if a.activation_id is null or s.captured_at<a.activated_at then return jsonb_build_object('eligible',false,'reason','predates_explicit_activation');end if;
 if b.customer_id is null or eb.customer_id is distinct from b.customer_id or eb.branch_id is distinct from b.branch_id or eb.catalog_item_id is distinct from b.catalog_item_id or o.customer_id is distinct from b.customer_id or o.branch_id is distinct from b.branch_id or s.branch_id is distinct from b.branch_id or b.catalog_item_id is distinct from s.catalog_item_id or s.policy_snapshot->>'unit' is distinct from 'service_visits' or s.policy_snapshot->>'eligibility_basis' is distinct from 'booking_created_time' or coalesce((s.policy_snapshot->>'enabled')::boolean,false) is not true or not(s.policy_snapshot->'eligible_service_ids' @> to_jsonb(array[eb.catalog_item_id])) or (s.policy_snapshot->'target_customer_ids'<>'null'::jsonb and not(s.policy_snapshot->'target_customer_ids' @> to_jsonb(array[eb.customer_id]))) or (s.policy_snapshot->>'offer_starts_at' is not null and s.captured_at<(s.policy_snapshot->>'offer_starts_at')::timestamptz) or (s.policy_snapshot->>'offer_ends_at' is not null and s.captured_at>(s.policy_snapshot->>'offer_ends_at')::timestamptz) then return jsonb_build_object('eligible',false,'reason','snapshot_identity_mismatch');end if;
 select count(*) into n from public.business_orders where booking_id=b.id and order_type='service';
 if n<>1 then return jsonb_build_object('eligible',false,'reason','ambiguous_booking_orders');end if;
 if b.status<>'completed' or o.status not in ('completed','delivered') then return jsonb_build_object('eligible',false,'reason','awaiting_completed_booking_and_order');end if;
 select count(*) into n from public.business_invoices where order_id=o.order_id and status<>'void';
 if n<>1 then return jsonb_build_object('eligible',false,'reason','ambiguous_service_invoice');end if;
 select * into i from public.business_invoices where order_id=o.order_id and status<>'void';
 if i.sale_type<>'service' or i.branch_id<>o.branch_id or i.status<>'active' or i.total<=0 or i.total::text='NaN' or i.discount::text='NaN' or exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='refund') then return jsonb_build_object('eligible',false,'reason','invoice_not_active_or_refunded');end if;
 select * into p from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash';
 if p.payment_id is null or p.amount<>i.total or p.amount<=0 or p.amount::text='NaN' or not exists(select 1 from public.business_cashier_shifts where shift_id=p.shift_id and branch_id=i.branch_id) then return jsonb_build_object('eligible',false,'reason','awaiting_actual_full_cash_sale');end if;
 return jsonb_build_object('eligible',true,'reason','eligible','customer_id',o.customer_id,'order_id',o.order_id,'booking_id',b.id,'invoice_id',i.invoice_id,'sale_payment_id',p.payment_id,'sale_amount',p.amount,'branch_id',o.branch_id,'policy_version_id',s.policy_version_id,'activation_id',a.activation_id,'policy_snapshot',s.policy_snapshot,'invoice_total',i.total,'invoice_discount',i.discount,'invoice_commission_total',i.commission_total);
end $$;
create function private.reconcile_booked_loyalty_visit(p_order uuid) returns text language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;r public.business_payment_events;facts jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Visit reconciliation requires READ COMMITTED';end if;
 perform pg_advisory_xact_lock(hashtextextended('canonical-visit:'||p_order::text,0));
 select * into e from private.canonical_loyalty_visits where order_id=p_order and kind='earn';
 if e.id is not null then
 select * into r from public.business_payment_events where invoice_id=e.invoice_id and event_type='refund' and method='cash' and amount=(e.facts->>'sale_amount')::numeric;
 if r.payment_id is not null and exists(select 1 from public.business_cashier_shifts where shift_id=r.shift_id and branch_id=(e.facts->>'branch_id')::uuid) then
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,order_id,booking_id,invoice_id,sale_payment_id,refund_payment_id,activation_id,policy_version_id,reverses_earning,facts) values('refund',-1,e.branch_id,e.customer_id,e.order_id,e.booking_id,e.invoice_id,e.sale_payment_id,r.payment_id,e.activation_id,e.policy_version_id,e.id,jsonb_build_object('original_earning',e.id,'refund_payment_id',r.payment_id,'refund_amount',r.amount,'unit','service_visits')) on conflict(reverses_earning) where kind='refund' do nothing;
 return 'refunded';end if;
 return 'already_earned';end if;
 facts:=private.evaluate_loyalty_visit(p_order);
 if coalesce((facts->>'eligible')::boolean,false) is not true then return facts->>'reason';end if;
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,order_id,booking_id,invoice_id,sale_payment_id,activation_id,policy_version_id,facts) values('earn',1,(facts->>'branch_id')::uuid,(facts->>'customer_id')::uuid,p_order,(facts->>'booking_id')::uuid,facts->>'invoice_id',(facts->>'sale_payment_id')::uuid,(facts->>'activation_id')::uuid,(facts->>'policy_version_id')::uuid,facts) on conflict(order_id) where kind='earn' do nothing;
 -- A refund may have committed while FK checks waited for the invoice row.
 if exists(select 1 from public.business_payment_events where invoice_id=facts->>'invoice_id' and event_type='refund') then return private.reconcile_loyalty_visit(p_order);end if;
 return 'earned';
end $$;
revoke all on function private.evaluate_booked_loyalty_visit(uuid),private.reconcile_booked_loyalty_visit(uuid)from public,anon,authenticated,service_role;
create function private.evaluate_offline_service_visit(p_order uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare s private.offline_walk_in_subjects;b private.offline_service_visit_order_snapshots;o public.business_orders;i public.business_invoices;sale public.business_payment_events;
begin
 if not private.loyalty_visit_scheduler_ready()or not coalesce((select earning_enabled from private.offline_service_visit_runtime where singleton),false)then return jsonb_build_object('eligible',false,'reason','scheduler_disabled');end if;
 select * into s from private.offline_walk_in_subjects where order_id=p_order;
 select * into b from private.offline_service_visit_order_snapshots where order_id=p_order;
 select * into o from public.business_orders where order_id=p_order;
 if s.order_id is null or not coalesce(b.earning_authorized,false)or not coalesce(b.declared_eligible,false)or b.offline_profile_id is distinct from s.profile_id or b.car_ref_id is distinct from s.car_ref_id or b.catalog_item_id is distinct from s.service_id or b.branch_id is distinct from s.branch_id
 or o.customer_id is not null or o.booking_id is not null or o.order_type is distinct from'service'or o.branch_id is distinct from s.branch_id
 or not exists(select 1 from private.offline_visit_channel_activations a join private.offline_visit_channel_versions v on v.version_id=a.channel_version_id where a.activation_id=b.offline_activation_id and v.version_id=b.channel_version_id and v.policy_version_id=b.policy_version_id and v.rules_version_id=b.rules_reference_id and v.terms_snapshot=b.overlay_snapshot and v.branch_id=s.branch_id and s.service_id=any(v.eligible_service_ids)and(v.target_offline_profile_ids is null or s.profile_id=any(v.target_offline_profile_ids))and b.policy_snapshot=v.terms_snapshot->'policy_snapshot'and b.rules_snapshot=v.terms_snapshot->'rules_terms_snapshot'and a.activated_at<=s.created_at and b.captured_at>=a.activated_at)
 then return jsonb_build_object('eligible',false,'reason','offline_frozen_source_required');end if;
 if o.status not in('completed','delivered')or not exists(select 1 from private.service_work_ledger w where w.order_id=p_order and w.target_kind='order'and w.expected_status='quality_check'and w.next_status='completed')
 or not exists(select 1 from private.service_resource_events r where r.walk_in_order_id=p_order and r.action='complete')then return jsonb_build_object('eligible',false,'reason','awaiting_guarded_completed_offline_work');end if;
 if(select count(*)from public.business_invoices where order_id=p_order and status<>'void')<>1 then return jsonb_build_object('eligible',false,'reason','ambiguous_service_invoice');end if;
 select * into i from public.business_invoices where invoice_id=s.invoice_id and order_id=p_order;
 if i.status is distinct from'active'or i.branch_id is distinct from s.branch_id or i.sale_type is distinct from'service'or i.commission_model is distinct from'walk_in_frozen_workers'
 or i.total is distinct from s.gross or i.discount<>0 or i.total<=0 or i.total::text in('NaN','Infinity','-Infinity')or i.reward_snapshot is not null
 or exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='refund')then return jsonb_build_object('eligible',false,'reason','invoice_not_active_or_refunded');end if;
 select * into sale from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale'and method='cash';
 if sale.payment_id is null or sale.amount is distinct from i.total or not exists(select 1 from public.business_cashier_shifts sh where sh.shift_id=sale.shift_id and sh.branch_id=i.branch_id)then return jsonb_build_object('eligible',false,'reason','awaiting_actual_full_cash_sale');end if;
 if(select count(*)from private.offline_walk_in_commissions c where c.invoice_id=i.invoice_id)<>cardinality(s.staff_ids)
 or(select sum(c.amount)from private.offline_walk_in_commissions c where c.invoice_id=i.invoice_id)is distinct from i.commission_total then return jsonb_build_object('eligible',false,'reason','frozen_worker_commission_required');end if;
 return jsonb_build_object('eligible',true,'unit','service_visits','source_channel','offline_walk_in','owner_kind','offline_profile','offline_profile_id',s.profile_id,'order_id',p_order,'invoice_id',i.invoice_id,'sale_payment_id',sale.payment_id,'sale_amount',sale.amount,'branch_id',s.branch_id,'policy_version_id',b.policy_version_id,'offline_activation_id',b.offline_activation_id,'channel_version_id',b.channel_version_id,'rules_version_id',b.rules_reference_id);
end$$;
create function private.reconcile_offline_service_visit(p_order uuid)returns text language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare e private.canonical_loyalty_visits;r public.business_payment_events;facts jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Visit reconciliation requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('canonical-visit:'||p_order::text,0));
 perform 1 from public.business_invoices i where i.order_id=p_order order by i.invoice_id for update of i;
 select * into e from private.canonical_loyalty_visits where order_id=p_order and kind='earn';
 if e.id is not null then
 if e.source_channel<>'offline_walk_in'then raise exception 'Typed source mismatch'using errcode='55000';end if;
 select p.*into r from public.business_payment_events p join public.business_cashier_shifts s on s.shift_id=p.shift_id where p.invoice_id=e.invoice_id and p.event_type='refund'and p.method='cash'and p.amount=(e.facts->>'sale_amount')::numeric and s.branch_id=e.branch_id;
 if r.payment_id is not null then
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,offline_profile_id,order_id,booking_id,invoice_id,sale_payment_id,refund_payment_id,activation_id,offline_activation_id,policy_version_id,reverses_earning,facts,source_channel,offline_order_snapshot_id)
 values('refund',-1,e.branch_id,null,e.offline_profile_id,p_order,null,e.invoice_id,e.sale_payment_id,r.payment_id,null,e.offline_activation_id,e.policy_version_id,e.id,jsonb_build_object('original_earning',e.id,'refund_payment_id',r.payment_id,'refund_amount',r.amount,'unit','service_visits'),'offline_walk_in',e.offline_order_snapshot_id)
 on conflict(reverses_earning)where kind='refund'do nothing;return 'refunded';end if;
 return 'already_earned';end if;
 facts:=private.evaluate_offline_service_visit(p_order);
 if not coalesce((facts->>'eligible')::boolean,false)then return facts->>'reason';end if;
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,offline_profile_id,order_id,booking_id,invoice_id,sale_payment_id,activation_id,offline_activation_id,policy_version_id,facts,source_channel,offline_order_snapshot_id)
 values('earn',1,(facts->>'branch_id')::uuid,null,(facts->>'offline_profile_id')::uuid,p_order,null,facts->>'invoice_id',(facts->>'sale_payment_id')::uuid,null,(facts->>'offline_activation_id')::uuid,(facts->>'policy_version_id')::uuid,facts,'offline_walk_in',p_order)
 on conflict(order_id)where kind='earn'do nothing;
 return 'earned';
end$$;
create or replace function private.evaluate_loyalty_visit(p_order uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.offline_walk_in_subjects where order_id=p_order)then return private.evaluate_offline_service_visit(p_order);end if;
 return private.evaluate_booked_loyalty_visit(p_order);end$$;
create or replace function private.reconcile_loyalty_visit(p_order uuid)returns text language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Visit reconciliation requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('canonical-visit:'||p_order::text,0));
 if exists(select 1 from private.offline_walk_in_subjects where order_id=p_order)then return private.reconcile_offline_service_visit(p_order);end if;
 return private.reconcile_booked_loyalty_visit(p_order);end$$;
create or replace function private.guard_offline_canonical_visit_insert()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;facts jsonb;
begin
 if new.source_channel='offline_walk_in'then
 if new.kind='earn'then
 facts:=private.evaluate_offline_service_visit(new.order_id);
 if not coalesce((facts->>'eligible')::boolean,false)or new.facts is distinct from facts or new.offline_profile_id is distinct from(facts->>'offline_profile_id')::uuid or new.offline_activation_id is distinct from(facts->>'offline_activation_id')::uuid
 or new.invoice_id is distinct from facts->>'invoice_id'or new.sale_payment_id is distinct from(facts->>'sale_payment_id')::uuid or new.policy_version_id is distinct from(facts->>'policy_version_id')::uuid or new.branch_id is distinct from(facts->>'branch_id')::uuid then raise exception 'Actual offline earning proof required'using errcode='55000';end if;
 else
 select * into e from private.canonical_loyalty_visits where id=new.reverses_earning and kind='earn'and source_channel='offline_walk_in';
 if e.id is null or new.offline_profile_id is distinct from e.offline_profile_id or new.order_id is distinct from e.order_id or new.invoice_id is distinct from e.invoice_id or new.sale_payment_id is distinct from e.sale_payment_id or new.offline_activation_id is distinct from e.offline_activation_id or new.policy_version_id is distinct from e.policy_version_id or new.branch_id is distinct from e.branch_id or new.offline_order_snapshot_id is distinct from e.offline_order_snapshot_id
 or new.facts is distinct from jsonb_build_object('original_earning',e.id,'refund_payment_id',new.refund_payment_id,'refund_amount',(select r.amount from public.business_payment_events r where r.payment_id=new.refund_payment_id),'unit','service_visits')
 or not exists(select 1 from public.business_payment_events r join public.business_cashier_shifts s on s.shift_id=r.shift_id where r.payment_id=new.refund_payment_id and r.invoice_id=e.invoice_id and r.event_type='refund'and r.method='cash'and r.amount=(e.facts->>'sale_amount')::numeric and s.branch_id=e.branch_id)then raise exception 'Actual same-owner refund proof required'using errcode='55000';end if;
 end if;return new;end if;
 if new.offline_profile_id is not null or new.offline_order_snapshot_id is not null then raise exception 'Booking typed owner mismatch'using errcode='55000';end if;
 if new.kind='refund'and exists(select 1 from private.canonical_loyalty_visits prior where prior.id=new.reverses_earning and(prior.source_channel<>'booking'or prior.customer_id is distinct from new.customer_id or prior.booking_id is distinct from new.booking_id or prior.order_id is distinct from new.order_id or prior.invoice_id is distinct from new.invoice_id or prior.branch_id is distinct from new.branch_id or prior.policy_version_id is distinct from new.policy_version_id or prior.activation_id is distinct from new.activation_id))then raise exception 'Canonical reversal owner/source mismatch'using errcode='55000';end if;
 return new;end$$;
create function private.block_offline_reward_claim_until_typed_allocator()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.canonical_loyalty_visits where id=new.earning_id and source_channel='offline_walk_in')then raise exception 'Typed offline allocator and consent not implemented'using errcode='55000';end if;return new;end$$;
create trigger block_offline_reward_claim before insert on private.reward_credit_claims for each row execute function private.block_offline_reward_claim_until_typed_allocator();
create function private.bind_offline_reward_earning_terms()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.source_channel='offline_walk_in'and new.kind='earn'then
 insert into private.reward_earning_terms(earning_id,rules_version_id)select new.id,s.rules_reference_id from private.offline_service_visit_order_snapshots s where s.order_id=new.order_id and s.earning_authorized;
 end if;return new;end$$;
create trigger bind_offline_reward_earning_terms after insert on private.canonical_loyalty_visits for each row execute function private.bind_offline_reward_earning_terms();
create or replace function private.enqueue_loyalty_visit_source() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare oid uuid;bid uuid;iid text;sid uuid:=gen_random_uuid();
begin
 if tg_table_schema='private' and tg_table_name='loyalty_earning_snapshot_bindings' then bid:=new.booking_id;sid:=new.booking_id;
 elsif tg_table_name='bookings' then bid:=new.id;if not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid) then return new;end if;
 elsif tg_table_name='business_orders' then if new.order_type<>'service' then return new;end if;oid:=new.order_id;bid:=new.booking_id;
 elsif tg_table_name='business_invoices' then oid:=new.order_id;iid:=new.invoice_id;select booking_id into bid from public.business_orders where order_id=oid;
 else sid:=new.payment_id;iid:=new.invoice_id;select order_id into oid from public.business_invoices where invoice_id=iid;select booking_id into bid from public.business_orders where order_id=oid;end if;
 if bid is null then
 if oid is not null and exists(select 1 from private.offline_service_visit_order_snapshots s where s.order_id=oid and s.earning_authorized)then
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,invoice_id)values(tg_table_name,sid,oid,iid)on conflict(source_kind,source_id)do nothing;end if;return new;end if;
 if not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid)then return new;end if;
 -- Distinct append-only events: never a mutable shared queue row per order.
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,booking_id,invoice_id) values(tg_table_name,sid,oid,bid,iid) on conflict(source_kind,source_id) do nothing;
 return new;
end $$;
revoke all on function private.offline_visit_base_terms_current(uuid,uuid),private.guard_offline_visit_channel(),private.guard_offline_visit_channel_activation(),private.evaluate_offline_service_visit(uuid),private.reconcile_offline_service_visit(uuid),private.block_offline_reward_claim_until_typed_allocator(),private.bind_offline_reward_earning_terms()from public,anon,authenticated,service_role;
create or replace function private.offline_service_visit_readiness()returns jsonb language sql stable security definer set search_path=pg_catalog as $$
select jsonb_build_object('unit','service_visits','typed_owner_schema_installed',true,'future_order_snapshot_installed',true,'shared_earning_kernel_installed',true,'refund_kernel_installed',true,
'earning_enabled',false,'redemption_enabled',false,'offline_wallet_access',false,'points_conversion',false,'existing_engine_reused',true,
'blockers',jsonb_build_array('public_owner_channel_configuration_not_implemented','production_activation_check_locked','typed_rules_wallet_allocator_debt_not_implemented','separate_wallet_and_spend_consent_not_implemented','reward_worker_commission_recognition_not_implemented','offline_quote_prepared_issuer_recovery_not_implemented','full_concurrency_and_customer_acceptance_pending'))$$;
-- The installed production runtime CHECK(not earning_enabled) is intentionally untouched.
-- No public enable/config/credit API, new scheduler, legacy import or transfer.
commit;
