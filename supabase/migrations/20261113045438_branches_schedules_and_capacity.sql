-- Additive local migration. Existing records belong to the first, renameable Egyptian branch.
create table public.business_branches (
 branch_id uuid primary key default gen_random_uuid(), name_ar text not null check(length(trim(name_ar)) between 2 and 120),
 name_en text not null check(length(trim(name_en)) between 2 and 120), is_default boolean not null default false,
 is_active boolean not null default true, temporarily_closed boolean not null default false,
 address_ar text not null default '', address_en text not null default '', maps_url text not null default '',
 time_zone text not null default 'Africa/Cairo' check(time_zone='Africa/Cairo'), currency text not null default 'EGP' check(currency='EGP'),
 delivery_enabled boolean not null default false, minimum_subtotal numeric(12,2) not null default 0 check(minimum_subtotal>=0),
 whatsapp_phone text not null default '' check(whatsapp_phone='' or whatsapp_phone ~ '^\+[1-9][0-9]{7,14}$'),
 check(maps_url='' or maps_url ~ '^https://(maps\.app\.goo\.gl/|maps\.google\.com/|www\.google\.com/maps)')
);
create unique index one_default_branch on public.business_branches(is_default) where is_default;
insert into public.business_branches(name_ar,name_en,is_default,delivery_enabled,minimum_subtotal)
 select 'الفرع الرئيسي','Main branch',true,delivery_enabled,minimum_subtotal from public.business_contact_delivery_settings where id;
create function public.default_branch_id() returns uuid language sql stable security invoker set search_path=pg_catalog as $$ select branch_id from public.business_branches where is_default; $$;
revoke all on function public.default_branch_id() from public;
grant execute on function public.default_branch_id() to anon,authenticated,service_role;
create table public.business_branch_hours (
 branch_id uuid not null references public.business_branches(branch_id),weekday integer not null check(weekday between 0 and 6),
 is_open boolean not null default true,opens_at time not null default '09:00',closes_at time not null default '22:00',
 primary key(branch_id,weekday),check(closes_at>opens_at)
);
create table public.business_branch_exceptions (
 branch_id uuid not null references public.business_branches(branch_id),exception_date date not null,
 is_closed boolean not null default true,opens_at time,closes_at time,reason text not null check(length(trim(reason)) between 2 and 300),
 primary key(branch_id,exception_date),check(is_closed or opens_at is not null and closes_at>opens_at)
);
create table public.business_branch_resources (
 branch_id uuid not null references public.business_branches(branch_id),resource_key text not null check(resource_key in ('wash','polish')),
 capacity integer not null check(capacity between 1 and 100),primary key(branch_id,resource_key)
);
create function private.initialize_branch() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 insert into public.business_branch_hours(branch_id,weekday) select new.branch_id,d from generate_series(0,6) d;
 insert into public.business_branch_resources(branch_id,resource_key,capacity) values(new.branch_id,'wash',2),(new.branch_id,'polish',1);
 return new; end; $$;
revoke all on function private.initialize_branch() from public;
create trigger initialize_branch after insert on public.business_branches for each row execute function private.initialize_branch();
insert into public.business_branch_hours(branch_id,weekday) select branch_id,d from public.business_branches cross join generate_series(0,6) d;
insert into public.business_branch_resources(branch_id,resource_key,capacity) select branch_id,'wash',4 from public.business_branches union all select branch_id,'polish',1 from public.business_branches;
create table public.staff_branch_access (
 user_id uuid not null references public.staff_profiles(user_id),branch_id uuid not null references public.business_branches(branch_id),
 can_edit_prices boolean not null default false,primary key(user_id,branch_id)
);
insert into public.staff_branch_access(user_id,branch_id) select user_id,public.default_branch_id() from public.staff_profiles;
create function private.can_access_branch(p_branch uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select private.active_staff_role()='owner' or (private.active_staff_role() in ('manager','employee') and exists(select 1 from public.staff_branch_access where user_id=auth.uid() and branch_id=p_branch));
$$;
create function private.can_price_branch(p_branch uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select private.active_staff_role()='owner' or (private.active_staff_role()='manager' and exists(select 1 from public.staff_branch_access where user_id=auth.uid() and branch_id=p_branch and can_edit_prices));
$$;
revoke all on function private.can_access_branch(uuid),private.can_price_branch(uuid) from public,anon;
grant execute on function private.can_access_branch(uuid),private.can_price_branch(uuid) to authenticated,service_role;

alter table public.business_catalog_items add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id),
 add column catalog_key uuid not null default gen_random_uuid(),add column duration_minutes integer not null default 60 check(duration_minutes between 5 and 480),
 add column resource_key text not null default 'wash' check(resource_key in ('wash','polish'));
update public.business_catalog_items set catalog_key=item_id;
do $$ declare r record; begin
 for r in select conname from pg_constraint where conrelid='public.business_catalog_items'::regclass and contype='u' and pg_get_constraintdef(oid)='UNIQUE (item_type, name, vehicle_type)' loop execute format('alter table public.business_catalog_items drop constraint %I',r.conname);end loop;
end; $$;
create unique index branch_catalog_key on public.business_catalog_items(branch_id,catalog_key);
create unique index branch_catalog_name on public.business_catalog_items(branch_id,item_type,name,coalesce(vehicle_type,''));
alter table public.bookings add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id),
 add column duration_minutes integer not null default 60 check(duration_minutes between 5 and 480),
 add column resource_key text not null default 'wash',add column capacity_override_reason text;
alter table public.business_orders add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_invoices add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_expenses add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_offers add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_coupons add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_delivery_zones add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
alter table public.business_order_fulfillments add column branch_id uuid not null default public.default_branch_id() references public.business_branches(branch_id);
create index bookings_branch_slot on public.bookings(branch_id,booking_date,resource_key,booking_time) where status<>'cancelled';
create index orders_branch_idx on public.business_orders(branch_id,created_at desc);
create index invoices_branch_idx on public.business_invoices(branch_id,issued_at desc);
create index expenses_branch_idx on public.business_expenses(branch_id,expense_date);
drop index public.business_expenses_date_category_uidx;
create unique index business_expenses_branch_date_category_uidx on public.business_expenses(branch_id,expense_date,category);

grant select on public.business_branches,public.business_branch_hours,public.business_branch_exceptions,public.business_branch_resources to anon,authenticated;
grant insert,update on public.business_branches,public.business_branch_hours,public.business_branch_exceptions,public.business_branch_resources to authenticated;
grant delete on public.business_branch_exceptions to authenticated;
grant select,insert,update,delete on public.staff_branch_access to authenticated;
grant select(branch_id,catalog_key,duration_minutes,resource_key,stock_quantity,created_at,updated_at) on public.business_catalog_items to authenticated;
grant select(branch_id,duration_minutes,resource_key,capacity_override_reason),insert(branch_id),update(branch_id,vehicle_id,catalog_item_id,capacity_override_reason) on public.bookings to authenticated;
grant select(branch_id) on public.business_orders,public.business_invoices,public.business_offers,public.business_coupons to authenticated;
do $$ declare tab text; begin
 foreach tab in array array['business_branches','business_branch_hours','business_branch_exceptions','business_branch_resources','staff_branch_access'] loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('grant all on public.%I to service_role',tab);
 execute format('create policy "Owner manages branch configuration" on public.%I for all to authenticated using ((select private.active_staff_role())=''owner'') with check ((select private.active_staff_role())=''owner'')',tab);
 if tab<>'staff_branch_access' then execute format('create policy "Read branch information" on public.%I for select to anon,authenticated using(true)',tab);
 else execute 'create policy "Read own branch membership" on public.staff_branch_access for select to authenticated using(user_id=(select auth.uid()))';end if;
 end loop;
end; $$;
create policy "Branch booking boundary" on public.bookings as restrictive for all to authenticated using((select private.active_staff_role()) is null or (select private.can_access_branch(branch_id))) with check((select private.active_staff_role()) is null or (select private.can_access_branch(branch_id)));
create policy "Branch order boundary" on public.business_orders as restrictive for all to authenticated using((select private.active_staff_role()) is null or (select private.can_access_branch(branch_id))) with check((select private.active_staff_role()) is null or (select private.can_access_branch(branch_id)));
create policy "Branch delivery boundary" on public.business_order_fulfillments as restrictive for select to authenticated using((select private.active_staff_role()) is null or (select private.can_access_branch(branch_id)));
create policy "Branch catalog edits" on public.business_catalog_items as restrictive for update to authenticated using((select private.can_price_branch(branch_id))) with check((select private.can_price_branch(branch_id)));
create policy "Branch catalog inserts" on public.business_catalog_items as restrictive for insert to authenticated with check((select private.can_price_branch(branch_id)));
create policy "Only owner deletes catalog" on public.business_catalog_items as restrictive for delete to authenticated using((select private.active_staff_role())='owner');

-- Reuse the existing audit log; never expose credentials, passwords or customer address snapshots.
alter table public.business_audit_log add column branch_id uuid references public.business_branches(branch_id),add column actor_id uuid,
 add column before_data jsonb,add column after_data jsonb,add column reason text;
grant select on public.business_audit_log to authenticated;
create policy "Owner reads audit events" on public.business_audit_log for select to authenticated using((select private.active_staff_role())='owner');
create function private.audit_branch_change() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_old jsonb;v_new jsonb;v_branch uuid;begin
 if tg_op<>'INSERT' then v_old=to_jsonb(old);end if;if tg_op<>'DELETE' then v_new=to_jsonb(new);end if;
 v_branch:=nullif(coalesce(v_new->>'branch_id',v_old->>'branch_id'),'')::uuid;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data,reason)
 values(coalesce(auth.uid()::text,'local_server'),auth.uid(),tg_op,tg_table_name,coalesce(v_new->>'item_id',v_new->>'branch_id',v_old->>'branch_id'),v_branch,v_old,v_new,coalesce(v_new->>'reason',v_new->>'capacity_override_reason'));
 return coalesce(new,old);end; $$;
revoke all on function private.audit_branch_change() from public;
do $$ declare tab text;begin foreach tab in array array['business_branches','business_branch_hours','business_branch_exceptions','business_branch_resources','staff_branch_access','business_catalog_items'] loop
 execute format('create trigger audit_branch_change after insert or update or delete on public.%I for each row execute function private.audit_branch_change()',tab);
end loop;end; $$;

create function private.enforce_booking_capacity() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare b public.business_branches%rowtype;h public.business_branch_hours%rowtype;e public.business_branch_exceptions%rowtype;
 c public.business_catalog_items%rowtype;v_open time;v_close time;v_start timestamp;v_end timestamp;v_count integer;v_capacity integer;
begin
 if tg_op='UPDATE' and new.branch_id=old.branch_id and new.booking_date=old.booking_date and new.booking_time=old.booking_time and new.catalog_item_id is not distinct from old.catalog_item_id then return new;end if;
 if new.capacity_override_reason is not null and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can override capacity';end if;
 select * into strict b from public.business_branches where branch_id=new.branch_id for share;
 if not b.is_active or b.temporarily_closed then raise exception 'Branch is closed';end if;
 if new.catalog_item_id is not null then
  select * into c from public.business_catalog_items where item_id=new.catalog_item_id and branch_id=new.branch_id and item_type='service' and is_active and is_public;
  if not found then raise exception 'Service does not belong to selected branch';end if;
  new.duration_minutes:=c.duration_minutes;new.resource_key:=c.resource_key;
  if tg_op='INSERT' then new.quoted_price:=c.price;new.service_name:=c.name;new.vehicle_type:=c.vehicle_type;end if;
 end if;
 v_start:=new.booking_date+new.booking_time;v_end:=v_start+make_interval(mins=>new.duration_minutes);
 if v_start at time zone b.time_zone<=now() then raise exception 'Choose a future appointment';end if;
 select * into h from public.business_branch_hours where branch_id=new.branch_id and weekday=extract(dow from new.booking_date)::integer;
 if not found then raise exception 'Branch hours not configured';end if;
 v_open:=h.opens_at;v_close:=h.closes_at;
 select * into e from public.business_branch_exceptions where branch_id=new.branch_id and exception_date=new.booking_date;
 if found then if e.is_closed then raise exception 'Branch closed on this date';end if;v_open:=e.opens_at;v_close:=e.closes_at;
 elsif not h.is_open then raise exception 'Branch closed on this weekday';end if;
 if new.booking_time<v_open or v_end>new.booking_date+v_close then raise exception 'Appointment outside opening hours';end if;
 perform pg_advisory_xact_lock(hashtextextended(new.branch_id::text||new.booking_date::text||new.resource_key,0));
 select capacity into v_capacity from public.business_branch_resources where branch_id=new.branch_id and resource_key=new.resource_key;
 if v_capacity is null then raise exception 'Resource not configured';end if;
 -- Maximum simultaneous occupancy inside the proposed interval, not merely a count of intersecting visits.
 select coalesce(max(occupied),0) into v_count from (
  select (select count(*) from public.bookings q where q.branch_id=new.branch_id and q.booking_date=new.booking_date and q.resource_key=new.resource_key
   and q.status not in ('cancelled','completed') and q.id is distinct from new.id
   and q.booking_date+q.booking_time<=point and q.booking_date+q.booking_time+make_interval(mins=>q.duration_minutes)>point) occupied
  from (select v_start as point union select q.booking_date+q.booking_time from public.bookings q where q.branch_id=new.branch_id and q.booking_date=new.booking_date
   and q.resource_key=new.resource_key and q.status not in ('cancelled','completed') and q.id is distinct from new.id and q.booking_date+q.booking_time>v_start and q.booking_date+q.booking_time<v_end) points
 ) counts;
 if v_count>=v_capacity and length(trim(coalesce(new.capacity_override_reason,'')))<5 then raise exception 'Branch capacity reached';end if;
 if new.vehicle_id is not null and exists(select 1 from public.bookings q where q.vehicle_id=new.vehicle_id and q.id is distinct from new.id and q.status not in ('cancelled','completed') and q.booking_date+q.booking_time<v_end and q.booking_date+q.booking_time+make_interval(mins=>q.duration_minutes)>v_start) then raise exception 'Vehicle already booked in this interval';end if;
 if v_count>=v_capacity then insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason) values(auth.uid()::text,auth.uid(),'capacity_override','bookings',new.id::text,new.branch_id,new.capacity_override_reason);end if;
 return new;end; $$;
revoke all on function private.enforce_booking_capacity() from public;
create trigger z_enforce_booking_capacity before insert or update of branch_id,booking_date,booking_time,catalog_item_id on public.bookings for each row execute function private.enforce_booking_capacity();

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
    v_branch uuid;
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

    select ci.branch_id into v_branch from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id limit 1;
    if (select count(distinct ci.branch_id) from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id)<>1 then raise exception 'A cart must belong to one branch';end if;
    if not exists(select 1 from public.business_branches where branch_id=v_branch and is_active and not temporarily_closed) then raise exception 'Branch closed';end if;
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
        branch_id, order_id, order_number, customer_id, customer_name, service_name,
        status, order_type, customer_request_id, created_by, notes
    ) values (
        v_branch, v_order_id, v_order_number, v_customer_id, v_customer_name,
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
    v_branch uuid;
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
    select ci.branch_id into v_branch from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id limit 1;
    if (select count(distinct ci.branch_id) from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id)<>1 then raise exception 'A cart must belong to one branch';end if;
    if not exists(select 1 from public.business_branches where branch_id=v_branch and is_active and not temporarily_closed) then raise exception 'Branch closed';end if;
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
        if not exists(select 1 from public.business_coupons where code=upper(trim(p_coupon_code)) and branch_id=v_branch) then raise exception 'Coupon belongs to another branch';end if;
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
        branch_id, order_id, order_number, customer_id, customer_name, service_name, status, order_type,
        customer_request_id, created_by, notes, coupon_id, coupon_code, coupon_discount
    ) values (
        v_branch, v_order_id, v_order_number, v_customer_id, v_customer_name,
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


create or replace function private.product_fulfillment_quote(p_items jsonb,p_method text,p_zone uuid,p_coupon text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_branch uuid; v_settings public.business_branches%rowtype; v_zone public.business_delivery_zones%rowtype;
 v_sub numeric:=0; v_discount numeric:=0; v_fee numeric:=0; v_coupon jsonb; v_count integer;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_method not in ('pickup','delivery') or p_method is null then raise exception 'Choose pickup or delivery'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Invalid cart'; end if;
 if exists(select 1 from jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) where item_id is null or quantity is null or quantity not between 1 and 100) or
 exists(select item_id from jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) group by item_id having count(*)>1) then raise exception 'Invalid cart quantities'; end if;
 select count(*),coalesce(sum(ci.price*x.quantity),0) into v_count,v_sub from jsonb_to_recordset(p_items) x(item_id uuid,quantity integer)
 join public.business_catalog_items ci on ci.item_id=x.item_id and ci.item_type='product' and ci.is_active and ci.is_public
 and (ci.stock_quantity is null or ci.stock_quantity>=x.quantity);
 if v_count<>jsonb_array_length(p_items) then raise exception 'Product unavailable or insufficient stock'; end if;
 select ci.branch_id into v_branch from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id limit 1;
 if (select count(distinct ci.branch_id) from public.business_catalog_items ci join jsonb_to_recordset(p_items) x(item_id uuid,quantity integer) on ci.item_id=x.item_id)<>1 then raise exception 'A cart must belong to one branch';end if;
 select * into strict v_settings from public.business_branches where branch_id=v_branch for share;
 if not v_settings.is_active or v_settings.temporarily_closed then raise exception 'Branch closed';end if;
 if p_method='delivery' then
  if not v_settings.delivery_enabled then raise exception 'Delivery is disabled'; end if;
  select * into v_zone from public.business_delivery_zones where zone_id=p_zone and branch_id=v_branch and is_active;
  if not found then raise exception 'Address zone is outside available delivery areas'; end if;
  if v_sub<v_settings.minimum_subtotal then raise exception 'Delivery minimum subtotal not reached'; end if;
  v_fee:=v_zone.fee;
 end if;
 if coalesce(trim(p_coupon),'')<>'' then
  if not exists(select 1 from public.business_coupons where code=upper(trim(p_coupon)) and branch_id=v_branch) then raise exception 'Coupon belongs to another branch';end if;
  v_coupon:=public._calculate_customer_coupon(auth.uid(),p_coupon,p_items);
  if coalesce((v_coupon->>'is_valid')::boolean,false) is not true then raise exception 'Coupon is invalid'; end if;
  v_discount:=(v_coupon->>'discount_amount')::numeric;
 end if;
 return jsonb_build_object('subtotal',v_sub,'discount',v_discount,'delivery_fee',v_fee,'total',v_sub-v_discount+v_fee,'zone_name',v_zone.name);
end; $$;

create or replace function private.update_product_fulfillment(p_order uuid,p_expected text,p_status text,p_courier uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare f public.business_order_fulfillments%rowtype; v_role text:=private.active_staff_role(); v_manager boolean; v_number text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into strict f from public.business_order_fulfillments where order_id=p_order for update;
 v_manager:=coalesce(v_role in ('owner','manager'),false);
 if v_role is not null and not coalesce(private.can_access_branch(f.branch_id),false) then raise exception 'Branch access denied';end if;
 if not v_manager and not coalesce(v_role='employee' and f.courier_id=auth.uid(),false) and not(f.customer_id=auth.uid() and p_status='cancelled' and f.status in ('new','confirmed')) then raise exception 'Fulfillment access denied'; end if;
 if p_courier is distinct from f.courier_id then
  if not v_manager then raise exception 'Only management assigns a courier'; end if;
  if p_courier is not null and not exists(select 1 from public.staff_profiles where user_id=p_courier and is_active and exists(select 1 from public.staff_branch_access a where a.user_id=p_courier and a.branch_id=f.branch_id)) then raise exception 'Active courier account required'; end if;
 end if;
 if p_status not in ('new','confirmed','preparing','out_for_delivery','delivered','cancelled') or p_status is null then raise exception 'Invalid fulfillment status'; end if;
 if f.status<>p_expected then raise exception 'Order changed; refresh first'; end if;
 if p_status<>f.status then
  if not ((f.status='new' and p_status in ('confirmed','cancelled')) or
   (f.status='confirmed' and p_status in ('preparing','cancelled')) or
   (f.status='preparing' and (p_status='cancelled' or (f.fulfillment_method='delivery' and p_status='out_for_delivery') or (f.fulfillment_method='pickup' and p_status='delivered'))) or
   (f.status='out_for_delivery' and p_status in ('delivered','cancelled'))) then raise exception 'Invalid fulfillment transition'; end if;
  if not v_manager and f.customer_id<>auth.uid() and not ((f.status='confirmed' and p_status='preparing') or (f.status='preparing' and p_status='out_for_delivery') or (f.status in ('preparing','out_for_delivery') and p_status='delivered')) then raise exception 'Courier may only progress delivery'; end if;
 end if;
 if p_status='out_for_delivery' and p_courier is null then raise exception 'Assign a courier before dispatch'; end if;
 if f.status in ('delivered','cancelled') and p_courier is distinct from f.courier_id then raise exception 'Terminal order is immutable'; end if;
 update public.business_order_fulfillments set status=p_status,courier_id=p_courier,updated_at=now() where order_id=p_order;
 update public.business_orders set assigned_staff_ids=case when p_courier is distinct from f.courier_id then array_remove(assigned_staff_ids,f.courier_id)||case when p_courier is null then '{}'::uuid[] else array[p_courier] end else assigned_staff_ids end, status=case p_status when 'new' then 'received' when 'confirmed' then 'received' when 'preparing' then 'in_progress' when 'out_for_delivery' then 'completed' else p_status end,updated_at=now() where order_id=p_order returning order_number into v_number;
 if p_status<>f.status then
  insert into public.customer_order_notifications(customer_id,order_id,status) values(f.customer_id,p_order,p_status) on conflict(order_id,status) do nothing;
 end if;
 if p_status='delivered' then
  insert into public.business_invoices(invoice_id,order_id,service_name,total,discount,sale_type,payment_method,created_by)
  values('FULFILL-'||p_order::text,p_order,'طلب منتجات '||v_number,f.total,f.discount,'product','cash_on_receipt','fulfillment') on conflict(invoice_id) do nothing;
 end if;
 return jsonb_build_object('order_id',p_order,'status',p_status);
end; $$;

create function private.branch_owner_report(p_from date, p_to date, p_zone text,p_branch uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_start timestamptz; v_end timestamptz; v_sales numeric; v_refunds numeric;
 v_commission numeric; v_expenses numeric; v_count bigint; v_daily jsonb; v_payments jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then
   raise exception 'Active owner access required' using errcode='42501';
 end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to 367 days'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Unknown report time zone'; end if;
 v_start:=p_from::timestamp at time zone p_zone;
 v_end:=(p_to+1)::timestamp at time zone p_zone;
 select coalesce(sum(total) filter(where status='active'),0),coalesce(sum(total) filter(where status='refunded'),0),
   coalesce(sum(commission_total) filter(where status='active'),0),count(*) filter(where status='active')
 into v_sales,v_refunds,v_commission,v_count from public.business_invoices where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end;
 select coalesce(sum(amount),0) into v_expenses from public.business_expenses where (p_branch is null or branch_id=p_branch) and expense_date between p_from and p_to;
 select coalesce(jsonb_agg(to_jsonb(d) order by d.day),'[]') into v_daily from (
   select (issued_at at time zone p_zone)::date as day, sum(total) as sales,count(*) as invoices
   from public.business_invoices where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end and status='active' group by 1) d;
 select coalesce(jsonb_agg(to_jsonb(p)),'[]') into v_payments from (
   select coalesce(payment_method,'unspecified') as method,sum(total) as total from public.business_invoices
   where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end and status='active' group by 1) p;
 return jsonb_build_object('from',p_from,'to',p_to,'time_zone',p_zone,'sales',v_sales,'refunded_total',v_refunds,
   'commissions',v_commission,'expenses',v_expenses,'net_before_tax',v_sales-v_commission-v_expenses,
   'invoice_count',v_count,'daily',v_daily,'payments',v_payments);
end; $$;
revoke all on function private.branch_owner_report(date,date,text,uuid) from public,anon;
grant execute on function private.branch_owner_report(date,date,text,uuid) to authenticated;
create function public.get_branch_owner_report(p_from date,p_to date,p_branch uuid default null,p_zone text default 'Africa/Cairo')
returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.branch_owner_report(p_from,p_to,p_zone,p_branch); $$;
revoke all on function public.get_branch_owner_report(date,date,uuid,text) from public,anon;
grant execute on function public.get_branch_owner_report(date,date,uuid,text) to authenticated;
create function private.stamp_order_branch() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 select branch_id into new.branch_id from public.business_orders where order_id=new.order_id;return new;end; $$;
revoke all on function private.stamp_order_branch() from public;
create trigger stamp_fulfillment_branch before insert on public.business_order_fulfillments for each row execute function private.stamp_order_branch();
create trigger stamp_invoice_branch before insert on public.business_invoices for each row when(new.order_id is not null) execute function private.stamp_order_branch();
create function private.sync_default_delivery_settings() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 update public.business_branches set delivery_enabled=new.delivery_enabled,minimum_subtotal=new.minimum_subtotal where is_default;return new;end; $$;
revoke all on function private.sync_default_delivery_settings() from public;
create trigger sync_default_delivery_settings after update on public.business_contact_delivery_settings for each row execute function private.sync_default_delivery_settings();

create function private.copy_branch_prices(p_from uuid,p_to uuid) returns integer language plpgsql security definer set search_path=pg_catalog as $$
declare v_count integer;begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Owner required';end if;
 if p_from=p_to then raise exception 'Choose different branches';end if;
 insert into public.business_catalog_items(branch_id,catalog_key,item_type,name,description,category,vehicle_type,price,stock_quantity,is_active,is_public,duration_minutes,resource_key)
 select p_to,catalog_key,item_type,name,description,category,vehicle_type,price,case when item_type='product' then 0 end,is_active,is_public,duration_minutes,resource_key from public.business_catalog_items where branch_id=p_from
 on conflict(branch_id,catalog_key) do update set price=excluded.price,duration_minutes=excluded.duration_minutes,resource_key=excluded.resource_key,updated_at=now();
 get diagnostics v_count=row_count;return v_count;end; $$;
revoke all on function private.copy_branch_prices(uuid,uuid) from public,anon;
grant execute on function private.copy_branch_prices(uuid,uuid) to authenticated;
create function public.copy_branch_prices(p_from uuid,p_to uuid) returns integer language sql security invoker set search_path=pg_catalog as $$ select private.copy_branch_prices(p_from,p_to); $$;
revoke all on function public.copy_branch_prices(uuid,uuid) from public,anon;
grant execute on function public.copy_branch_prices(uuid,uuid) to authenticated;
create table public.business_stock_transfers (
 request_id uuid primary key,from_item uuid not null references public.business_catalog_items(item_id),to_item uuid not null references public.business_catalog_items(item_id),
 from_branch uuid not null references public.business_branches(branch_id),to_branch uuid not null references public.business_branches(branch_id),
 quantity integer not null check(quantity between 1 and 100000),reason text not null check(length(trim(reason)) between 5 and 500),actor_id uuid not null,created_at timestamptz not null default now()
);
alter table public.business_stock_transfers enable row level security;
grant select on public.business_stock_transfers to authenticated;grant all on public.business_stock_transfers to service_role;
create policy "Owner reads stock transfers" on public.business_stock_transfers for select to authenticated using((select private.active_staff_role())='owner');
create function private.transfer_branch_stock(p_request uuid,p_from uuid,p_to uuid,p_quantity integer,p_reason text)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare a public.business_catalog_items%rowtype;b public.business_catalog_items%rowtype;old public.business_stock_transfers%rowtype;
begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Owner required';end if;
 if p_request is null or p_from=p_to or p_quantity is null or p_quantity not between 1 and 100000 or length(trim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Invalid transfer';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));select * into old from public.business_stock_transfers where request_id=p_request;
 if found then if old.from_item<>p_from or old.to_item<>p_to or old.quantity<>p_quantity or old.reason<>p_reason then raise exception 'Transfer request already used';end if;return p_request;end if;
 perform 1 from public.business_catalog_items where item_id in (p_from,p_to) order by item_id for update;
 select * into strict a from public.business_catalog_items where item_id=p_from;select * into strict b from public.business_catalog_items where item_id=p_to;
 if a.branch_id=b.branch_id or a.catalog_key<>b.catalog_key or a.item_type<>'product' or b.item_type<>'product' or a.stock_quantity is null or b.stock_quantity is null then raise exception 'Choose matching products from different branches with tracked stock';end if;
 if a.stock_quantity<p_quantity then raise exception 'Insufficient stock';end if;
 update public.business_catalog_items set stock_quantity=stock_quantity-p_quantity where item_id=p_from;
 update public.business_catalog_items set stock_quantity=stock_quantity+p_quantity where item_id=p_to;
 insert into public.business_stock_transfers(request_id,from_item,to_item,from_branch,to_branch,quantity,reason,actor_id) values(p_request,p_from,p_to,a.branch_id,b.branch_id,p_quantity,p_reason,auth.uid());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data) values(auth.uid()::text,auth.uid(),'stock_transfer','business_stock_transfers',p_request::text,a.branch_id,p_reason,jsonb_build_object('to_branch',b.branch_id,'quantity',p_quantity));return p_request;
end; $$;
revoke all on function private.transfer_branch_stock(uuid,uuid,uuid,integer,text) from public,anon;
grant execute on function private.transfer_branch_stock(uuid,uuid,uuid,integer,text) to authenticated;
create function public.transfer_branch_stock(p_request uuid,p_from uuid,p_to uuid,p_quantity integer,p_reason text) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.transfer_branch_stock(p_request,p_from,p_to,p_quantity,p_reason); $$;
revoke all on function public.transfer_branch_stock(uuid,uuid,uuid,integer,text) from public,anon;
grant execute on function public.transfer_branch_stock(uuid,uuid,uuid,integer,text) to authenticated;
notify pgrst,'reload schema';
create function private.branch_config_lock() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 perform 1 from public.business_branches where branch_id=coalesce(new.branch_id,old.branch_id) for update;return coalesce(new,old);end; $$;
revoke all on function private.branch_config_lock() from public;
create trigger lock_branch_hours before insert or update or delete on public.business_branch_hours for each row execute function private.branch_config_lock();
create trigger lock_branch_exception before insert or update or delete on public.business_branch_exceptions for each row execute function private.branch_config_lock();
create trigger lock_branch_resource before insert or update or delete on public.business_branch_resources for each row execute function private.branch_config_lock();
create function private.available_booking_slots(p_branch uuid,p_service uuid,p_date date)
returns table(slot_time time) language plpgsql security definer set search_path=pg_catalog as $$
declare b public.business_branches%rowtype;c public.business_catalog_items%rowtype;h public.business_branch_hours%rowtype;e public.business_branch_exceptions%rowtype;
 v_open time;v_close time;v_capacity integer;v_start timestamp;v_end timestamp;v_count integer;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select * into b from public.business_branches where branch_id=p_branch and is_active and not temporarily_closed;if not found then return;end if;
 select * into c from public.business_catalog_items where item_id=p_service and branch_id=p_branch and item_type='service' and is_active and is_public;if not found then return;end if;
 select * into h from public.business_branch_hours where branch_id=p_branch and weekday=extract(dow from p_date)::integer;if not found then return;end if;
 v_open:=h.opens_at;v_close:=h.closes_at;
 select * into e from public.business_branch_exceptions where branch_id=p_branch and exception_date=p_date;
 if found then if e.is_closed then return;end if;v_open:=e.opens_at;v_close:=e.closes_at;elsif not h.is_open then return;end if;
 select capacity into v_capacity from public.business_branch_resources where branch_id=p_branch and resource_key=c.resource_key;
 if v_capacity is null then return;end if;
 for v_start in select generate_series(p_date+v_open,p_date+v_close-make_interval(mins=>c.duration_minutes),interval '15 minutes') loop
  if v_start at time zone b.time_zone<=now() then continue;end if;v_end:=v_start+make_interval(mins=>c.duration_minutes);
  select coalesce(max(occupied),0) into v_count from (
   select (select count(*) from public.bookings q where q.branch_id=p_branch and q.booking_date=p_date and q.resource_key=c.resource_key and q.status not in ('cancelled','completed') and q.booking_date+q.booking_time<=point and q.booking_date+q.booking_time+make_interval(mins=>q.duration_minutes)>point) occupied
   from(select v_start point union select q.booking_date+q.booking_time from public.bookings q where q.branch_id=p_branch and q.booking_date=p_date and q.resource_key=c.resource_key and q.status not in ('cancelled','completed') and q.booking_date+q.booking_time>v_start and q.booking_date+q.booking_time<v_end) points
  ) counts;
  if v_count<v_capacity then slot_time:=v_start::time;return next;end if;
 end loop;
end; $$;
revoke all on function private.available_booking_slots(uuid,uuid,date) from public,anon;
grant execute on function private.available_booking_slots(uuid,uuid,date) to authenticated;
create function public.available_booking_slots(p_branch uuid,p_service uuid,p_date date) returns table(slot_time time) language sql security invoker set search_path=pg_catalog as $$ select * from private.available_booking_slots(p_branch,p_service,p_date); $$;
revoke all on function public.available_booking_slots(uuid,uuid,date) from public,anon;
grant execute on function public.available_booking_slots(uuid,uuid,date) to authenticated;
notify pgrst,'reload schema';
-- A price-edit permission does not authorize moving catalog identity or inventory.
revoke update on public.business_catalog_items from authenticated;
grant update(name,description,category,vehicle_type,price,commission_type,commission_value,is_active,is_public,updated_at,duration_minutes,resource_key) on public.business_catalog_items to authenticated;
create function private.guard_catalog_identity() returns trigger language plpgsql set search_path=pg_catalog as $$ begin
 if new.branch_id is distinct from old.branch_id or new.catalog_key is distinct from old.catalog_key then raise exception 'Catalog identity cannot be moved; use a stock transfer';end if;
 if (new.commission_type is distinct from old.commission_type or new.commission_value is distinct from old.commission_value) and current_user not in ('postgres','service_role','supabase_admin') and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can change commissions';end if;
 return new;end; $$;
revoke all on function private.guard_catalog_identity() from public;
create trigger guard_catalog_identity before update on public.business_catalog_items for each row execute function private.guard_catalog_identity();
notify pgrst,'reload schema';
-- Delegating price edits never delegates catalog creation or inventory creation.
alter policy "Branch catalog inserts" on public.business_catalog_items with check((select private.active_staff_role())='owner');
create function private.guard_capacity_reason() returns trigger language plpgsql set search_path=pg_catalog as $$ begin
 if new.capacity_override_reason is distinct from old.capacity_override_reason and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can change a capacity override reason';end if;return new;end; $$;
revoke all on function private.guard_capacity_reason() from public;
create trigger guard_capacity_reason before update of capacity_override_reason on public.bookings for each row execute function private.guard_capacity_reason();
create function private.audit_booking_change() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare before_value jsonb;after_value jsonb;begin
 if tg_op='UPDATE' then before_value:=jsonb_build_object('status',old.status,'date',old.booking_date,'time',old.booking_time,'quoted_price',old.quoted_price,'assigned_staff_ids',old.assigned_staff_ids,'capacity_override_reason',old.capacity_override_reason);end if;
 after_value:=jsonb_build_object('status',new.status,'date',new.booking_date,'time',new.booking_time,'quoted_price',new.quoted_price,'assigned_staff_ids',new.assigned_staff_ids,'capacity_override_reason',new.capacity_override_reason);
 if tg_op='INSERT' or before_value is distinct from after_value then
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data,reason) values(coalesce(auth.uid()::text,'local_server'),auth.uid(),tg_op,'bookings',new.id::text,new.branch_id,before_value,after_value,new.capacity_override_reason);end if;return new;end; $$;
revoke all on function private.audit_booking_change() from public;
create trigger audit_booking_change after insert or update on public.bookings for each row execute function private.audit_booking_change();
notify pgrst,'reload schema';
