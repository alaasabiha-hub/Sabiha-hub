begin;

-- Avoid PL/pgSQL name resolution colliding with public.customers.id.
create or replace function private.enqueue_customer_operational_notification(
  p_customer uuid,p_branch uuid,p_event text,p_source_kind text,p_source uuid,
  p_event_key text,p_available_at timestamptz,p_payload jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare v_notification_id uuid;
begin
  if p_customer is null or p_branch is null or p_source is null
     or p_event_key is null or length(p_event_key) not between 1 and 240
     or jsonb_typeof(coalesce(p_payload,'{}'::jsonb))<>'object'
     or pg_column_size(coalesce(p_payload,'{}'::jsonb))>2048 then
    raise exception 'Valid customer notification source required' using errcode='22023';
  end if;
  if not exists(select 1 from public.customers c where c.id=p_customer)
     or not exists(select 1 from public.business_branches b where b.branch_id=p_branch) then
    return null;
  end if;
  insert into private.customer_operational_notifications(
    customer_id,branch_id,event_type,source_kind,source_id,event_key,payload,available_at
  ) values(p_customer,p_branch,p_event,p_source_kind,p_source,p_event_key,
    coalesce(p_payload,'{}'::jsonb),coalesce(p_available_at,clock_timestamp()))
  on conflict(event_key) do nothing returning notification_id into v_notification_id;
  if v_notification_id is null then
    select n.notification_id into v_notification_id
    from private.customer_operational_notifications n where n.event_key=p_event_key;
    return v_notification_id;
  end if;
  if exists(select 1 from public.customer_marketing_preferences pref
      where pref.customer_id=p_customer and pref.order_push_enabled) then
    insert into private.customer_operational_push_outbox(notification_id,customer_id,next_attempt_at)
    values(v_notification_id,p_customer,coalesce(p_available_at,clock_timestamp()))
    on conflict(notification_id) do nothing;
  end if;
  return v_notification_id;
end$$;
revoke all on function private.enqueue_customer_operational_notification(uuid,uuid,text,text,uuid,text,timestamptz,jsonb)
  from public,anon,authenticated,service_role;

commit;
