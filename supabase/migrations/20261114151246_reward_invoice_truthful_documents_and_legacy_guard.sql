begin;
-- New covered invoices only; no financial/snapshot backfill or fake payment events.
CREATE OR REPLACE FUNCTION private.invoice_snapshot(p_invoice text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog'
AS $function$
declare invoice_row public.business_invoices;snapshot jsonb;coverage jsonb;
begin
 select * into invoice_row from public.business_invoices where invoice_id=p_invoice;
 if not found then return null;end if;
select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('name',x.item_name,'quantity',x.quantity,'unit_price',x.unit_price,'subtotal',x.subtotal) order by x.created_at,x.order_item_id) from public.business_order_items x where x.order_id=i.order_id),jsonb_build_array(jsonb_build_object('name',i.service_name,'quantity',1,'unit_price',i.total+i.discount,'subtotal',i.total+i.discount))),
 'currency','EGP','discount',i.discount,'total',i.total,'tax_amount',null,'tax_configuration','not_recorded_in_legacy_invoice',
 'delivery_fee',(select delivery_fee from public.business_order_fulfillments f where f.order_id=i.order_id))
 into snapshot
 from public.business_invoices i join public.business_branches b using(branch_id) where i.invoice_id=p_invoice;
 if invoice_row.reward_snapshot is null then return snapshot;end if;
 coverage:=private.reward_invoice_coverage(p_invoice);
 if invoice_row.total<>0 or not coalesce(coverage->>'state' in ('covered_by_reward','cancelled_reward'),false) then
  raise exception 'An issued reward document requires complete canonical coverage at creation' using errcode='42501';
 end if;
 return snapshot||jsonb_build_object('reward',invoice_row.reward_snapshot,'reward_coverage',coverage,
  'payment_status',case when coverage->>'state'='covered_by_reward' and invoice_row.status='active' then 'covered_by_reward' else 'cancelled' end,
  'payment_method','reward_coverage');
end;$function$;

CREATE OR REPLACE FUNCTION private.invoice_document_data(p_token uuid, p_allow_revoked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare i public.business_invoices%rowtype;o public.business_orders%rowtype;b public.bookings%rowtype;v_paid boolean;v_unverified boolean;coverage jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 select * into i from public.business_invoices where document_token=p_token and (document_link_enabled or p_allow_revoked);
 if not found or not coalesce(private.can_read_invoice(i.invoice_id),false) then raise exception 'Invoice unavailable or not authorized' using errcode='42501';end if;
 select * into o from public.business_orders where order_id=i.order_id;
 select * into b from public.bookings where id=o.booking_id;
 select exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash') into v_paid;
 select exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='electronic') into v_unverified;
 coverage:=case when i.total=0 then private.reward_invoice_coverage(i.invoice_id) else null end;
 return jsonb_build_object('invoice_id',i.invoice_id,'document_token',i.document_token,'issued_at',i.issued_at,'branch_id',i.branch_id,'snapshot',i.document_snapshot,
 'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when v_paid then 'paid' when v_unverified then 'verification_required' when i.status='active' and i.total=0 and coverage->>'state'='covered_by_reward' then 'covered_by_reward' else 'unpaid' end,
 'reward_coverage',coverage,'invoice_total',i.total,'invoice_discount',i.discount,'payment_method',case when coverage->>'state' in ('covered_by_reward','cancelled_reward') and i.total=0 then 'reward_coverage' else case when i.payment_method='reward_coverage' then null else i.payment_method end end,'order_id',i.order_id,'booking_id',o.booking_id,'vehicle_id',b.vehicle_id,'service_status',coalesce(b.status,o.status),'portal_origin',i.document_origin,'invoice_number',coalesce(i.display_number,i.invoice_id),'booking_number',coalesce(b.display_number,b.id::text),'issued_at_cairo',to_char(i.issued_at at time zone 'Africa/Cairo','YYYY-MM-DD"T"HH24:MI:SS'));
end;$function$;

CREATE OR REPLACE FUNCTION private.get_customer_booking_history()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.booking_date desc,h.booking_time desc,h.id) from (
    select b.id,b.branch_id,b.catalog_item_id,coalesce(b.display_number,b.id::text) booking_number,b.service_name,b.booking_date,b.booking_time,b.status,b.quoted_price,b.notes,b.vehicle_id,
      case when v.id is not null then jsonb_build_object('brand',v.brand,'model',v.model,'year',v.year,'plate_number',v.plate_number) end vehicle,
      i.invoice_id,i.invoice_number,i.document_token invoice_token,
      case when i.invoice_id is null then 'not_recorded' when i.status='void' then 'cancelled'
        when i.status='refunded' then 'refunded'
        when i.status='active' and i.total=0 and i.reward_coverage->>'state'='covered_by_reward' then 'covered_by_reward'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='cash') then 'paid'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='electronic') then 'verification_required'
        else 'unpaid' end payment_status,
      i.total invoice_total,i.discount invoice_discount,i.reward_coverage,case when i.reward_coverage->>'state' in ('covered_by_reward','cancelled_reward') and i.total=0 then 'reward_coverage' else case when i.payment_method='reward_coverage' then null else i.payment_method end end payment_method
    from public.bookings b
    left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
    left join lateral (
      select x.invoice_id,coalesce(x.display_number,x.invoice_id) invoice_number,x.document_token,x.status,x.payment_method,x.total,x.discount,case when x.total=0 then private.reward_invoice_coverage(x.invoice_id) else null end reward_coverage from public.business_orders o
      join public.business_invoices x on x.order_id=o.order_id and x.branch_id=b.branch_id
      where o.booking_id=b.id and o.customer_id=b.customer_id and o.branch_id=b.branch_id
      order by x.issued_at desc,x.invoice_id limit 1
    ) i on true
    where b.customer_id=auth.uid()
  ) h),'[]'::jsonb);
end;$function$;

CREATE OR REPLACE FUNCTION private.invoice_payment_quote(p_invoice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare i public.business_invoices%rowtype;coverage jsonb;begin
 if not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 coverage:=case when i.total=0 then private.reward_invoice_coverage(i.invoice_id) else null end;
 return jsonb_build_object('reward_coverage',coverage,'amount_due',i.total,'gross_amount',i.total+i.discount,'discount',i.discount,'collectible',i.status='active' and i.total>0 and not exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale'),
 'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when coverage->>'state'='covered_by_reward' and i.status='active' and i.total=0 then 'covered_by_reward' when exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash') then 'paid' when exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='electronic') then 'verification_required' else 'unpaid' end,'invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'base_amount',i.total,'customer_fee',0,'cash_total',i.total,'card_total',i.total,'currency','EGP','policy',case when i.payment_policy_snapshot is null then null else jsonb_build_object('base_amount',i.total,'currency','EGP','customer_fee',0,'cash_total',i.total,'card_total',i.total,'merchant_absorbs_fee',true,'versions',coalesce((select jsonb_object_agg(key,jsonb_build_object('version_id',value->>'version_id')) from jsonb_each(i.payment_policy_snapshot->'versions')),'{}'::jsonb)) end,'live_enabled',false,'sandbox_only',true);
end;$function$;

CREATE OR REPLACE FUNCTION private.shift_invoice_options(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;begin
 if not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Cashier branch permission required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'total',i.total,'status',i.status,'paid',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale'),'refunded',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='refund'))),'[]') into result from (select * from public.business_invoices where branch_id=p_branch and status<>'void' and not(total=0 and coalesce(private.reward_invoice_coverage(invoice_id)->>'state'='covered_by_reward',false)) order by issued_at desc limit 200) i;return result;
end; $function$;

create or replace function public.finalize_service_loyalty(
    p_customer_id uuid,
    p_order_id uuid,
    p_invoice_id text
)
returns table (reward_applied boolean, points_balance bigint)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_offer_id uuid;
    v_visits_required integer;
    v_balance bigint;
    v_invoice_total numeric(12, 2);
begin
    if p_customer_id is null or p_order_id is null or p_invoice_id is null then
        raise exception 'Customer, order, and invoice are required';
    end if;
    perform 1 from public.customers where id = p_customer_id for update;
    if not found then
        raise exception 'Customer not found';
    end if;
    if not exists (
        select 1 from public.business_orders
        where order_id = p_order_id and customer_id = p_customer_id
    ) then
        raise exception 'Order does not belong to this customer';
    end if;
    if exists (
        select 1 from public.business_loyalty_transactions t
        where t.customer_id = p_customer_id and t.order_id = p_order_id
          and t.reason in ('Completed service visit', 'Wash reward redeemed')
    ) then
        if exists (
            select 1 from public.business_loyalty_transactions t
            where t.customer_id = p_customer_id and t.order_id = p_order_id
              and t.reason = 'Wash reward redeemed'
        ) then
            update public.business_invoices
            set discount = discount + total, total = 0
            where invoice_id = p_invoice_id and order_id = p_order_id and total > 0;
        end if;
        select coalesce(sum(t.points), 0) into v_balance
        from public.business_loyalty_transactions t where t.customer_id = p_customer_id;
        return query select exists (
            select 1 from public.business_loyalty_transactions t
            where t.customer_id = p_customer_id and t.order_id = p_order_id
              and t.reason = 'Wash reward redeemed'
        ), v_balance;
        return;
    end if;
    select coalesce(sum(t.points), 0) into v_balance
    from public.business_loyalty_transactions t where t.customer_id = p_customer_id;
    -- Preserve old receipts above; new canonical orders must never fall back to
    -- an unrelated unmanaged/global legacy offer or import the legacy balance.
    if exists(select 1 from public.business_invoices where invoice_id=p_invoice_id and order_id=p_order_id)
      and (coalesce(private.reward_invoice_coverage(p_invoice_id)->>'state' in ('covered_by_reward','cancelled_reward'),false) or exists(
        select 1 from public.business_orders o join private.loyalty_earning_snapshot_bindings eb on eb.booking_id=o.booking_id
        where o.order_id=p_order_id and o.customer_id=p_customer_id)) then
        return query select false,v_balance;return;
    end if;
    select o.offer_id, o.visits_required into v_offer_id, v_visits_required
    from public.business_offers o
    where o.is_active and o.is_public and o.offer_type = 'visit_reward'
      and not exists (select 1 from private.managed_visit_reward_offers m where m.offer_id=o.offer_id)
      and o.visits_required is not null
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at is null or o.ends_at >= now())
    order by (o.name = 'غسيل 3 مرات والرابعة مجاناً') desc, o.created_at desc
    limit 1;
    -- Managed/new-program offers never activate legacy earning or redemption.
    -- With no explicitly configured unmanaged program, do not mint visits.
    if v_offer_id is null then
        return query select false, v_balance;
        return;
    end if;
    select i.total into v_invoice_total
    from public.business_invoices i where i.invoice_id = p_invoice_id and i.order_id = p_order_id;
    if not found then
        raise exception 'Service invoice was not found';
    end if;
    if v_invoice_total > 0 and v_offer_id is not null and v_balance >= v_visits_required then
        update public.business_invoices
        set discount = discount + total,
            total = 0
        where invoice_id = p_invoice_id;
        insert into public.business_loyalty_transactions (customer_id, points, reason, order_id, offer_id)
        values (p_customer_id, -v_visits_required, 'Wash reward redeemed', p_order_id, v_offer_id);
        v_balance := v_balance - v_visits_required;
        return query select true, v_balance;
        return;
    end if;
    if v_invoice_total > 0 then
        insert into public.business_loyalty_transactions (customer_id, points, reason, order_id, offer_id)
        values (p_customer_id, 1, 'Completed service visit', p_order_id, v_offer_id);
        v_balance := v_balance + 1;
    end if;
    return query select false, v_balance;
end;
$$;
create or replace function private.get_loyalty_redemption_rules(p_policy_version uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare v private.loyalty_policy_versions;o public.business_offers;r public.business_catalog_items;current_rules private.loyalty_redemption_rule_versions;
 service_id uuid;threshold integer;save_blockers text[]:='{}';blockers text[]:=array['redemption_quote_not_implemented','booking_redemption_not_implemented','visit_reservation_not_implemented','visit_consumption_not_implemented','visit_release_not_implemented','reward_invoice_document_state_not_implemented','refunded_contribution_resolution_not_implemented'];terms_ok boolean;backend jsonb;current_enabled boolean;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select * into v from private.loyalty_policy_versions where version_id=p_policy_version;
 if v.version_id is null then raise exception 'Actual saved loyalty policy version required' using errcode='22023';end if;
 select * into o from public.business_offers where offer_id=v.offer_id;
 service_id:=(v.policy_snapshot->>'reward_item_id')::uuid;threshold:=(v.policy_snapshot->>'threshold_visits')::integer;
 select * into r from public.business_catalog_items where item_id=service_id;
 select * into current_rules from private.loyalty_redemption_rule_versions where policy_version_id=v.version_id order by version_no desc limit 1;
 backend:=coalesce(private.reward_backend_readiness(v.version_id),'{}'::jsonb);
 if not coalesce((backend->>'earning_rules_binding_implemented')::boolean,false) then blockers:=array_append(blockers,'earning_rules_binding_not_implemented');end if;
 if coalesce((backend->>'quote_implemented')::boolean,false) then blockers:=array_remove(blockers,'redemption_quote_not_implemented');end if;
 if coalesce((backend->>'booking_implemented')::boolean,false) then blockers:=array_remove(blockers,'booking_redemption_not_implemented');end if;
 if coalesce((backend->>'allocation_implemented')::boolean,false) then blockers:=array_remove(blockers,'visit_reservation_not_implemented');end if;
 if coalesce((backend->>'consumption_implemented')::boolean,false) then blockers:=array_remove(blockers,'visit_consumption_not_implemented');end if;
 if coalesce((backend->>'release_implemented')::boolean,false) then blockers:=array_remove(blockers,'visit_release_not_implemented');end if;
 if coalesce((backend->>'readers_integrated')::boolean,false) then blockers:=array_remove(blockers,'reward_invoice_document_state_not_implemented');end if;
 if coalesce((backend->>'refund_resolution_implemented')::boolean,false) then blockers:=array_remove(blockers,'refunded_contribution_resolution_not_implemented');end if;
 current_enabled:=coalesce((backend->>'redemption_enabled')::boolean,false) and coalesce((backend->>'current_rules_activated')::boolean,false);
 if current_rules.rules_version_id is not null and not coalesce((backend->>'current_rules_activated')::boolean,false) then blockers:=array_append(blockers,'redemption_not_activated');end if;

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
 if current_rules.rules->>'refunded_contribution'='freeze_for_owner_review' and not coalesce((backend->>'refund_resolution_implemented')::boolean,false) then blockers:=array_append(blockers,'owner_refund_review_resolution_not_implemented');end if;
 return jsonb_build_object('policy_version_id',v.version_id,'policy_version_no',v.version_no,'branch_id',v.branch_id,'offer_id',v.offer_id,'threshold_visits',threshold,
 'reward_service',case when service_id is null then null else jsonb_build_object('id',service_id,'name',r.name,'is_active',coalesce(r.is_active,false),'is_public',coalesce(r.is_public,false),'branch_id',r.branch_id) end,
 'offer',jsonb_build_object('name',v.policy_snapshot->>'offer_name','starts_at',v.policy_snapshot->'offer_starts_at','ends_at',v.policy_snapshot->'offer_ends_at','current_is_active',o.is_active,'current_is_public',o.is_public),
 'current',case when current_rules.rules_version_id is null then null else to_jsonb(current_rules) end,'rules_saved',current_rules.rules_version_id is not null,'configuration_valid',cardinality(save_blockers)=0,'terms_valid',terms_ok,
 'redemption_enabled',current_enabled,'program_redemption_enabled',coalesce((backend->>'redemption_enabled')::boolean,false),'current_rules_activated',coalesce((backend->>'current_rules_activated')::boolean,false),'backend_readiness',backend,'readiness',case when current_enabled then 'redemption_enabled' when not terms_ok then 'blocked' when coalesce((backend->>'booking_implemented')::boolean,false) and coalesce((backend->>'readers_integrated')::boolean,false) then 'activation_required' else 'rules_only' end,'blockers',to_jsonb(blockers),'save_blockers',to_jsonb(save_blockers),
 'supported_rules',jsonb_build_object('pooling',jsonb_build_array('policy_version','offer_branch'),'expiry',jsonb_build_array('no_expiry','snapshot_offer_end'),'cancellation',jsonb_build_array('restore_visits','forfeit_visits'),'refunded_contribution',jsonb_build_array('offset_future_visits','freeze_for_owner_review')),
 'history',coalesce((select jsonb_agg(to_jsonb(h) order by h.version_no desc) from(select * from private.loyalty_redemption_rule_versions where policy_version_id=v.version_id order by version_no desc limit 50)h),'[]'::jsonb));
end;$$;

-- Capability installation only; this never creates a policy/rule activation.
do $$begin
 update private.reward_runtime set readers_integrated=true where singleton;
 if not found then raise exception 'Install the canonical reward backend before its invoice readers';end if;
end $$;

notify pgrst,'reload schema';
commit;
