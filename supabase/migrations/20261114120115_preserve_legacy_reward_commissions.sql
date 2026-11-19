-- Future legacy service loyalty calls retain issued before-discount commissions.
-- No invoice backfill or reward seed; existing zero commissions remain untouched.
begin;
-- Bootstrap also supports the standalone website compatibility migration.
create table if not exists private.managed_visit_reward_offers(offer_id uuid primary key references public.business_offers(offer_id),managed_by uuid not null references public.staff_profiles(user_id),managed_at timestamptz not null default clock_timestamp());
alter table private.managed_visit_reward_offers enable row level security;
revoke all on private.managed_visit_reward_offers from public,anon,authenticated;
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
    select o.offer_id, o.visits_required into v_offer_id, v_visits_required
    from public.business_offers o
    where o.is_active and o.is_public and o.offer_type = 'visit_reward'
      and not exists (select 1 from private.managed_visit_reward_offers m where m.offer_id=o.offer_id)
      and o.visits_required is not null
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at is null or o.ends_at >= now())
    order by (o.name = 'غسيل 3 مرات والرابعة مجاناً') desc, o.created_at desc
    limit 1;
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

revoke all on function public.finalize_service_loyalty(uuid, uuid, text) from public, authenticated;
grant execute on function public.finalize_service_loyalty(uuid, uuid, text) to service_role;

commit;
