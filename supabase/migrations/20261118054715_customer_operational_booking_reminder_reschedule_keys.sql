begin;

-- A booking can be moved back to a previously used date/time. Give each
-- committed scheduling transition a new key so its old cancelled reminder
-- cannot suppress the replacement. Duplicate no-op updates are filtered by
-- the trigger's IS DISTINCT checks.
create or replace function private.schedule_customer_booking_reminder(p_booking public.bookings)
returns void language plpgsql security definer set search_path=pg_catalog as $$
declare appointment timestamptz; deliver_at timestamptz; reminder_key text;
begin
  if p_booking.customer_id is null or p_booking.status not in ('pending','confirmed') then return; end if;
  appointment:=(p_booking.booking_date+p_booking.booking_time) at time zone 'Africa/Cairo';
  if appointment<=clock_timestamp()+interval '2 hours' then return; end if;
  deliver_at:=greatest(clock_timestamp(),appointment-interval '24 hours');
  reminder_key:='booking:'||p_booking.id::text||':reminder:'||p_booking.booking_date::text||':'||p_booking.booking_time::text||':'||gen_random_uuid()::text;
  perform private.enqueue_customer_operational_notification(
    p_booking.customer_id,p_booking.branch_id,'booking_reminder','booking',p_booking.id,
    reminder_key,deliver_at,
    jsonb_build_object('booking_date',p_booking.booking_date,'booking_time',p_booking.booking_time)
  );
end$$;
revoke all on function private.schedule_customer_booking_reminder(public.bookings)
  from public,anon,authenticated,service_role;

create or replace function private.customer_booking_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare event_name text; key text;
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
      key:='booking:'||new.id::text||':rescheduled:'||new.booking_date::text||':'||new.booking_time::text||':'||gen_random_uuid()::text;
      perform private.enqueue_customer_operational_notification(
        new.customer_id,new.branch_id,'booking_rescheduled','booking',new.id,key,clock_timestamp(),
        jsonb_build_object('booking_date',new.booking_date,'booking_time',new.booking_time)
      );
      perform private.schedule_customer_booking_reminder(new);
    end if;
  end if;
  return new;
end$$;
revoke all on function private.customer_booking_operational_notice()
  from public,anon,authenticated,service_role;

commit;
