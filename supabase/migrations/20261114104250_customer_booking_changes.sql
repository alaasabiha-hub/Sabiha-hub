begin;
create table private.customer_booking_change_requests(request_id uuid primary key,actor_id uuid not null,booking_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now());
alter table private.customer_booking_change_requests enable row level security;
revoke all on private.customer_booking_change_requests from public,anon,authenticated,service_role;
create function private.change_customer_booking(p_request uuid,p_booking uuid,p_action text,p_date date default null,p_time time default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare b public.bookings%rowtype;o public.business_orders%rowtype;i public.business_invoices%rowtype;r private.customer_booking_change_requests%rowtype;payload jsonb;before_value jsonb;result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 select * into b from public.bookings where id=p_booking and customer_id=auth.uid() for update;
 if not found then raise exception 'Booking access denied' using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in ('cancel','reschedule') or (p_action='cancel' and (p_date is not null or p_time is not null)) or (p_action='reschedule' and (p_date is null or p_time is null)) then raise exception 'Invalid booking change' using errcode='22023';end if;
 payload:=jsonb_build_object('booking',p_booking,'action',p_action,'date',p_date,'time',p_time);
 perform pg_advisory_xact_lock(hashtextextended('customer-booking-change:'||p_request::text,0));
 select * into r from private.customer_booking_change_requests where request_id=p_request;
 if found then
  if r.actor_id<>auth.uid() or r.booking_id<>p_booking then raise exception 'Request access denied' using errcode='42501';end if;
  if r.payload<>payload then raise exception 'Request payload mismatch' using errcode='22023';end if;
  return r.result;
 end if;
 if b.status<>'pending' or coalesce(cardinality(b.assigned_staff_ids),0)>0 or (b.booking_date+b.booking_time) at time zone 'Africa/Cairo'<=clock_timestamp() then raise exception 'Only future pending unassigned bookings may be changed; contact management';end if;
 select * into o from public.business_orders where booking_id=b.id and customer_id=auth.uid() and order_type='service' for update;
 if not found or o.status<>'received' or coalesce(cardinality(o.assigned_staff_ids),0)>0 then raise exception 'Order requires management';end if;
 if (select count(*) from public.business_orders where booking_id=b.id)<>1 then raise exception 'Ambiguous booking order';end if;
 select * into i from public.business_invoices where order_id=o.order_id for update;
 if not found or (select count(*) from public.business_invoices where order_id=o.order_id)<>1 or i.status<>'active' then raise exception 'Invoice requires management';end if;
 if exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale') or exists(select 1 from private.paymob_intents where invoice_id=i.invoice_id and status in ('creating','pending','uncertain','sandbox_succeeded','refund_reported')) then raise exception 'Payment recorded or unresolved; contact management';end if;
 before_value:=jsonb_build_object('booking',to_jsonb(b),'order',to_jsonb(o),'invoice',to_jsonb(i));
 if p_action='cancel' then
  update public.bookings set status='cancelled' where id=b.id;
  update public.business_orders set status='cancelled',updated_at=now() where order_id=o.order_id;
  update public.business_invoices set status='void' where invoice_id=i.invoice_id;
 else
  if (p_date+p_time) at time zone 'Africa/Cairo'<=clock_timestamp() or not exists(select 1 from private.available_booking_slots(b.branch_id,b.catalog_item_id,p_date) where slot_time=p_time) then raise exception 'Choose an available future appointment';end if;
  perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||b.vehicle_id::text,0));
  update public.bookings set booking_date=p_date,booking_time=p_time where id=b.id;
 end if;
 select * into b from public.bookings where id=b.id;select * into o from public.business_orders where order_id=o.order_id;select * into i from public.business_invoices where invoice_id=i.invoice_id;
 result:=jsonb_build_object('booking_id',b.id,'status',b.status,'booking_date',b.booking_date,'booking_time',b.booking_time,'invoice_id',i.invoice_id);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data) values(auth.uid()::text,auth.uid(),'customer_booking_'||p_action,'bookings',b.id::text,b.branch_id,before_value,jsonb_build_object('booking',to_jsonb(b),'order',to_jsonb(o),'invoice',to_jsonb(i),'request_id',p_request));
 insert into private.customer_booking_change_requests(request_id,actor_id,booking_id,payload,result) values(p_request,auth.uid(),b.id,payload,result);return result;
end;$$;
create function public.change_customer_booking(p_request uuid,p_booking uuid,p_action text,p_date date default null,p_time time default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.change_customer_booking(p_request,p_booking,p_action,p_date,p_time);$$;
revoke all on function private.change_customer_booking(uuid,uuid,text,date,time),public.change_customer_booking(uuid,uuid,text,date,time) from public,anon;
grant execute on function private.change_customer_booking(uuid,uuid,text,date,time),public.change_customer_booking(uuid,uuid,text,date,time) to authenticated;
notify pgrst,'reload schema';
commit;
