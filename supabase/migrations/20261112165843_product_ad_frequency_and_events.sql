alter table public.customer_marketing_preferences
    add column marketing_in_app_enabled boolean not null default false;

create table public.business_product_ads (
    ad_id uuid primary key default gen_random_uuid(),
    item_id uuid not null references public.business_catalog_items(item_id) on delete cascade,
    title text not null check (length(trim(title)) between 1 and 120),
    description text not null check (length(trim(description)) between 1 and 500),
    image_url text,
    discounted_price numeric(12, 2) check (discounted_price is null or discounted_price >= 0),
    starts_at timestamptz not null default now(),
    ends_at timestamptz,
    frequency_days integer not null default 7 check (frequency_days between 1 and 365),
    target_customer_ids uuid[],
    priority integer not null default 0,
    is_active boolean not null default true,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (ends_at is null or ends_at > starts_at)
);

create index business_product_ads_active_window_idx
    on public.business_product_ads (priority desc, starts_at, ends_at)
    where is_active;

alter table public.business_product_ads enable row level security;
revoke all on public.business_product_ads from anon, authenticated;

create table public.business_product_ad_customer_state (
    ad_id uuid not null references public.business_product_ads(ad_id) on delete cascade,
    customer_id uuid not null references public.customers(id) on delete cascade,
    last_shown_at timestamptz not null,
    impression_count integer not null default 1,
    click_count integer not null default 0,
    dismissed_at timestamptz,
    primary key (ad_id, customer_id)
);

create table public.business_product_ad_events (
    event_id uuid primary key default gen_random_uuid(),
    ad_id uuid not null references public.business_product_ads(ad_id) on delete cascade,
    customer_id uuid not null references public.customers(id) on delete cascade,
    event_type text not null check (event_type in ('impression', 'click', 'dismiss', 'purchase')),
    order_id uuid references public.business_orders(order_id) on delete set null,
    occurred_at timestamptz not null default now()
);

create index business_product_ad_events_ad_type_idx
    on public.business_product_ad_events (ad_id, event_type, occurred_at desc);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'business-product-ads', 'business-product-ads', true, 5242880,
    array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = true,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Public can view product advertisement images"
on storage.objects for select to anon, authenticated
using (bucket_id = 'business-product-ads');

create policy "Owners upload product advertisement images"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'business-product-ads'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

create policy "Owners update product advertisement images"
on storage.objects for update to authenticated
using (
    bucket_id = 'business-product-ads'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
)
with check (
    bucket_id = 'business-product-ads'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

create policy "Owners delete product advertisement images"
on storage.objects for delete to authenticated
using (
    bucket_id = 'business-product-ads'
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

alter table public.business_product_ad_customer_state enable row level security;
alter table public.business_product_ad_events enable row level security;
revoke all on public.business_product_ad_customer_state, public.business_product_ad_events from anon, authenticated;
grant select on public.business_product_ad_events to authenticated;

create policy "Owners review product ad analytics"
on public.business_product_ad_events for select to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

create or replace function public.claim_customer_product_ad()
returns table (
    ad_id uuid,
    item_id uuid,
    title text,
    description text,
    image_url text,
    original_price numeric,
    discounted_price numeric,
    product_name text,
    frequency_days integer
)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_customer_id uuid := auth.uid();
    v_ad public.business_product_ads%rowtype;
    v_claimed integer;
begin
    if v_customer_id is null then raise exception 'Authentication required'; end if;
    if not exists (
        select 1 from public.customer_marketing_preferences p
        where p.customer_id = v_customer_id and p.marketing_in_app_enabled
    ) then return; end if;

    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_customer_id::text, 0));
    for v_ad in
        select a.*
        from public.business_product_ads a
        join public.business_catalog_items ci on ci.item_id = a.item_id
        where a.is_active
          and a.starts_at <= now()
          and (a.ends_at is null or a.ends_at > now())
          and ci.item_type = 'product' and ci.is_active and ci.is_public
          and (a.target_customer_ids is null or v_customer_id = any(a.target_customer_ids))
          and (
              not exists (
                  select 1 from public.business_product_ad_customer_state s
                  where s.ad_id = a.ad_id and s.customer_id = v_customer_id
              )
              or exists (
                  select 1 from public.business_product_ad_customer_state s
                  where s.ad_id = a.ad_id and s.customer_id = v_customer_id
                    and s.last_shown_at <= now() - make_interval(days => a.frequency_days)
              )
          )
        order by a.priority desc, a.starts_at desc, a.created_at desc
        limit 20
        for update of a skip locked
    loop
        insert into public.business_product_ad_customer_state (ad_id, customer_id, last_shown_at, impression_count)
        values (v_ad.ad_id, v_customer_id, now(), 1)
        on conflict (ad_id, customer_id) do update
        set last_shown_at = now(),
            impression_count = business_product_ad_customer_state.impression_count + 1,
            dismissed_at = null
        where business_product_ad_customer_state.last_shown_at <= now() - make_interval(days => v_ad.frequency_days)
        returning 1 into v_claimed;
        if found then
            insert into public.business_product_ad_events (ad_id, customer_id, event_type)
            values (v_ad.ad_id, v_customer_id, 'impression');
            return query
            select v_ad.ad_id, ci.item_id, v_ad.title, v_ad.description, v_ad.image_url,
                ci.price, case when v_ad.discounted_price between 0 and ci.price then v_ad.discounted_price else null end,
                ci.name, v_ad.frequency_days
            from public.business_catalog_items ci where ci.item_id = v_ad.item_id;
            return;
        end if;
    end loop;
end;
$$;

create or replace function public.record_customer_product_ad_event(p_ad_id uuid, p_event_type text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_customer_id uuid := auth.uid();
begin
    if v_customer_id is null then raise exception 'Authentication required'; end if;
    if p_event_type not in ('click', 'dismiss') then raise exception 'Unsupported ad event'; end if;
    update public.business_product_ad_customer_state
    set click_count = click_count + case when p_event_type = 'click' then 1 else 0 end,
        dismissed_at = case when p_event_type = 'dismiss' then now() else dismissed_at end
    where ad_id = p_ad_id and customer_id = v_customer_id;
    if not found then return false; end if;
    insert into public.business_product_ad_events (ad_id, customer_id, event_type)
    values (p_ad_id, v_customer_id, p_event_type);
    return true;
end;
$$;

create or replace function public.place_customer_ad_product_order(
    p_ad_id uuid,
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
    v_ad public.business_product_ads%rowtype;
    v_item public.business_catalog_items%rowtype;
    v_existing record;
    v_order_id uuid;
    v_order_number text;
    v_unit_price numeric(12, 2);
begin
    if v_customer_id is null then raise exception 'Authentication required'; end if;
    if p_request_id is null or length(coalesce(p_customer_note, '')) > 1000 then
        raise exception 'A request id and a valid delivery note are required';
    end if;
    select o.order_id, o.order_number into v_existing
    from public.business_orders o
    where o.customer_id = v_customer_id and o.customer_request_id = p_request_id;
    if found then
        select coalesce(sum(oi.subtotal), 0) into v_unit_price
        from public.business_order_items oi where oi.order_id = v_existing.order_id;
        return query select v_existing.order_id, v_existing.order_number, v_unit_price;
        return;
    end if;
    if not exists (
        select 1 from public.customer_marketing_preferences p
        join public.business_product_ad_customer_state s on s.customer_id = p.customer_id
        where p.customer_id = v_customer_id
          and p.marketing_in_app_enabled
          and s.ad_id = p_ad_id
          and s.last_shown_at > now() - make_interval(days => (
              select a.frequency_days from public.business_product_ads a where a.ad_id = p_ad_id
          ))
    ) then
        raise exception 'The product ad is no longer eligible for this customer';
    end if;
    select * into v_ad from public.business_product_ads a
    where a.ad_id = p_ad_id and a.is_active and a.starts_at <= now()
      and (a.ends_at is null or a.ends_at > now())
      and (a.target_customer_ids is null or v_customer_id = any(a.target_customer_ids))
    for update;
    if not found then raise exception 'This product ad is no longer available'; end if;
    select * into v_item from public.business_catalog_items ci
    where ci.item_id = v_ad.item_id and ci.item_type = 'product' and ci.is_active and ci.is_public
    for update;
    if not found then raise exception 'This product is no longer available'; end if;
    v_unit_price := case when v_ad.discounted_price between 0 and v_item.price then v_ad.discounted_price else v_item.price end;
    if v_item.stock_quantity is not null and v_item.stock_quantity < 1 then raise exception 'This product is out of stock'; end if;
    if v_item.stock_quantity is not null then
        update public.business_catalog_items
        set stock_quantity = stock_quantity - 1, updated_at = now()
        where item_id = v_item.item_id;
    end if;
    v_order_id := gen_random_uuid();
    v_order_number := 'AD-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
    insert into public.business_orders (
        order_id, order_number, customer_id, customer_name, service_name,
        status, order_type, customer_request_id, created_by, notes
    )
    select v_order_id, v_order_number, v_customer_id, c.full_name, v_item.name,
        'received', 'product', p_request_id, 'product_ad', nullif(trim(p_customer_note), '')
    from public.customers c where c.id = v_customer_id;
    insert into public.business_order_items (order_id, item_id, item_name, quantity, unit_price, subtotal)
    values (v_order_id, v_item.item_id, v_item.name, 1, v_unit_price, v_unit_price);
    insert into public.business_product_ad_events (ad_id, customer_id, event_type, order_id)
    values (v_ad.ad_id, v_customer_id, 'purchase', v_order_id);
    return query select v_order_id, v_order_number, v_unit_price;
end;
$$;

revoke all on function public.claim_customer_product_ad() from public, anon;
grant execute on function public.claim_customer_product_ad() to authenticated;
revoke all on function public.record_customer_product_ad_event(uuid, text) from public, anon;
grant execute on function public.record_customer_product_ad_event(uuid, text) to authenticated;
revoke all on function public.place_customer_ad_product_order(uuid, uuid, text) from public, anon;
grant execute on function public.place_customer_ad_product_order(uuid, uuid, text) to authenticated;
