begin;

-- Operational events are independent of marketing consent. They are always
-- stored in the customer's in-app inbox; the separate push outbox is populated
-- only when the customer opted into order/service Push.
create table private.customer_operational_notifications (
  notification_id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  branch_id uuid not null references public.business_branches(branch_id),
  event_type text not null check (event_type in (
    'booking_received','booking_confirmed','booking_rescheduled',
    'booking_cancelled','booking_reminder','service_started',
    'service_quality_check','vehicle_ready','vehicle_delivered',
    'service_cancelled','loyalty_points_added','loyalty_visit_earned'
  )),
  source_kind text not null check (source_kind in ('booking','order','loyalty')),
  source_id uuid not null,
  event_key text not null unique check (length(event_key) between 1 and 240),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload)='object' and pg_column_size(payload)<=2048),
  available_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  read_at timestamptz,
  cancelled_at timestamptz
);
create index customer_operational_inbox_owner_idx
  on private.customer_operational_notifications(customer_id,available_at desc,created_at desc)
  where cancelled_at is null;
create index customer_operational_due_idx
  on private.customer_operational_notifications(available_at,created_at)
  where read_at is null and cancelled_at is null;
alter table private.customer_operational_notifications enable row level security;
revoke all on private.customer_operational_notifications from public,anon,authenticated,service_role;

create table private.customer_operational_push_outbox (
  notification_id uuid primary key references private.customer_operational_notifications(notification_id),
  customer_id uuid not null references public.customers(id),
  state text not null default 'queued'
    check (state in ('queued','sending','accepted','failed','suppressed','cancelled')),
  attempt_count integer not null default 0 check (attempt_count>=0),
  next_attempt_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  provider_message_id text,
  error_code text
);
create index customer_operational_push_due_idx
  on private.customer_operational_push_outbox(next_attempt_at,created_at)
  where state in ('queued','failed');
alter table private.customer_operational_push_outbox enable row level security;
revoke all on private.customer_operational_push_outbox from public,anon,authenticated,service_role;

create function private.enqueue_customer_operational_notification(
  p_customer uuid,p_branch uuid,p_event text,p_source_kind text,p_source uuid,
  p_event_key text,p_available_at timestamptz,p_payload jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare id uuid;
begin
  if p_customer is null or p_branch is null or p_source is null
     or p_event_key is null or length(p_event_key) not between 1 and 240
     or jsonb_typeof(coalesce(p_payload,'{}'::jsonb))<>'object'
     or pg_column_size(coalesce(p_payload,'{}'::jsonb))>2048 then
    raise exception 'Valid customer notification source required' using errcode='22023';
  end if;
  if not exists(select 1 from public.customers where id=p_customer)
     or not exists(select 1 from public.business_branches where branch_id=p_branch) then
    return null;
  end if;
  insert into private.customer_operational_notifications(
    customer_id,branch_id,event_type,source_kind,source_id,event_key,payload,available_at
  ) values(p_customer,p_branch,p_event,p_source_kind,p_source,p_event_key,
    coalesce(p_payload,'{}'::jsonb),coalesce(p_available_at,clock_timestamp()))
  on conflict(event_key) do nothing returning notification_id into id;
  if id is null then
    select notification_id into id from private.customer_operational_notifications where event_key=p_event_key;
    return id;
  end if;
  if exists(select 1 from public.customer_marketing_preferences
      where customer_id=p_customer and order_push_enabled) then
    insert into private.customer_operational_push_outbox(notification_id,customer_id,next_attempt_at)
    values(id,p_customer,coalesce(p_available_at,clock_timestamp()))
    on conflict(notification_id) do nothing;
  end if;
  return id;
end$$;
revoke all on function private.enqueue_customer_operational_notification(uuid,uuid,text,text,uuid,text,timestamptz,jsonb)
  from public,anon,authenticated,service_role;

create function private.schedule_customer_booking_reminder(p_booking public.bookings)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare appointment timestamptz;deliver_at timestamptz;
begin
  if p_booking.customer_id is null or p_booking.status not in ('pending','confirmed') then return; end if;
  appointment:=(p_booking.booking_date+p_booking.booking_time) at time zone 'Africa/Cairo';
  if appointment<=clock_timestamp()+interval '2 hours' then return; end if;
  deliver_at:=greatest(clock_timestamp(),appointment-interval '24 hours');
  perform private.enqueue_customer_operational_notification(
    p_booking.customer_id,p_booking.branch_id,'booking_reminder','booking',p_booking.id,
    'booking:'||p_booking.id::text||':reminder:'||p_booking.booking_date::text||':'||p_booking.booking_time::text,
    deliver_at,jsonb_build_object('booking_date',p_booking.booking_date,'booking_time',p_booking.booking_time)
  );
end$$;
revoke all on function private.schedule_customer_booking_reminder(public.bookings)
  from public,anon,authenticated,service_role;

create function private.customer_booking_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare event_name text;key text;
begin
  if new.customer_id is null then return new; end if;
  if tg_op='INSERT' then
    event_name:=case when new.status='confirmed' then 'booking_confirmed' else 'booking_received' end;
    key:='booking:'||new.id::text||':'||event_name;
    perform private.enqueue_customer_operational_notification(
      new.customer_id,new.branch_id,event_name,'booking',new.id,key,clock_timestamp(),
      jsonb_build_object('booking_date',new.booking_date,'booking_time',new.booking_time)
    );
    perform private.schedule_customer_booking_reminder(new);
    return new;
  end if;

  if old.status is distinct from new.status then
    if new.status='confirmed' then
      perform private.enqueue_customer_operational_notification(
        new.customer_id,new.branch_id,'booking_confirmed','booking',new.id,
        'booking:'||new.id::text||':confirmed',clock_timestamp(),
        jsonb_build_object('booking_date',new.booking_date,'booking_time',new.booking_time)
      );
    elsif new.status='cancelled' then
      perform private.enqueue_customer_operational_notification(
        new.customer_id,new.branch_id,'booking_cancelled','booking',new.id,
        'booking:'||new.id::text||':cancelled',clock_timestamp(),'{}'::jsonb
      );
      update private.customer_operational_notifications
        set cancelled_at=clock_timestamp()
        where source_kind='booking' and source_id=new.id and event_type='booking_reminder'
          and cancelled_at is null and available_at>clock_timestamp();
      update private.customer_operational_push_outbox p set state='cancelled',updated_at=clock_timestamp()
        from private.customer_operational_notifications n
        where p.notification_id=n.notification_id and n.source_kind='booking' and n.source_id=new.id
          and n.event_type='booking_reminder' and p.state='queued';
    end if;
  end if;

  if (old.booking_date,old.booking_time) is distinct from (new.booking_date,new.booking_time) then
    update private.customer_operational_notifications
      set cancelled_at=clock_timestamp()
      where source_kind='booking' and source_id=new.id and event_type='booking_reminder'
        and cancelled_at is null and available_at>clock_timestamp();
    update private.customer_operational_push_outbox p set state='cancelled',updated_at=clock_timestamp()
      from private.customer_operational_notifications n
      where p.notification_id=n.notification_id and n.source_kind='booking' and n.source_id=new.id
        and n.event_type='booking_reminder' and p.state='queued';
    if new.status in ('pending','confirmed') then
      key:='booking:'||new.id::text||':rescheduled:'||new.booking_date::text||':'||new.booking_time::text;
      perform private.enqueue_customer_operational_notification(
        new.customer_id,new.branch_id,'booking_rescheduled','booking',new.id,key,clock_timestamp(),
        jsonb_build_object('booking_date',new.booking_date,'booking_time',new.booking_time)
      );
      perform private.schedule_customer_booking_reminder(new);
    end if;
  end if;
  return new;
end$$;
revoke all on function private.customer_booking_operational_notice() from public,anon,authenticated,service_role;
create trigger customer_booking_operational_notice
  after insert or update of status,booking_date,booking_time on public.bookings
  for each row execute function private.customer_booking_operational_notice();

create function private.customer_service_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare event_name text;
begin
  if new.status is not distinct from old.status or new.customer_id is null
     or new.order_type not in ('service','mixed') then return new; end if;
  event_name:=case new.status
    when 'in_progress' then 'service_started'
    when 'quality_check' then 'service_quality_check'
    when 'completed' then 'vehicle_ready'
    when 'delivered' then 'vehicle_delivered'
    when 'cancelled' then 'service_cancelled'
    else null end;
  if event_name is not null then
    perform private.enqueue_customer_operational_notification(
      new.customer_id,new.branch_id,event_name,'order',new.order_id,
      'order:'||new.order_id::text||':status:'||new.status,
      clock_timestamp(),jsonb_build_object('status',new.status)
    );
  end if;
  return new;
end$$;
revoke all on function private.customer_service_operational_notice() from public,anon,authenticated,service_role;
create trigger customer_service_operational_notice
  after update of status on public.business_orders
  for each row execute function private.customer_service_operational_notice();

create function private.customer_loyalty_points_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare b public.business_orders%rowtype;i public.business_invoices%rowtype;net_paid numeric;
begin
  if new.points<=0 or new.reason<>'Completed service visit' or new.order_id is null then return new; end if;
  select * into b from public.business_orders where order_id=new.order_id and customer_id=new.customer_id;
  if b.order_id is null or b.status not in ('completed','delivered') or b.order_type<>'service'
     or not exists(select 1 from public.bookings where id=b.booking_id and customer_id=b.customer_id and status='completed') then return new; end if;
  select * into i from public.business_invoices where order_id=b.order_id and status='active' order by created_at desc limit 1;
  if i.invoice_id is null or i.total<=0 then return new; end if;
  select coalesce(sum(case when event_type='sale' then amount else -amount end),0)
    into net_paid from public.business_payment_events where invoice_id=i.invoice_id;
  if net_paid<i.total then return new; end if;
  perform private.enqueue_customer_operational_notification(
    new.customer_id,b.branch_id,'loyalty_points_added','loyalty',new.transaction_id,
    'loyalty:points:'||new.transaction_id::text,clock_timestamp(),
    jsonb_build_object('points_earned',new.points)
  );
  return new;
end$$;
revoke all on function private.customer_loyalty_points_operational_notice() from public,anon,authenticated,service_role;
create trigger customer_loyalty_points_operational_notice
  after insert on public.business_loyalty_transactions
  for each row execute function private.customer_loyalty_points_operational_notice();

create function private.customer_canonical_visit_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
  if new.kind='earn' then
    perform private.enqueue_customer_operational_notification(
      new.customer_id,new.branch_id,'loyalty_visit_earned','loyalty',new.id,
      'loyalty:visit:'||new.id::text,clock_timestamp(),jsonb_build_object('visits_earned',new.visits)
    );
  end if;
  return new;
end$$;
revoke all on function private.customer_canonical_visit_operational_notice() from public,anon,authenticated,service_role;
create trigger customer_canonical_visit_operational_notice
  after insert on private.canonical_loyalty_visits
  for each row execute function private.customer_canonical_visit_operational_notice();

create function private.customer_operational_push_preference_guard()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
  if old.order_push_enabled and not new.order_push_enabled then
    update private.customer_operational_push_outbox set state='suppressed',updated_at=clock_timestamp()
      where customer_id=new.customer_id and state='queued';
  end if;
  return new;
end$$;
revoke all on function private.customer_operational_push_preference_guard() from public,anon,authenticated,service_role;
create trigger customer_operational_push_preference_guard
  after update of order_push_enabled on public.customer_marketing_preferences
  for each row execute function private.customer_operational_push_preference_guard();

create function private.list_my_customer_operational_notifications(p_limit integer default 50)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();items jsonb;unread bigint;
begin
  if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid limit' using errcode='22023'; end if;
  if not exists(select 1 from public.customers where id=actor) then raise exception 'Customer inbox unavailable' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'notification_id',n.notification_id,'event_type',n.event_type,'source_kind',n.source_kind,
    'source_id',n.source_id,'payload',n.payload,'created_at',n.created_at,
    'available_at',n.available_at,'read',n.read_at is not null,
    'deep_link',case when n.source_kind='booking' then '/booking' else '/orders' end
  ) order by n.available_at desc,n.notification_id desc),'[]'::jsonb),
  count(*) filter(where n.read_at is null)
  into items,unread from (
    select * from private.customer_operational_notifications
    where customer_id=actor and cancelled_at is null and available_at<=clock_timestamp()
    order by available_at desc,notification_id desc limit p_limit
  ) n;
  return jsonb_build_object('items',items,'unread_count',coalesce(unread,0));
end$$;

create function private.mark_my_customer_operational_notification_read(p_notification uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.app_inbox_actor();n private.customer_operational_notifications%rowtype;changed boolean;
begin
  if p_notification is null or not exists(select 1 from public.customers where id=actor) then raise exception 'Customer notification unavailable' using errcode='42501'; end if;
  select * into n from private.customer_operational_notifications
    where notification_id=p_notification and customer_id=actor and cancelled_at is null
      and available_at<=clock_timestamp() for update;
  if not found then raise exception 'Customer notification unavailable' using errcode='42501'; end if;
  changed:=n.read_at is null;
  if changed then update private.customer_operational_notifications set read_at=clock_timestamp() where notification_id=n.notification_id returning * into n; end if;
  return jsonb_build_object('notification_id',n.notification_id,'read',true,'changed',changed,'read_at',n.read_at);
end$$;
revoke all on function private.list_my_customer_operational_notifications(integer),private.mark_my_customer_operational_notification_read(uuid)
  from public,anon,service_role;
grant execute on function private.list_my_customer_operational_notifications(integer),private.mark_my_customer_operational_notification_read(uuid)
  to authenticated;
create function public.list_my_customer_operational_notifications(p_limit integer default 50)
returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.list_my_customer_operational_notifications(p_limit)$$;
create function public.mark_my_customer_operational_notification_read(p_notification uuid)
returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.mark_my_customer_operational_notification_read(p_notification)$$;
revoke all on function public.list_my_customer_operational_notifications(integer),public.mark_my_customer_operational_notification_read(uuid)
  from public,anon,service_role;
grant execute on function public.list_my_customer_operational_notifications(integer),public.mark_my_customer_operational_notification_read(uuid)
  to authenticated;

-- Promotional photos are intentionally public media; upload is owner-only,
-- MIME/size limited, path-randomized and overwrite/delete are denied to clients.
do $$
begin
  if exists(select 1 from storage.buckets where id='customer-notification-media') then
    raise exception 'Notification media bucket already exists; review it before applying this migration';
  end if;
  insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('customer-notification-media','customer-notification-media',true,3145728,
      array['image/jpeg','image/png','image/webp']);
end$$;
create policy customer_notification_media_owner_insert
  on storage.objects for insert to authenticated
  with check (bucket_id='customer-notification-media'
    and name~'^campaigns/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$'
    and (select private.active_staff_role())='owner');
create policy customer_notification_media_insert_guard
  on storage.objects as restrictive for insert to anon,authenticated
  with check (bucket_id<>'customer-notification-media' or
    (auth.role()='authenticated' and name~'^campaigns/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$'
      and (select private.active_staff_role())='owner'));
create policy customer_notification_media_no_overwrite
  on storage.objects as restrictive for update to anon,authenticated
  using (bucket_id<>'customer-notification-media')
  with check (bucket_id<>'customer-notification-media');
create policy customer_notification_media_no_delete
  on storage.objects as restrictive for delete to anon,authenticated
  using (bucket_id<>'customer-notification-media');

notify pgrst,'reload schema';
commit;
