-- Atomic, idempotent checkout using existing bookings/orders/invoices tables.
-- No backfill, price seed, gateway call or historical record rewrite.
begin;

create or replace function private.place_customer_service_booking(
  p_request uuid, p_service uuid, p_branch uuid, p_vehicle uuid,
  p_date date, p_time time, p_expected_price numeric, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor uuid := auth.uid();
  service public.business_catalog_items%rowtype;
  car public.vehicles%rowtype;
  customer public.customers%rowtype;
  visit public.bookings%rowtype;
  work public.business_orders%rowtype;
  receipt public.business_invoices%rowtype;
  note text := nullif(trim(p_notes),'');
  bid uuid := gen_random_uuid();
  oid uuid := gen_random_uuid();
  iid text;
begin
  if actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_request is null or p_service is null or p_branch is null or p_vehicle is null
    or p_date is null or p_time is null or p_expected_price is null
    or length(coalesce(note,'')) > 2000 then
    raise exception 'Complete booking details required' using errcode='22023';
  end if;
  -- Same request may be retried after a lost HTTP response. A different payload
  -- must not silently reuse it, and a retry must retain its original price.
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':service-booking:' || p_request::text,0));
  select * into work from public.business_orders
    where customer_id=actor and customer_request_id=p_request;
  if found then
    select * into visit from public.bookings where id=work.booking_id and customer_id=actor;
    if visit.id is null or work.order_type<>'service'
      or visit.catalog_item_id is distinct from p_service
      or visit.branch_id is distinct from p_branch or visit.vehicle_id is distinct from p_vehicle
      or visit.booking_date is distinct from p_date or visit.booking_time is distinct from p_time
      or visit.quoted_price is distinct from p_expected_price or visit.notes is distinct from note then
      raise exception 'Booking request payload mismatch' using errcode='22023';
    end if;
    select * into receipt from public.business_invoices where invoice_id='BOOKING-'||visit.id::text and order_id=work.order_id;
    if not found then raise exception 'Booking invoice unavailable; contact support'; end if;
    return jsonb_build_object('booking_id',visit.id,'order_id',work.order_id,
      'invoice_id',receipt.invoice_id,'quoted_price',visit.quoted_price,'branch_id',visit.branch_id);
  end if;

  select * into customer from public.customers where id=actor;
  if not found then raise exception 'Customer profile required' using errcode='42501'; end if;
  select * into car from public.vehicles where id=p_vehicle and customer_id=actor for share;
  if not found then raise exception 'Vehicle ownership required' using errcode='42501'; end if;
  select * into service from public.business_catalog_items
    where item_id=p_service and branch_id=p_branch and item_type='service'
      and is_active and is_public
      and name !~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'
    for share;
  if not found then raise exception 'Published branch service required' using errcode='22023'; end if;
  if service.price is distinct from p_expected_price then
    raise exception 'Service price changed; refresh before booking' using errcode='40001';
  end if;
  -- Serialize the same vehicle even across different resource/branch locks.
  perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||p_vehicle::text,0));
  -- Existing triggers retain hours, closure, capacity, ownership and server
  -- price/duration snapshots. Failure rolls the entire checkout back.
  insert into public.bookings(id,customer_id,branch_id,vehicle_id,catalog_item_id,
    service_name,booking_date,booking_time,notes)
    values(bid,actor,p_branch,p_vehicle,p_service,service.name,p_date,p_time,note)
    returning * into visit;
  iid := 'BOOKING-'||bid::text;
  insert into public.business_orders(order_id,order_number,customer_id,customer_name,
    customer_phone,booking_id,branch_id,plate_number,vehicle_type,service_name,
    order_type,customer_request_id,created_by,notes)
    values(oid,iid,actor,customer.full_name,customer.phone,bid,p_branch,car.plate_number,
      visit.vehicle_type,visit.service_name,'service',p_request,'customer_booking',note);
  insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)
    values(oid,p_service,visit.service_name,1,visit.quoted_price,visit.quoted_price);
  insert into public.business_invoices(invoice_id,order_id,branch_id,plate_number,
    service_name,vehicle_type,total,payment_method,created_by)
    values(iid,oid,p_branch,car.plate_number,visit.service_name,visit.vehicle_type,
      visit.quoted_price,'cash_on_receipt','customer_booking');
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)
    values(actor::text,actor,'customer_service_booking','bookings',bid::text,p_branch,
      jsonb_build_object('order_id',oid,'invoice_id',iid,'quoted_price',visit.quoted_price));
  return jsonb_build_object('booking_id',bid,'order_id',oid,'invoice_id',iid,
    'quoted_price',visit.quoted_price,'branch_id',p_branch);
end;
$$;

create or replace function public.place_customer_service_booking(
  p_request uuid, p_service uuid, p_branch uuid, p_vehicle uuid,
  p_date date, p_time time, p_expected_price numeric, p_notes text default null
) returns jsonb language sql security invoker set search_path = pg_catalog as $$
  select private.place_customer_service_booking(p_request,p_service,p_branch,p_vehicle,
    p_date,p_time,p_expected_price,p_notes);
$$;

revoke all on function private.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text),
  public.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text)
  from public,anon;
grant execute on function private.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text),
  public.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text)
  to authenticated;

-- Customer clients must not bypass atomic invoice creation with a raw insert.
-- Staff updates/reads and existing server-side legacy writers stay unchanged.
revoke insert on public.bookings from authenticated;
revoke insert(customer_id,service_name,vehicle_type,vehicle_id,booking_date,
  booking_time,notes,catalog_item_id,branch_id) on public.bookings from authenticated;

notify pgrst,'reload schema';
commit;
