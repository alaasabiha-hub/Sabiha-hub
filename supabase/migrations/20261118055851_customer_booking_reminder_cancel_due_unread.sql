begin;

-- A reminder that is already due but still unread is still pending from the
-- customer's perspective. Cancel it on a reschedule/cancellation; preserve a
-- reminder the customer has already read as inbox history.
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
          and cancelled_at is null and read_at is null;
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
        and cancelled_at is null and read_at is null;
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
