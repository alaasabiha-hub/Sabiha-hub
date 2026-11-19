-- Shared features used by both the customer app and the Streamlit operations site.
-- This migration is prepared locally and is not applied to the hosted project.

create table if not exists public.business_catalog_items (
    item_id uuid primary key default gen_random_uuid(),
    item_type text not null check (item_type in ('service', 'product')),
    name text not null,
    description text,
    category text,
    vehicle_type text not null default '',
    price numeric(12, 2) not null default 0 check (price >= 0),
    commission_type text not null default 'fixed'
        check (commission_type in ('fixed', 'percentage')),
    commission_value numeric(12, 2) not null default 0 check (commission_value >= 0),
    stock_quantity integer check (stock_quantity is null or stock_quantity >= 0),
    is_active boolean not null default true,
    is_public boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (item_type, name, vehicle_type)
);

create index if not exists business_catalog_public_idx
    on public.business_catalog_items (item_type, is_public, is_active);

create table if not exists public.business_offers (
    offer_id uuid primary key default gen_random_uuid(),
    name text not null,
    description text,
    offer_type text not null check (
        offer_type in ('visit_reward', 'percentage_discount', 'fixed_discount', 'product_bundle')
    ),
    visits_required integer check (visits_required is null or visits_required > 0),
    reward_value numeric(12, 2) not null default 0 check (reward_value >= 0),
    reward_item_id uuid references public.business_catalog_items(item_id) on delete set null,
    starts_at timestamptz,
    ends_at timestamptz,
    is_active boolean not null default true,
    is_public boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create index if not exists business_offers_active_window_idx
    on public.business_offers (is_active, starts_at, ends_at);

-- Do not publish an assumed visit-reward offer on a fresh installation.
-- Owners create actual offers explicitly; existing database rows are not changed.

alter table public.business_orders
    add column if not exists customer_id uuid references public.customers(id) on delete set null;

create table if not exists public.business_loyalty_transactions (
    transaction_id uuid primary key default gen_random_uuid(),
    customer_id uuid not null references public.customers(id) on delete cascade,
    points integer not null check (points <> 0),
    reason text not null,
    order_id uuid references public.business_orders(order_id) on delete set null,
    offer_id uuid references public.business_offers(offer_id) on delete set null,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now()
);

create index if not exists business_loyalty_customer_created_idx
    on public.business_loyalty_transactions (customer_id, created_at desc);

create unique index if not exists business_loyalty_order_reason_uidx
    on public.business_loyalty_transactions (customer_id, order_id, reason)
    where order_id is not null;

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
            set discount = discount + total, total = 0,
                commission_total = 0, commission_share = 0
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
    select i.total into v_invoice_total
    from public.business_invoices i where i.invoice_id = p_invoice_id and i.order_id = p_order_id;
    if not found then
        raise exception 'Service invoice was not found';
    end if;
    if v_invoice_total > 0 and v_offer_id is not null and v_balance >= v_visits_required then
        update public.business_invoices
        set discount = discount + total,
            total = 0,
            commission_total = 0,
            commission_share = 0
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

create or replace function public.reverse_service_loyalty(
    p_customer_id uuid,
    p_order_id uuid,
    p_invoice_id text
)
returns table (points_balance bigint)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_original record;
    v_invoice_status text;
    v_reversal_reason text;
begin
    perform 1 from public.customers where id = p_customer_id for update;
    if not found then
        raise exception 'Customer not found';
    end if;
    select i.status into v_invoice_status from public.business_invoices i
    where i.invoice_id = p_invoice_id and i.order_id = p_order_id;
    if not found or v_invoice_status <> 'refunded' then
        raise exception 'Only a refunded invoice can reverse loyalty points';
    end if;
    select t.points, t.reason, t.offer_id into v_original
    from public.business_loyalty_transactions t
    where t.customer_id = p_customer_id and t.order_id = p_order_id
      and t.reason in ('Completed service visit', 'Wash reward redeemed')
    limit 1;
    if found then
        v_reversal_reason := case when v_original.points < 0
            then 'Refunded wash reward' else 'Refunded service visit' end;
        if not exists (
            select 1 from public.business_loyalty_transactions t
            where t.customer_id = p_customer_id and t.order_id = p_order_id
              and t.reason = v_reversal_reason
        ) then
            insert into public.business_loyalty_transactions (customer_id, points, reason, order_id, offer_id)
            values (p_customer_id, -v_original.points, v_reversal_reason, p_order_id, v_original.offer_id);
        end if;
    end if;
    return query select coalesce(sum(t.points), 0)::bigint
    from public.business_loyalty_transactions t where t.customer_id = p_customer_id;
end;
$$;

revoke all on function public.reverse_service_loyalty(uuid, uuid, text) from public, authenticated;
grant execute on function public.reverse_service_loyalty(uuid, uuid, text) to service_role;

create or replace view public.business_loyalty_balances
with (security_invoker = true)
as
select customer_id, sum(points)::bigint as points_balance
from public.business_loyalty_transactions
group by customer_id;

create table if not exists public.business_documents (
    document_id uuid primary key default gen_random_uuid(),
    category text not null,
    title text not null,
    original_filename text not null,
    mime_type text not null,
    storage_path text not null unique,
    document_number text,
    issuing_authority text,
    issued_at date,
    expires_at date,
    ai_status text not null default 'pending'
        check (ai_status in ('pending', 'processed', 'needs_review', 'failed')),
    extracted_data jsonb not null default '{}'::jsonb,
    approved_by uuid references auth.users(id) on delete set null,
    approved_by_label text,
    approved_at timestamptz,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists business_documents_expiry_idx
    on public.business_documents (expires_at)
    where expires_at is not null;

create table if not exists public.business_document_alerts (
    alert_id uuid primary key default gen_random_uuid(),
    document_id uuid not null references public.business_documents(document_id) on delete cascade,
    alert_date date not null,
    days_before_expiry integer not null,
    sent_at timestamptz,
    created_at timestamptz not null default now(),
    unique (document_id, alert_date, days_before_expiry)
);

alter table public.business_orders
    add column if not exists booking_id uuid references public.bookings(id) on delete set null;

alter table public.bookings
    add column if not exists vehicle_id uuid references public.vehicles(id) on delete set null;

alter table public.bookings
    add column if not exists quoted_price numeric(12, 2) check (quoted_price is null or quoted_price >= 0);

alter table public.bookings
    add column if not exists catalog_item_id uuid references public.business_catalog_items(item_id) on delete set null;

alter table public.bookings
    add column if not exists assigned_workers jsonb not null default '[]'::jsonb
        check (jsonb_typeof(assigned_workers) = 'array');

create or replace function public.set_customer_booking_catalog_snapshot()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
declare
    v_name text;
    v_vehicle_type text;
    v_price numeric(12, 2);
begin
    if auth.uid() is not null and new.customer_id = auth.uid() then
        if new.catalog_item_id is null then
            raise exception 'Choose a service from the published catalog';
        end if;
        select ci.name, ci.vehicle_type, ci.price
        into v_name, v_vehicle_type, v_price
        from public.business_catalog_items ci
        where ci.item_id = new.catalog_item_id
          and ci.item_type = 'service'
          and ci.is_active and ci.is_public;
        if not found then
            raise exception 'The selected service is no longer available';
        end if;
        if new.vehicle_id is not null and not exists (
            select 1 from public.vehicles v
            where v.id = new.vehicle_id and v.customer_id = new.customer_id
        ) then
            raise exception 'The selected vehicle does not belong to this customer';
        end if;
        new.service_name := v_name;
        new.vehicle_type := v_vehicle_type;
        new.quoted_price := v_price;
    end if;
    return new;
end;
$$;

create trigger set_customer_booking_catalog_snapshot
before insert on public.bookings
for each row execute function public.set_customer_booking_catalog_snapshot();

revoke insert on public.bookings from authenticated;
grant insert (customer_id, service_name, vehicle_type, vehicle_id, booking_date, booking_time, notes, catalog_item_id)
    on public.bookings to authenticated;
revoke select on public.bookings from authenticated;
grant select (id, customer_id, service_name, vehicle_type, booking_date, booking_time, status, notes, created_at, vehicle_id, quoted_price)
    on public.bookings to authenticated;

create policy "Managers read customer booking profiles"
on public.customers for select to authenticated
using (
    exists (
        select 1 from public.bookings b
        join public.staff_profiles sp on sp.user_id = (select auth.uid())
        where b.customer_id = customers.id
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Managers read all bookings"
on public.bookings for select to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Assigned employees read their bookings"
on public.bookings for select to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'employee'
          and bookings.assigned_workers @> jsonb_build_array(sp.full_name)
    )
);

create policy "Managers update bookings"
on public.bookings for update to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Assigned employees progress their bookings"
on public.bookings for update to authenticated
using (
    status in ('confirmed', 'in_progress')
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'employee'
          and bookings.assigned_workers @> jsonb_build_array(sp.full_name)
    )
)
with check (
    status in ('in_progress', 'completed')
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'employee'
          and bookings.assigned_workers @> jsonb_build_array(sp.full_name)
    )
);

revoke update on public.bookings from authenticated;
grant update (status) on public.bookings to authenticated;

alter table public.business_orders
    add column if not exists order_type text not null default 'service'
        check (order_type in ('service', 'product'));

alter table public.business_orders
    add column if not exists customer_request_id uuid;

alter table public.business_orders
    add column if not exists stock_restored_at timestamptz;

create unique index if not exists business_orders_customer_request_uidx
    on public.business_orders (customer_id, customer_request_id)
    where customer_request_id is not null;

create table if not exists public.business_order_items (
    order_item_id uuid primary key default gen_random_uuid(),
    order_id uuid not null references public.business_orders(order_id) on delete cascade,
    item_id uuid references public.business_catalog_items(item_id) on delete set null,
    item_name text not null,
    quantity integer not null check (quantity > 0),
    unit_price numeric(12, 2) not null check (unit_price >= 0),
    subtotal numeric(12, 2) not null check (subtotal >= 0),
    created_at timestamptz not null default now()
);

create index if not exists business_order_items_order_idx
    on public.business_order_items (order_id);

create or replace function public.restore_cancelled_product_order_stock()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
    if new.order_type = 'product'
       and new.status = 'cancelled'
       and old.status <> 'cancelled'
       and old.status <> 'delivered'
       and old.stock_restored_at is null then
        update public.business_catalog_items ci
        set stock_quantity = ci.stock_quantity + cancelled.quantity,
            updated_at = now()
        from (
            select item_id, sum(quantity)::integer as quantity
            from public.business_order_items
            where order_id = new.order_id and item_id is not null
            group by item_id
        ) as cancelled
        where ci.item_id = cancelled.item_id
          and ci.stock_quantity is not null;
        new.stock_restored_at := now();
    end if;
    return new;
end;
$$;

revoke all on function public.restore_cancelled_product_order_stock() from public;

create trigger restore_cancelled_product_order_stock
before update of status on public.business_orders
for each row execute function public.restore_cancelled_product_order_stock();

alter table public.business_order_items enable row level security;

grant select on public.business_order_items to authenticated;

create policy "Customers and staff read authorized order items"
on public.business_order_items for select to authenticated
using (
    exists (
        select 1 from public.business_orders o
        where o.order_id = business_order_items.order_id
          and (
              o.customer_id = (select auth.uid())
              or exists (
                  select 1 from public.staff_profiles sp
                  where sp.user_id = (select auth.uid())
                    and sp.is_active
                    and (
                        sp.role in ('owner', 'manager')
                        or (
                            sp.role = 'employee'
                            and o.assigned_workers @> jsonb_build_array(sp.full_name)
                        )
                    )
              )
          )
    )
);

create or replace function public.place_customer_product_order(
    p_items jsonb,
    p_request_id uuid,
    p_customer_note text default null
)
returns table (order_id uuid, order_number text, total numeric)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_customer_id uuid := auth.uid();
    v_existing record;
    v_line record;
    v_item public.business_catalog_items%rowtype;
    v_quantity integer;
    v_order_id uuid;
    v_order_number text;
    v_total numeric(12, 2) := 0;
    v_customer_name text;
    v_item_count integer;
begin
    if v_customer_id is null then
        raise exception 'Authentication required';
    end if;
    if p_request_id is null or jsonb_typeof(p_items) <> 'array' then
        raise exception 'A request id and product list are required';
    end if;
    if length(coalesce(p_customer_note, '')) > 1000 then
        raise exception 'The delivery note is too long';
    end if;
    select count(*) into v_item_count from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer);
    if v_item_count < 1 or v_item_count > 50 then
        raise exception 'A product order must contain between 1 and 50 lines';
    end if;
    if exists (
        select item_id
        from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        group by item_id having count(*) > 1
    ) then
        raise exception 'Duplicate product rows are not allowed';
    end if;
    if exists (
        select 1 from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        where item_id is null or quantity is null or quantity < 1 or quantity > 100
    ) then
        raise exception 'Product quantities must be between 1 and 100';
    end if;

    select o.order_id, o.order_number into v_existing
    from public.business_orders o
    where o.customer_id = v_customer_id and o.customer_request_id = p_request_id;
    if found then
        select coalesce(sum(oi.subtotal), 0) into v_total
        from public.business_order_items oi where oi.order_id = v_existing.order_id;
        return query select v_existing.order_id, v_existing.order_number, v_total;
        return;
    end if;

    for v_line in
        select item_id, quantity
        from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        order by item_id
    loop
        v_quantity := v_line.quantity;
        select * into v_item
        from public.business_catalog_items ci
        where ci.item_id = v_line.item_id
          and ci.item_type = 'product'
          and ci.is_active and ci.is_public
        for update;
        if not found then
            raise exception 'A selected product is unavailable';
        end if;
        if v_item.stock_quantity is not null and v_item.stock_quantity < v_quantity then
            raise exception 'Insufficient stock for product: %', v_item.name;
        end if;
        if v_item.stock_quantity is not null then
            update public.business_catalog_items
            set stock_quantity = stock_quantity - v_quantity,
                updated_at = now()
            where item_id = v_item.item_id;
        end if;
        v_total := v_total + (v_item.price * v_quantity);
    end loop;

    select c.full_name into v_customer_name
    from public.customers c where c.id = v_customer_id;
    v_order_id := gen_random_uuid();
    v_order_number := 'SHOP-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
    insert into public.business_orders (
        order_id, order_number, customer_id, customer_name, service_name,
        status, order_type, customer_request_id, created_by, notes
    ) values (
        v_order_id, v_order_number, v_customer_id, v_customer_name,
        'طلب منتجات من تطبيق Sabiha Hub', 'received', 'product', p_request_id, 'customer_app', nullif(trim(p_customer_note), '')
    );

    insert into public.business_order_items (order_id, item_id, item_name, quantity, unit_price, subtotal)
    select v_order_id, ci.item_id, ci.name, x.quantity, ci.price, ci.price * x.quantity
    from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
    join public.business_catalog_items ci on ci.item_id = x.item_id;

    return query select v_order_id, v_order_number, v_total;
end;
$$;

revoke all on function public.place_customer_product_order(jsonb, uuid, text) from public;
grant execute on function public.place_customer_product_order(jsonb, uuid, text) to authenticated;

create unique index if not exists business_orders_booking_uidx
    on public.business_orders (booking_id)
    where booking_id is not null;

alter table public.business_orders enable row level security;
alter table public.business_invoices enable row level security;

revoke all on public.business_orders from authenticated;
grant select (order_id, customer_id, order_number, plate_number, vehicle_type, service_name, status, order_type, notes, created_at)
    on public.business_orders to authenticated;
grant update (status) on public.business_orders to authenticated;
revoke all on public.business_invoices from authenticated;
grant select (invoice_id, order_id, service_name, total, status, issued_at)
    on public.business_invoices to authenticated;

create policy "Customers read their own business orders"
on public.business_orders for select to authenticated
using (
    customer_id = (select auth.uid())
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Assigned employees read their work orders"
on public.business_orders for select to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and (
              sp.role in ('owner', 'manager')
              or (
                  sp.role = 'employee'
                  and business_orders.assigned_workers @> jsonb_build_array(sp.full_name)
              )
          )
    )
);

create policy "Authorized staff update work progress"
on public.business_orders for update to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and (
              sp.role in ('owner', 'manager')
              or (
                  sp.role = 'employee'
                  and business_orders.assigned_workers @> jsonb_build_array(sp.full_name)
                  and business_orders.status in ('received', 'in_progress', 'quality_check')
              )
          )
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and (
              sp.role in ('owner', 'manager')
              or (
                  sp.role = 'employee'
                  and business_orders.assigned_workers @> jsonb_build_array(sp.full_name)
                  and business_orders.status in ('in_progress', 'quality_check', 'completed')
              )
          )
    )
);

create policy "Customers read invoices for their own orders"
on public.business_invoices for select to authenticated
using (
    exists (
        select 1 from public.business_orders o
        where o.order_id = business_invoices.order_id
          and o.customer_id = (select auth.uid())
    )
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

alter table public.business_catalog_items enable row level security;
alter table public.business_offers enable row level security;
alter table public.business_loyalty_transactions enable row level security;
alter table public.business_documents enable row level security;
alter table public.business_document_alerts enable row level security;

revoke all on public.business_catalog_items from authenticated;
grant select (item_id, item_type, name, description, category, vehicle_type, price, is_active, is_public)
    on public.business_catalog_items to authenticated;
grant insert, update, delete on public.business_catalog_items to authenticated;
revoke all on public.business_offers from authenticated;
grant select (offer_id, name, description, offer_type, visits_required, reward_value, starts_at, ends_at, is_active, is_public)
    on public.business_offers to authenticated;
grant insert, update, delete on public.business_offers to authenticated;
revoke all on public.business_loyalty_transactions from authenticated;
grant select (transaction_id, customer_id, points, reason, offer_id, created_at)
    on public.business_loyalty_transactions to authenticated;
grant insert on public.business_loyalty_transactions to authenticated;
grant select on public.business_loyalty_balances to authenticated;
grant select, insert, update, delete on public.business_documents to authenticated;
grant select, insert, update, delete on public.business_document_alerts to authenticated;

create policy "Customers and staff read published catalog"
on public.business_catalog_items for select to authenticated
using (
    (is_public and is_active)
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Managers manage catalog"
on public.business_catalog_items for all to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Customers and staff read published offers"
on public.business_offers for select to authenticated
using (
    (is_public and is_active)
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Managers manage offers"
on public.business_offers for all to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Customers read their own points"
on public.business_loyalty_transactions for select to authenticated
using (customer_id = (select auth.uid()));

create policy "Managers read all points"
on public.business_loyalty_transactions for select to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Managers award or redeem points"
on public.business_loyalty_transactions for insert to authenticated
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role in ('owner', 'manager')
    )
);

create policy "Owners manage business documents"
on public.business_documents for all to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);

create policy "Owners manage document alerts"
on public.business_document_alerts for all to authenticated
using (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
)
with check (
    exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'business-documents',
    'business-documents',
    false,
    20971520,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Owners read business documents storage"
on storage.objects for select to authenticated
using (
    bucket_id = 'business-documents'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);

create policy "Owners upload business documents storage"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'business-documents'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);

create policy "Owners update business documents storage"
on storage.objects for update to authenticated
using (
    bucket_id = 'business-documents'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
)
with check (
    bucket_id = 'business-documents'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);

create policy "Owners delete business documents storage"
on storage.objects for delete to authenticated
using (
    bucket_id = 'business-documents'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid())
          and sp.is_active
          and sp.role = 'owner'
    )
);
