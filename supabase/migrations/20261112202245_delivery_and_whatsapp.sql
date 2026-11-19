-- Local review only. No historical order is rewritten.
create table public.business_contact_delivery_settings (
 id boolean primary key default true check(id),
 delivery_enabled boolean not null default false,
 minimum_subtotal numeric(12,2) not null default 0 check(minimum_subtotal>=0),
 whatsapp_enabled boolean not null default false,
 whatsapp_phone text not null default '',
 whatsapp_message text not null default 'مرحبًا، أحتاج مساعدة من Sabiha Hub.' check(length(whatsapp_message) between 1 and 500),
 check(whatsapp_phone='' or whatsapp_phone ~ '^\+[1-9][0-9]{7,14}$'),
 check(not whatsapp_enabled or whatsapp_phone<>''),
 updated_at timestamptz not null default now()
);
insert into public.business_contact_delivery_settings(id) values(true);
create table public.business_delivery_zones (
 zone_id uuid primary key default gen_random_uuid(),
 name text not null check(length(trim(name)) between 2 and 120),
 fee numeric(12,2) not null check(fee>=0),
 is_active boolean not null default true
);
create table public.business_order_fulfillments (
 order_id uuid primary key references public.business_orders(order_id),
 customer_id uuid not null references public.customers(id),
 fulfillment_method text not null check(fulfillment_method in ('delivery','pickup')),
 zone_id uuid references public.business_delivery_zones(zone_id), zone_name text,
 address text, phone text, delivery_note text check(length(delivery_note)<=1000),
 delivery_fee numeric(12,2) not null check(delivery_fee>=0),
 subtotal numeric(12,2) not null, discount numeric(12,2) not null,
 total numeric(12,2) not null check(total=subtotal-discount+delivery_fee),
 status text not null default 'new' check(status in ('new','confirmed','preparing','out_for_delivery','delivered','cancelled')),
 courier_id uuid references public.staff_profiles(user_id),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(fulfillment_method<>'delivery' or (zone_id is not null and length(trim(address)) between 10 and 700 and phone ~ '^\+[1-9][0-9]{7,14}$'))
);
create index fulfillment_customer_idx on public.business_order_fulfillments(customer_id,created_at desc);
create index fulfillment_courier_idx on public.business_order_fulfillments(courier_id) where courier_id is not null;
create table public.customer_order_notifications (
 notification_id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.customers(id),
 order_id uuid not null references public.business_orders(order_id),
 status text not null, created_at timestamptz not null default now(),
 push_state text not null default 'pending' check(push_state in ('pending','sending','accepted','failed')),
 push_attempted_at timestamptz, unique(order_id,status)
);
create index order_notifications_customer_idx on public.customer_order_notifications(customer_id,created_at desc);
create index order_notifications_pending_idx on public.customer_order_notifications(created_at) where push_state='pending';
alter table public.business_contact_delivery_settings enable row level security;
alter table public.business_delivery_zones enable row level security;
alter table public.business_order_fulfillments enable row level security;
alter table public.customer_order_notifications enable row level security;
revoke all on public.business_contact_delivery_settings,public.business_delivery_zones,public.business_order_fulfillments,public.customer_order_notifications from anon,authenticated;
grant select on public.business_contact_delivery_settings to anon,authenticated;
grant update on public.business_contact_delivery_settings to authenticated;
grant select,insert,update on public.business_delivery_zones to authenticated;
grant select on public.business_order_fulfillments,public.customer_order_notifications to authenticated;
grant all on public.business_contact_delivery_settings,public.business_delivery_zones,public.business_order_fulfillments,public.customer_order_notifications to service_role;
create policy "Public contact and delivery settings" on public.business_contact_delivery_settings for select to anon,authenticated using(true);
create policy "Owner edits contact delivery settings" on public.business_contact_delivery_settings for update to authenticated using((select private.active_staff_role())='owner') with check((select private.active_staff_role())='owner');
create policy "Available delivery zones" on public.business_delivery_zones for select to authenticated using(is_active or (select private.active_staff_role())='owner');
create policy "Owner creates delivery zones" on public.business_delivery_zones for insert to authenticated with check((select private.active_staff_role())='owner');
create policy "Owner updates delivery zones" on public.business_delivery_zones for update to authenticated using((select private.active_staff_role())='owner') with check((select private.active_staff_role())='owner');
create policy "Authorized fulfillment read" on public.business_order_fulfillments for select to authenticated using(
 customer_id=(select auth.uid()) or (select private.active_staff_role()) in ('owner','manager') or
 ((select private.active_staff_role())='employee' and courier_id=(select auth.uid())));
create policy "Customer reads order notifications" on public.customer_order_notifications for select to authenticated using(customer_id=(select auth.uid()));

create function private.product_fulfillment_quote(p_items jsonb,p_method text,p_zone uuid,p_coupon text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_settings public.business_contact_delivery_settings%rowtype; v_zone public.business_delivery_zones%rowtype;
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
 select * into strict v_settings from public.business_contact_delivery_settings where id;
 if p_method='delivery' then
  if not v_settings.delivery_enabled then raise exception 'Delivery is disabled'; end if;
  select * into v_zone from public.business_delivery_zones where zone_id=p_zone and is_active;
  if not found then raise exception 'Address zone is outside available delivery areas'; end if;
  if v_sub<v_settings.minimum_subtotal then raise exception 'Delivery minimum subtotal not reached'; end if;
  v_fee:=v_zone.fee;
 end if;
 if coalesce(trim(p_coupon),'')<>'' then
  v_coupon:=public._calculate_customer_coupon(auth.uid(),p_coupon,p_items);
  if coalesce((v_coupon->>'is_valid')::boolean,false) is not true then raise exception 'Coupon is invalid'; end if;
  v_discount:=(v_coupon->>'discount_amount')::numeric;
 end if;
 return jsonb_build_object('subtotal',v_sub,'discount',v_discount,'delivery_fee',v_fee,'total',v_sub-v_discount+v_fee,'zone_name',v_zone.name);
end; $$;
revoke all on function private.product_fulfillment_quote(jsonb,text,uuid,text) from public,anon;
grant execute on function private.product_fulfillment_quote(jsonb,text,uuid,text) to authenticated;
create function public.quote_product_fulfillment(p_items jsonb,p_method text,p_zone uuid default null,p_coupon text default null)
returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.product_fulfillment_quote(p_items,p_method,p_zone,p_coupon); $$;
revoke all on function public.quote_product_fulfillment(jsonb,text,uuid,text) from public,anon;
grant execute on function public.quote_product_fulfillment(jsonb,text,uuid,text) to authenticated;

create function private.place_product_fulfillment(p_items jsonb,p_request_id uuid,p_method text,p_zone uuid,p_address text,p_phone text,p_note text,p_coupon text,p_expected_total numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_existing public.business_order_fulfillments%rowtype; v_order record; v_quote jsonb; v_request jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer authentication required'; end if;
 if p_request_id is null then raise exception 'Request id required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 select f.* into v_existing from public.business_order_fulfillments f join public.business_orders o using(order_id)
 where o.customer_id=auth.uid() and o.customer_request_id=p_request_id;
 if found then
  if v_existing.fulfillment_method is distinct from p_method or v_existing.zone_id is distinct from (case when p_method='delivery' then p_zone end)
   or coalesce(v_existing.address,'')<>coalesce(trim(p_address),'') or coalesce(v_existing.phone,'')<>coalesce(trim(p_phone),'')
   or coalesce(v_existing.delivery_note,'')<>coalesce(trim(p_note),'') then raise exception 'Request id already used for different delivery details'; end if;
  -- Reuse the established cart/coupon retry validator, without reserving stock again.
  select * into v_order from public.place_customer_product_order(p_items,p_request_id,p_note,p_coupon);
  return jsonb_build_object('order_id',v_existing.order_id,'order_number',v_order.order_number,'total',v_existing.total);
 end if;
 if exists(select 1 from public.business_orders where customer_id=auth.uid() and customer_request_id=p_request_id) then raise exception 'Request id belongs to a legacy order'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Delivery note too long'; end if;
 if p_method='delivery' and (length(trim(coalesce(p_address,''))) not between 10 and 700 or coalesce(p_phone,'') !~ '^\+[1-9][0-9]{7,14}$') then raise exception 'Detailed address and international phone required'; end if;
 -- Lock configuration and cart rows until checkout completes, so the preview and charge use one price snapshot.
 perform 1 from public.business_contact_delivery_settings where id for share;
 perform 1 from public.business_delivery_zones where zone_id=p_zone for share;
 perform 1 from public.business_catalog_items where item_id in (select item_id from jsonb_to_recordset(p_items) x(item_id uuid,quantity integer)) order by item_id for update;
 v_quote:=private.product_fulfillment_quote(p_items,p_method,p_zone,p_coupon);
 if p_expected_total is null or p_expected_total<>(v_quote->>'total')::numeric then raise exception 'Price changed; review the server quote again'; end if;
 select * into v_order from public.place_customer_product_order(p_items,p_request_id,p_note,p_coupon);
 insert into public.business_order_fulfillments(order_id,customer_id,fulfillment_method,zone_id,zone_name,address,phone,delivery_note,delivery_fee,subtotal,discount,total)
 values(v_order.order_id,auth.uid(),p_method,case when p_method='delivery' then p_zone end,v_quote->>'zone_name',nullif(trim(p_address),''),nullif(trim(p_phone),''),nullif(trim(p_note),''),
 (v_quote->>'delivery_fee')::numeric,(v_quote->>'subtotal')::numeric,(v_quote->>'discount')::numeric,(v_quote->>'total')::numeric);
 insert into public.customer_order_notifications(customer_id,order_id,status) values(auth.uid(),v_order.order_id,'new');
 return jsonb_build_object('order_id',v_order.order_id,'order_number',v_order.order_number,'total',v_quote->'total');
end; $$;
revoke all on function private.place_product_fulfillment(jsonb,uuid,text,uuid,text,text,text,text,numeric) from public,anon;
grant execute on function private.place_product_fulfillment(jsonb,uuid,text,uuid,text,text,text,text,numeric) to authenticated;
create function public.place_product_fulfillment(p_items jsonb,p_request_id uuid,p_method text,p_zone uuid,p_address text,p_phone text,p_note text,p_coupon text,p_expected_total numeric)
returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.place_product_fulfillment(p_items,p_request_id,p_method,p_zone,p_address,p_phone,p_note,p_coupon,p_expected_total); $$;
revoke all on function public.place_product_fulfillment(jsonb,uuid,text,uuid,text,text,text,text,numeric) from public,anon;
grant execute on function public.place_product_fulfillment(jsonb,uuid,text,uuid,text,text,text,text,numeric) to authenticated;

create or replace function public.enforce_business_status_transition()
returns trigger language plpgsql set search_path = pg_catalog as $$
declare v_employee boolean;
begin
    if tg_table_name='business_orders' then
     if exists(select 1 from public.business_order_fulfillments f where f.order_id=new.order_id) then
      if new.status is distinct from (select case f.status when 'new' then 'received' when 'confirmed' then 'received' when 'preparing' then 'in_progress' when 'out_for_delivery' then 'completed' else f.status end from public.business_order_fulfillments f where f.order_id=new.order_id) then
        raise exception 'Use the fulfillment workflow to update this order';
      end if;
      return new;
     end if;
    end if;
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
create function private.update_product_fulfillment(p_order uuid,p_expected text,p_status text,p_courier uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare f public.business_order_fulfillments%rowtype; v_role text:=private.active_staff_role(); v_manager boolean; v_number text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into strict f from public.business_order_fulfillments where order_id=p_order for update;
 v_manager:=coalesce(v_role in ('owner','manager'),false);
 if not v_manager and not coalesce(v_role='employee' and f.courier_id=auth.uid(),false) and not(f.customer_id=auth.uid() and p_status='cancelled' and f.status in ('new','confirmed')) then raise exception 'Fulfillment access denied'; end if;
 if p_courier is distinct from f.courier_id then
  if not v_manager then raise exception 'Only management assigns a courier'; end if;
  if p_courier is not null and not exists(select 1 from public.staff_profiles where user_id=p_courier and is_active) then raise exception 'Active courier account required'; end if;
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
revoke all on function private.update_product_fulfillment(uuid,text,text,uuid) from public,anon;
grant execute on function private.update_product_fulfillment(uuid,text,text,uuid) to authenticated;
create function public.update_product_fulfillment(p_order uuid,p_expected text,p_status text,p_courier uuid default null)
returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.update_product_fulfillment(p_order,p_expected,p_status,p_courier); $$;
revoke all on function public.update_product_fulfillment(uuid,text,text,uuid) from public,anon;
grant execute on function public.update_product_fulfillment(uuid,text,text,uuid) to authenticated;
-- Transactional order push is independent from marketing consent.
alter table public.customer_marketing_preferences add column order_push_enabled boolean not null default false;
create function public.claim_order_notifications(p_limit integer default 100)
returns setof public.customer_order_notifications language sql security definer set search_path=pg_catalog as $$
 update public.customer_order_notifications n set push_state='sending',push_attempted_at=now()
 where n.notification_id in (
  select q.notification_id from public.customer_order_notifications q
  join public.customer_marketing_preferences p on p.customer_id=q.customer_id and p.order_push_enabled
  where q.push_state='pending' and exists(select 1 from public.push_device_tokens d where d.user_id=q.customer_id and d.audience='customer' and d.is_active)
  order by q.created_at for update of q skip locked limit greatest(1,least(p_limit,100))
 ) returning n.*;
$$;
revoke all on function public.claim_order_notifications(integer) from public,anon,authenticated;
grant execute on function public.claim_order_notifications(integer) to service_role;
notify pgrst,'reload schema';
