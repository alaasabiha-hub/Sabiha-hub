-- Local-only prepared change. Review before applying to any hosted project.
-- Order RLS already decides which orders a caller can see. Reuse that decision
-- without referencing assigned_workers, which is intentionally not client-readable.
drop policy "Customers and staff read authorized order items" on public.business_order_items;
create policy "Customers and staff read authorized order items"
on public.business_order_items for select to authenticated
using (exists (select 1 from public.business_orders o where o.order_id = business_order_items.order_id));

create or replace function public.enforce_business_status_transition()
returns trigger language plpgsql set search_path = pg_catalog as $$
declare v_employee boolean;
begin
    if new.status is not distinct from old.status then return new; end if;
    select exists(select 1 from public.staff_profiles sp
        where sp.user_id = auth.uid() and sp.is_active and sp.role = 'employee') into v_employee;
    if tg_table_name = 'bookings' then
        if not ((old.status = 'pending' and new.status in ('confirmed','cancelled'))
            or (old.status = 'confirmed' and new.status in ('in_progress','cancelled'))
            or (old.status = 'in_progress' and new.status in ('completed','cancelled'))) then
            raise exception 'Invalid booking status transition: % -> %', old.status, new.status;
        end if;
        if v_employee and not ((old.status = 'confirmed' and new.status = 'in_progress')
            or (old.status = 'in_progress' and new.status = 'completed')) then
            raise exception 'Employees can only progress their assigned booking';
        end if;
    else
        if not ((old.status = 'received' and new.status in ('in_progress','cancelled'))
            or (old.status = 'in_progress' and new.status in ('quality_check','cancelled'))
            or (old.status = 'quality_check' and new.status in ('completed','cancelled'))
            or (old.status = 'completed' and new.status in ('delivered','cancelled'))) then
            raise exception 'Invalid order status transition: % -> %', old.status, new.status;
        end if;
        if v_employee and not ((old.status = 'received' and new.status = 'in_progress')
            or (old.status = 'in_progress' and new.status = 'quality_check')
            or (old.status = 'quality_check' and new.status = 'completed')) then
            raise exception 'Employees can only progress their assigned work';
        end if;
    end if;
    return new;
end;
$$;
revoke all on function public.enforce_business_status_transition() from public;
create trigger enforce_booking_status_transition before update of status on public.bookings
for each row execute function public.enforce_business_status_transition();
create trigger enforce_order_status_transition before update of status on public.business_orders
for each row execute function public.enforce_business_status_transition();


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

    perform pg_advisory_xact_lock(hashtextextended(v_customer_id::text || p_request_id::text, 0));
    select o.order_id, o.order_number into v_existing
    from public.business_orders o
    where o.customer_id = v_customer_id and o.customer_request_id = p_request_id;
    if found then
        if exists (
            (select x.item_id, x.quantity from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
             except select oi.item_id, oi.quantity from public.business_order_items oi where oi.order_id = v_existing.order_id)
            union all
            (select oi.item_id, oi.quantity from public.business_order_items oi where oi.order_id = v_existing.order_id
             except select x.item_id, x.quantity from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer))
        ) then raise exception 'This request id was already used with a different cart'; end if;
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
    perform pg_advisory_xact_lock(hashtextextended(v_customer_id::text || p_request_id::text, 0));
    select * into v_existing from public.business_orders o
    where o.customer_id = v_customer_id and o.customer_request_id = p_request_id;
    if found then
        if exists (
            (select x.item_id, x.quantity from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer)
             except select oi.item_id, oi.quantity from public.business_order_items oi where oi.order_id = v_existing.order_id)
            union all
            (select oi.item_id, oi.quantity from public.business_order_items oi where oi.order_id = v_existing.order_id
             except select x.item_id, x.quantity from jsonb_to_recordset(p_items) as x(item_id uuid, quantity integer))
        ) then raise exception 'This request id was already used with a different cart'; end if;
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

-- Avoid OUT-parameter names shadowing ON CONFLICT columns.
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
        on conflict on constraint business_product_ad_customer_state_pkey do update
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

-- Avoid OUT-parameter names shadowing ON CONFLICT columns.
create or replace function public.claim_due_marketing_campaigns(p_now timestamptz default now(), p_limit integer default 25)
returns table (run_id uuid, campaign_id uuid, scheduled_for timestamptz)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_campaign public.marketing_campaigns%rowtype;
    v_run_id uuid;
    v_next_local timestamp;
    v_next timestamptz;
begin
    for v_campaign in
        select * from public.marketing_campaigns c
        where c.status = 'scheduled'
          and c.next_scheduled_at <= p_now
          and (c.recurrence_ends_at is null or c.next_scheduled_at <= c.recurrence_ends_at)
        order by c.next_scheduled_at
        limit greatest(1, least(p_limit, 100))
        for update skip locked
    loop
        v_run_id := null;
        insert into public.marketing_campaign_runs (campaign_id, scheduled_for, status, started_at)
        values (v_campaign.campaign_id, v_campaign.next_scheduled_at, 'sending', p_now)
        on conflict do nothing
        returning marketing_campaign_runs.run_id into v_run_id;

        if v_run_id is not null then
            if v_campaign.recurrence = 'once' then
                update public.marketing_campaigns
                set status = 'sending', updated_at = p_now
                where marketing_campaigns.campaign_id = v_campaign.campaign_id;
            else
                v_next_local := v_campaign.next_scheduled_at at time zone v_campaign.time_zone;
                v_next_local := case v_campaign.recurrence
                    when 'daily' then v_next_local + interval '1 day'
                    when 'weekly' then v_next_local + interval '1 week'
                    else v_next_local + interval '1 month'
                end;
                v_next := v_next_local at time zone v_campaign.time_zone;
                update public.marketing_campaigns
                set next_scheduled_at = v_next,
                    status = case
                        when recurrence_ends_at is not null and v_next > recurrence_ends_at then 'completed'
                        else 'scheduled'
                    end,
                    updated_at = p_now
                where marketing_campaigns.campaign_id = v_campaign.campaign_id;
            end if;
            run_id := v_run_id;
            campaign_id := v_campaign.campaign_id;
            scheduled_for := v_campaign.next_scheduled_at;
            return next;
        end if;
    end loop;
end;
$$;

-- Avoid OUT-parameter names shadowing ON CONFLICT columns.
create or replace function public.claim_due_business_document_alerts(p_today date default current_date, p_limit integer default 100)
returns table(alert_id uuid, document_id uuid, title text, category text, expires_at date, days_before_expiry integer)
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
    if p_limit < 1 or p_limit > 500 then raise exception 'Invalid batch size'; end if;

    insert into public.business_document_alerts(document_id, alert_date, days_before_expiry)
    select d.document_id, (d.expires_at - lead_days.days)::date, lead_days.days
    from public.business_documents d
    cross join (values (30), (15), (7), (0)) as lead_days(days)
    where d.expires_at is not null
      and d.expires_at - lead_days.days <= p_today
      and d.expires_at - lead_days.days >= p_today - 30
    on conflict do nothing;

    insert into public.business_document_alerts(document_id, alert_date, days_before_expiry)
    select d.document_id, p_today, -1
    from public.business_documents d
    where d.expires_at < p_today
    on conflict do nothing;

    return query
    with picked as (
        select a.alert_id
        from public.business_document_alerts a
        where a.alert_date <= p_today
          and a.delivery_status in ('queued', 'failed')
          and a.sent_at is null
          and a.attempt_count < 3
        order by a.alert_date, a.created_at
        for update skip locked
        limit p_limit
    ), claimed as (
        update public.business_document_alerts a
        set delivery_status = 'sending', attempt_count = a.attempt_count + 1,
            last_error = null
        from picked
        where a.alert_id = picked.alert_id
        returning a.*
    )
    select c.alert_id, d.document_id, d.title, d.category, d.expires_at, c.days_before_expiry
    from claimed c join public.business_documents d using (document_id);
end;
$$;
