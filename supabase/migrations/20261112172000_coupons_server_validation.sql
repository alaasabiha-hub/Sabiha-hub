-- Owner-managed coupons; all eligibility, limits and discounts are calculated in Postgres.
create table public.business_coupons (
    coupon_id uuid primary key default gen_random_uuid(),
    code text not null unique check (code = upper(trim(code)) and length(code) between 3 and 40),
    title text not null check (length(trim(title)) between 1 and 120),
    description text,
    image_url text,
    image_storage_path text,
    discount_type text not null check (discount_type in ('percentage', 'fixed')),
    discount_value numeric(12, 2) not null check (discount_value > 0),
    max_discount numeric(12, 2) check (max_discount is null or max_discount >= 0),
    minimum_subtotal numeric(12, 2) not null default 0 check (minimum_subtotal >= 0),
    starts_at timestamptz,
    ends_at timestamptz,
    max_redemptions integer check (max_redemptions is null or max_redemptions > 0),
    per_customer_limit integer not null default 1 check (per_customer_limit > 0),
    included_item_ids uuid[],
    excluded_item_ids uuid[] not null default '{}',
    first_purchase_only boolean not null default false,
    target_customer_ids uuid[],
    is_public boolean not null default true,
    is_active boolean not null default true,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (ends_at is null or starts_at is null or ends_at > starts_at),
    check (discount_type <> 'percentage' or discount_value <= 100)
);

create index business_coupons_active_window_idx
    on public.business_coupons (starts_at, ends_at) where is_active;

alter table public.business_offers
    add column if not exists image_url text,
    add column if not exists image_storage_path text,
    add column if not exists max_redemptions integer check (max_redemptions is null or max_redemptions > 0),
    add column if not exists per_customer_limit integer not null default 1 check (per_customer_limit > 0),
    add column if not exists included_item_ids uuid[],
    add column if not exists excluded_item_ids uuid[] not null default '{}',
    add column if not exists target_customer_ids uuid[];

drop policy if exists "Managers manage offers" on public.business_offers;
create policy "Owners manage offers"
on public.business_offers for all to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
))
with check (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

drop policy if exists "Customers and staff read published offers" on public.business_offers;
create policy "Customers and staff read published offers"
on public.business_offers for select to authenticated
using (
    (is_public and is_active and (target_customer_ids is null or (select auth.uid()) = any(target_customer_ids)))
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role in ('owner', 'manager')
    )
);
grant select (image_url, max_redemptions, per_customer_limit, included_item_ids, excluded_item_ids)
    on public.business_offers to authenticated;

alter table public.business_coupons enable row level security;
revoke all on public.business_coupons from anon, authenticated;
grant select, insert, update, delete on public.business_coupons to authenticated;
create policy "Owners manage coupons"
on public.business_coupons for all to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
))
with check (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

alter table public.business_orders
    add column if not exists coupon_id uuid references public.business_coupons(coupon_id) on delete set null;
alter table public.business_orders
    add column if not exists coupon_code text;
alter table public.business_orders
    add column if not exists coupon_discount numeric(12, 2) not null default 0 check (coupon_discount >= 0);
grant select (coupon_id, coupon_code, coupon_discount) on public.business_orders to authenticated;

create table public.business_coupon_redemptions (
    redemption_id uuid primary key default gen_random_uuid(),
    coupon_id uuid not null references public.business_coupons(coupon_id) on delete restrict,
    customer_id uuid not null references public.customers(id) on delete cascade,
    order_id uuid not null references public.business_orders(order_id) on delete cascade,
    request_id uuid not null,
    subtotal numeric(12, 2) not null check (subtotal >= 0),
    eligible_subtotal numeric(12, 2) not null check (eligible_subtotal >= 0),
    discount_amount numeric(12, 2) not null check (discount_amount >= 0),
    created_at timestamptz not null default now(),
    unique (request_id),
    unique (coupon_id, customer_id, order_id)
);
create index business_coupon_redemptions_customer_idx
    on public.business_coupon_redemptions (coupon_id, customer_id, created_at desc);

alter table public.business_coupon_redemptions enable row level security;
revoke all on public.business_coupon_redemptions from anon, authenticated;
grant select on public.business_coupon_redemptions to authenticated;
create policy "Owners and customers read coupon use"
on public.business_coupon_redemptions for select to authenticated
using (
    customer_id = (select auth.uid())
    or exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

create or replace function public._calculate_customer_coupon(p_customer_id uuid, p_code text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_coupon public.business_coupons%rowtype;
    v_subtotal numeric(12,2);
    v_eligible numeric(12,2);
    v_discount numeric(12,2);
    v_used integer;
    v_customer_used integer;
    v_eligible_items jsonb;
    v_excluded_items jsonb;
begin
    if p_customer_id is null then return jsonb_build_object('is_valid', false, 'reason', 'Authentication required'); end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 then
        return jsonb_build_object('is_valid', false, 'reason', 'Cart is empty');
    end if;
    select * into v_coupon from public.business_coupons c
    where c.code = upper(trim(coalesce(p_code, ''))) and c.is_active
      and (c.target_customer_ids is null or p_customer_id = any(c.target_customer_ids))
      and (c.starts_at is null or c.starts_at <= now())
      and (c.ends_at is null or c.ends_at > now())
    for update;
    if not found then return jsonb_build_object('is_valid', false, 'reason', 'Coupon is invalid or inactive'); end if;

    if exists (
        select 1 from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        where x.item_id is null or x.quantity is null or x.quantity < 1 or x.quantity > 100
    ) or exists (
        select x.item_id from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        group by x.item_id having count(*) > 1
    ) then return jsonb_build_object('is_valid', false, 'reason', 'Cart contains invalid lines'); end if;

    select coalesce(sum(ci.price * x.quantity), 0)::numeric(12,2)
    into v_subtotal
    from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
    join public.business_catalog_items ci on ci.item_id = x.item_id
    where ci.item_type = 'product' and ci.is_active and ci.is_public;

    if (select count(*) from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)) <>
       (select count(*) from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        join public.business_catalog_items ci on ci.item_id = x.item_id
        where ci.item_type = 'product' and ci.is_active and ci.is_public) then
        return jsonb_build_object('is_valid', false, 'reason', 'Cart contains unavailable products');
    end if;
    if v_subtotal < v_coupon.minimum_subtotal then
        return jsonb_build_object('is_valid', false, 'reason', 'Minimum order amount not reached', 'minimum_subtotal', v_coupon.minimum_subtotal);
    end if;

    select coalesce(sum(ci.price * x.quantity) filter (
        where (v_coupon.included_item_ids is null or ci.item_id = any(v_coupon.included_item_ids))
          and not (ci.item_id = any(v_coupon.excluded_item_ids))
    ), 0)::numeric(12,2),
    coalesce(jsonb_agg(jsonb_build_object('item_id', ci.item_id, 'name', ci.name, 'quantity', x.quantity)
        order by ci.name) filter (
        where (v_coupon.included_item_ids is null or ci.item_id = any(v_coupon.included_item_ids))
          and not (ci.item_id = any(v_coupon.excluded_item_ids))
    ), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('item_id', ci.item_id, 'name', ci.name, 'quantity', x.quantity)
        order by ci.name) filter (
        where (v_coupon.included_item_ids is not null and not (ci.item_id = any(v_coupon.included_item_ids)))
          or ci.item_id = any(v_coupon.excluded_item_ids)
    ), '[]'::jsonb)
    into v_eligible, v_eligible_items, v_excluded_items
    from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
    join public.business_catalog_items ci on ci.item_id = x.item_id;
    if v_eligible <= 0 then return jsonb_build_object('is_valid', false, 'reason', 'No cart items are eligible'); end if;

    if v_coupon.first_purchase_only and exists (
        select 1 from public.business_orders o
        where o.customer_id = p_customer_id and o.status <> 'cancelled'
    ) then return jsonb_build_object('is_valid', false, 'reason', 'Coupon is for first purchases only'); end if;

    select count(*)::integer, count(*) filter (where r.customer_id = p_customer_id)::integer
    into v_used, v_customer_used
    from public.business_coupon_redemptions r
    join public.business_orders o on o.order_id = r.order_id
    where r.coupon_id = v_coupon.coupon_id and o.status <> 'cancelled';
    if v_coupon.max_redemptions is not null and v_used >= v_coupon.max_redemptions then
        return jsonb_build_object('is_valid', false, 'reason', 'Coupon usage limit reached');
    end if;
    if v_customer_used >= v_coupon.per_customer_limit then
        return jsonb_build_object('is_valid', false, 'reason', 'Customer usage limit reached');
    end if;

    v_discount := case when v_coupon.discount_type = 'percentage'
        then round(v_eligible * v_coupon.discount_value / 100, 2)
        else least(v_coupon.discount_value, v_eligible) end;
    if v_coupon.max_discount is not null then v_discount := least(v_discount, v_coupon.max_discount); end if;
    v_discount := least(v_discount, v_eligible);
    return jsonb_build_object(
        'is_valid', true, 'coupon_id', v_coupon.coupon_id, 'code', v_coupon.code,
        'title', v_coupon.title, 'description', v_coupon.description,
        'discount_type', v_coupon.discount_type, 'discount_value', v_coupon.discount_value,
        'subtotal', v_subtotal, 'eligible_subtotal', v_eligible, 'discount_amount', v_discount,
        'total_after_discount', v_subtotal - v_discount,
        'eligible_items', v_eligible_items, 'excluded_items', v_excluded_items
    );
end;
$$;

create or replace function public.preview_customer_coupon(p_code text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    return public._calculate_customer_coupon(auth.uid(), p_code, p_items);
end;
$$;

create or replace function public.get_public_customer_coupons()
returns table(code text, title text, description text, image_url text, discount_type text, discount_value numeric,
    max_discount numeric, minimum_subtotal numeric, starts_at timestamptz, ends_at timestamptz,
    first_purchase_only boolean)
language sql
security definer
set search_path = pg_catalog
as $$
    select c.code, c.title, c.description, c.image_url, c.discount_type, c.discount_value,
        c.max_discount, c.minimum_subtotal, c.starts_at, c.ends_at, c.first_purchase_only
    from public.business_coupons c
    where auth.uid() is not null and c.is_active and c.is_public
      and (c.starts_at is null or c.starts_at <= now())
      and (c.ends_at is null or c.ends_at > now())
      and (c.target_customer_ids is null or auth.uid() = any(c.target_customer_ids))
    order by c.starts_at nulls first, c.created_at desc;
$$;

-- Coupon-aware overload. The legacy three-argument RPC remains available for orders without a coupon.
create or replace function public.place_customer_product_order(
    p_items jsonb, p_request_id uuid, p_customer_note text, p_coupon_code text
)
returns table(order_id uuid, order_number text, subtotal numeric, discount numeric, total numeric)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_customer_id uuid := auth.uid();
    v_existing public.business_orders%rowtype;
    v_coupon_result jsonb;
    v_item record;
    v_order_id uuid;
    v_order_number text;
    v_total numeric(12,2) := 0;
    v_discount numeric(12,2) := 0;
    v_customer_name text;
    v_item_count integer;
begin
    if v_customer_id is null then raise exception 'Authentication required'; end if;
    if p_request_id is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
        raise exception 'A request id and a valid product cart are required';
    end if;
    if length(coalesce(p_customer_note, '')) > 1000 then raise exception 'The delivery note is too long'; end if;
    select count(*) into v_item_count from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer);
    if v_item_count < 1 or v_item_count > 50 then raise exception 'A product order must contain between 1 and 50 lines'; end if;
    if exists (
        select x.item_id from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        group by x.item_id having count(*) > 1
    ) then raise exception 'Duplicate product rows are not allowed'; end if;
    if exists (
        select 1 from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        where x.item_id is null or x.quantity is null or x.quantity < 1 or x.quantity > 100
    ) then raise exception 'Product quantities must be between 1 and 100'; end if;
    if (select count(*) from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        join public.business_catalog_items ci on ci.item_id = x.item_id
        where ci.item_type = 'product' and ci.is_active and ci.is_public) <> v_item_count then
        raise exception 'A selected product is unavailable';
    end if;
    select * into v_existing from public.business_orders o
    where o.customer_id = v_customer_id and o.customer_request_id = p_request_id;
    if found then
        if coalesce(v_existing.coupon_code, '') <> upper(trim(coalesce(p_coupon_code, ''))) then
            raise exception 'This request id was already used with different coupon details';
        end if;
        select coalesce(sum(oi.subtotal), 0)::numeric(12,2) into v_total
        from public.business_order_items oi where oi.order_id = v_existing.order_id;
        return query select v_existing.order_id, v_existing.order_number,
            v_total, v_existing.coupon_discount, v_total - v_existing.coupon_discount;
        return;
    end if;
    if coalesce(trim(p_coupon_code), '') <> '' then
        v_coupon_result := public._calculate_customer_coupon(v_customer_id, p_coupon_code, p_items);
        if coalesce((v_coupon_result->>'is_valid')::boolean, false) is not true then
            raise exception 'Coupon could not be applied: %', coalesce(v_coupon_result->>'reason', 'invalid coupon');
        end if;
        v_discount := (v_coupon_result->>'discount_amount')::numeric;
    end if;

    for v_item in
        select ci.item_id, ci.name, ci.price, x.quantity, ci.stock_quantity
        from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
        join public.business_catalog_items ci on ci.item_id = x.item_id
        where ci.item_type = 'product' and ci.is_active and ci.is_public
        order by ci.item_id
        for update of ci
    loop
        if v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 100 then raise exception 'Invalid quantity'; end if;
        if v_item.stock_quantity is not null and v_item.stock_quantity < v_item.quantity then raise exception 'Insufficient stock for product: %', v_item.name; end if;
        if v_item.stock_quantity is not null then
            update public.business_catalog_items set stock_quantity = stock_quantity - v_item.quantity, updated_at = now()
            where item_id = v_item.item_id;
        end if;
        v_total := v_total + v_item.price * v_item.quantity;
    end loop;
    if v_total <= 0 then raise exception 'The cart does not contain available products'; end if;
    select c.full_name into v_customer_name from public.customers c where c.id = v_customer_id;
    v_order_id := gen_random_uuid();
    v_order_number := 'SHOP-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
    insert into public.business_orders(
        order_id, order_number, customer_id, customer_name, service_name, status, order_type,
        customer_request_id, created_by, notes, coupon_id, coupon_code, coupon_discount
    ) values (
        v_order_id, v_order_number, v_customer_id, v_customer_name,
        'طلب منتجات من تطبيق Sabiha Hub', 'received', 'product', p_request_id,
        'customer_app', nullif(trim(p_customer_note), ''),
        nullif(v_coupon_result->>'coupon_id', '')::uuid,
        nullif(upper(trim(p_coupon_code)), ''), v_discount
    );
    insert into public.business_order_items(order_id, item_id, item_name, quantity, unit_price, subtotal)
    select v_order_id, ci.item_id, ci.name, x.quantity, ci.price, ci.price * x.quantity
    from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
    join public.business_catalog_items ci on ci.item_id = x.item_id;
    if v_discount > 0 then
        insert into public.business_coupon_redemptions(coupon_id, customer_id, order_id, request_id, subtotal, eligible_subtotal, discount_amount)
        values ((v_coupon_result->>'coupon_id')::uuid, v_customer_id, v_order_id, p_request_id,
            v_total, (v_coupon_result->>'eligible_subtotal')::numeric, v_discount);
    end if;
    return query select v_order_id, v_order_number, v_total, v_discount, v_total - v_discount;
end;
$$;

revoke all on function public._calculate_customer_coupon(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.preview_customer_coupon(text, jsonb) from public, anon;
grant execute on function public.preview_customer_coupon(text, jsonb) to authenticated;
revoke all on function public.get_public_customer_coupons() from public, anon;
grant execute on function public.get_public_customer_coupons() to authenticated;
revoke all on function public.place_customer_product_order(jsonb, uuid, text, text) from public, anon;
grant execute on function public.place_customer_product_order(jsonb, uuid, text, text) to authenticated;
