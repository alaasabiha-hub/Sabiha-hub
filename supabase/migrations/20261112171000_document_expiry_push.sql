-- Server-side, idempotent expiry reminders for owner devices.
alter table public.business_document_alerts
    add column if not exists delivery_status text not null default 'queued'
        check (delivery_status in ('queued', 'sending', 'sent', 'failed'));
alter table public.business_document_alerts
    add column if not exists attempt_count integer not null default 0 check (attempt_count >= 0);
alter table public.business_document_alerts
    add column if not exists last_error text;

revoke insert, update on public.business_document_alerts from authenticated;
grant select, delete on public.business_document_alerts to authenticated;

update public.business_document_alerts
set delivery_status = 'sent'
where sent_at is not null and delivery_status <> 'sent';

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
    on conflict (document_id, alert_date, days_before_expiry) do nothing;

    insert into public.business_document_alerts(document_id, alert_date, days_before_expiry)
    select d.document_id, p_today, -1
    from public.business_documents d
    where d.expires_at < p_today
    on conflict (document_id, alert_date, days_before_expiry) do nothing;

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

create or replace function public.finish_business_document_alert(p_alert_id uuid, p_sent boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
    update public.business_document_alerts
    set delivery_status = case when p_sent then 'sent' else 'failed' end,
        sent_at = case when p_sent then now() else sent_at end,
        last_error = case when p_sent then null else left(coalesce(p_error, 'Delivery failed'), 300) end
    where alert_id = p_alert_id and delivery_status = 'sending';
    if not found then raise exception 'Alert is not currently claimed'; end if;
end;
$$;

revoke all on function public.claim_due_business_document_alerts(date, integer) from public, anon, authenticated;
grant execute on function public.claim_due_business_document_alerts(date, integer) to service_role;
revoke all on function public.finish_business_document_alert(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.finish_business_document_alert(uuid, boolean, text) to service_role;
