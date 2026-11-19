-- Marketing delivery is customer-only. Staff devices use a separate audience value.

create table public.customer_marketing_preferences (
    customer_id uuid primary key references public.customers(id) on delete cascade,
    marketing_push_enabled boolean not null default false,
    consent_updated_at timestamptz,
    updated_at timestamptz not null default now(),
    check (not marketing_push_enabled or consent_updated_at is not null)
);

alter table public.customer_marketing_preferences enable row level security;
revoke all on public.customer_marketing_preferences from anon, authenticated;
grant select, insert, update on public.customer_marketing_preferences to authenticated;

create policy "Customers manage their own marketing preference"
on public.customer_marketing_preferences for all to authenticated
using (customer_id = (select auth.uid()))
with check (customer_id = (select auth.uid()));

create table public.push_device_tokens (
    token_id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    audience text not null check (audience in ('customer', 'staff')),
    device_token text not null unique,
    platform text not null check (platform in ('android', 'ios', 'web')),
    locale text not null default 'ar' check (locale in ('ar', 'en')),
    is_active boolean not null default true,
    last_seen_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, audience, device_token)
);

create index push_device_tokens_audience_user_idx
    on public.push_device_tokens (audience, user_id) where is_active;

alter table public.push_device_tokens enable row level security;
revoke all on public.push_device_tokens from anon, authenticated;
grant select, insert, update, delete on public.push_device_tokens to authenticated;

create policy "Users manage only their audience-specific devices"
on public.push_device_tokens for all to authenticated
using (
    user_id = (select auth.uid())
    and (
        (audience = 'customer' and exists (
            select 1 from public.customers c where c.id = (select auth.uid())
        ))
        or
        (audience = 'staff' and exists (
            select 1 from public.staff_profiles sp
            where sp.user_id = (select auth.uid()) and sp.is_active
        ))
    )
)
with check (
    user_id = (select auth.uid())
    and (
        (audience = 'customer' and exists (
            select 1 from public.customers c where c.id = (select auth.uid())
        ))
        or
        (audience = 'staff' and exists (
            select 1 from public.staff_profiles sp
            where sp.user_id = (select auth.uid()) and sp.is_active
        ))
    )
);

create table public.marketing_campaigns (
    campaign_id uuid primary key default gen_random_uuid(),
    title text not null check (length(trim(title)) between 1 and 120),
    body text not null check (length(trim(body)) between 1 and 1000),
    title_en text check (title_en is null or length(trim(title_en)) between 1 and 120),
    body_en text check (body_en is null or length(trim(body_en)) between 1 and 1000),
    image_url text,
    deep_link text not null default '/offers',
    offer_id uuid references public.business_offers(offer_id) on delete set null,
    target_segment jsonb not null default '{"type":"all"}'::jsonb
        check (jsonb_typeof(target_segment) = 'object'),
    scheduled_at timestamptz not null,
    next_scheduled_at timestamptz not null,
    time_zone text not null default 'Africa/Cairo',
    recurrence text not null default 'once'
        check (recurrence in ('once', 'daily', 'weekly', 'monthly')),
    recurrence_ends_at timestamptz,
    status text not null default 'draft'
        check (status in ('draft', 'scheduled', 'sending', 'sent', 'failed', 'paused', 'cancelled', 'completed')),
    created_by uuid references auth.users(id) on delete set null,
    updated_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    last_error text,
    check (deep_link ~ '^/(offers|booking)(/|$)'),
    check (recurrence_ends_at is null or recurrence_ends_at >= scheduled_at)
);

create index marketing_campaigns_due_idx
    on public.marketing_campaigns (next_scheduled_at)
    where status = 'scheduled';

alter table public.marketing_campaigns enable row level security;
revoke all on public.marketing_campaigns from anon, authenticated;
grant select, insert, update, delete on public.marketing_campaigns to authenticated;

create policy "Owners read marketing campaigns"
on public.marketing_campaigns for select to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

create policy "Owners create marketing campaigns"
on public.marketing_campaigns for insert to authenticated
with check (
    created_by = (select auth.uid())
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

create policy "Owners update marketing campaigns"
on public.marketing_campaigns for update to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
))
with check (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

create policy "Owners delete campaigns before dispatch"
on public.marketing_campaigns for delete to authenticated
using (
    status in ('draft', 'scheduled', 'paused', 'cancelled')
    and exists (
        select 1 from public.staff_profiles sp
        where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
    )
);

create table public.marketing_campaign_runs (
    run_id uuid primary key default gen_random_uuid(),
    campaign_id uuid not null references public.marketing_campaigns(campaign_id) on delete restrict,
    scheduled_for timestamptz not null,
    status text not null default 'queued'
        check (status in ('queued', 'sending', 'sent', 'failed')),
    started_at timestamptz,
    finished_at timestamptz,
    recipient_count integer not null default 0,
    accepted_count integer not null default 0,
    failed_count integer not null default 0,
    error_message text,
    created_at timestamptz not null default now(),
    unique (campaign_id, scheduled_for)
);

create index marketing_campaign_runs_campaign_idx
    on public.marketing_campaign_runs (campaign_id, scheduled_for desc);

create table public.marketing_campaign_recipients (
    recipient_id uuid primary key default gen_random_uuid(),
    run_id uuid not null references public.marketing_campaign_runs(run_id) on delete cascade,
    campaign_id uuid not null references public.marketing_campaigns(campaign_id) on delete restrict,
    customer_id uuid not null references public.customers(id) on delete cascade,
    status text not null default 'queued'
        check (status in ('queued', 'sending', 'accepted', 'opened', 'failed', 'suppressed')),
    device_count integer not null default 0,
    accepted_device_count integer not null default 0,
    failed_device_count integer not null default 0,
    error_message text,
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    opened_at timestamptz,
    unique (run_id, customer_id)
);

create index marketing_campaign_recipients_campaign_status_idx
    on public.marketing_campaign_recipients (campaign_id, status);

create table public.marketing_campaign_delivery_attempts (
    attempt_id uuid primary key default gen_random_uuid(),
    recipient_id uuid not null references public.marketing_campaign_recipients(recipient_id) on delete cascade,
    token_id uuid not null references public.push_device_tokens(token_id) on delete cascade,
    status text not null check (status in ('sending', 'accepted', 'failed')),
    provider_message_id text,
    error_message text,
    attempted_at timestamptz not null default now(),
    unique (recipient_id, token_id)
);

create table public.marketing_campaign_events (
    event_id uuid primary key default gen_random_uuid(),
    campaign_id uuid not null references public.marketing_campaigns(campaign_id) on delete restrict,
    run_id uuid references public.marketing_campaign_runs(run_id) on delete set null,
    recipient_id uuid references public.marketing_campaign_recipients(recipient_id) on delete set null,
    customer_id uuid references public.customers(id) on delete set null,
    event_type text not null check (event_type in ('accepted', 'opened', 'booking', 'purchase')),
    occurred_at timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb
);

create index marketing_campaign_events_campaign_type_idx
    on public.marketing_campaign_events (campaign_id, event_type, occurred_at desc);

alter table public.marketing_campaign_runs enable row level security;
alter table public.marketing_campaign_recipients enable row level security;
alter table public.marketing_campaign_delivery_attempts enable row level security;
alter table public.marketing_campaign_events enable row level security;
revoke all on public.marketing_campaign_runs, public.marketing_campaign_recipients,
    public.marketing_campaign_delivery_attempts, public.marketing_campaign_events
    from anon, authenticated;
grant select on public.marketing_campaign_runs, public.marketing_campaign_recipients,
    public.marketing_campaign_delivery_attempts, public.marketing_campaign_events to authenticated;

create policy "Owners read campaign runs"
on public.marketing_campaign_runs for select to authenticated
using (exists (
    select 1 from public.marketing_campaigns c
    join public.staff_profiles sp on sp.user_id = (select auth.uid())
    where c.campaign_id = marketing_campaign_runs.campaign_id
      and sp.is_active and sp.role = 'owner'
));

create policy "Owners read campaign recipients"
on public.marketing_campaign_recipients for select to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

create policy "Owners read campaign events"
on public.marketing_campaign_events for select to authenticated
using (exists (
    select 1 from public.staff_profiles sp
    where sp.user_id = (select auth.uid()) and sp.is_active and sp.role = 'owner'
));

create policy "Owners read campaign delivery attempts"
on public.marketing_campaign_delivery_attempts for select to authenticated
using (exists (
    select 1
    from public.marketing_campaign_recipients r
    join public.staff_profiles sp on sp.user_id = (select auth.uid())
    where r.recipient_id = marketing_campaign_delivery_attempts.recipient_id
      and sp.is_active and sp.role = 'owner'
));

create or replace function public.validate_marketing_campaign_schedule()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
    if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.time_zone) then
        raise exception 'Unknown campaign time zone';
    end if;
    if tg_op = 'INSERT' then
        new.next_scheduled_at := new.scheduled_at;
    elsif old.status in ('sending', 'sent') and (
        new.title is distinct from old.title
        or new.body is distinct from old.body
        or new.title_en is distinct from old.title_en
        or new.body_en is distinct from old.body_en
        or new.image_url is distinct from old.image_url
        or new.deep_link is distinct from old.deep_link
        or new.offer_id is distinct from old.offer_id
        or new.target_segment is distinct from old.target_segment
        or new.scheduled_at is distinct from old.scheduled_at
        or new.time_zone is distinct from old.time_zone
        or new.recurrence is distinct from old.recurrence
        or new.recurrence_ends_at is distinct from old.recurrence_ends_at
    ) then
        raise exception 'Campaign content cannot be changed after dispatch begins';
    elsif old.status in ('draft', 'paused') and new.status = 'scheduled' then
        new.next_scheduled_at := new.scheduled_at;
    elsif old.status = 'scheduled' and new.scheduled_at is distinct from old.scheduled_at then
        new.next_scheduled_at := new.scheduled_at;
    end if;
    new.updated_at := now();
    return new;
end;
$$;

create trigger validate_marketing_campaign_schedule
before insert or update on public.marketing_campaigns
for each row execute function public.validate_marketing_campaign_schedule();

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
        on conflict (campaign_id, scheduled_for) do nothing
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

create or replace function public.finish_marketing_campaign_run(
    p_run_id uuid,
    p_status text,
    p_recipient_count integer,
    p_accepted_count integer,
    p_failed_count integer,
    p_error_message text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_campaign_id uuid;
    v_recurrence text;
begin
    if p_status not in ('sent', 'failed') then
        raise exception 'Invalid campaign run status';
    end if;
    update public.marketing_campaign_runs
    set status = p_status,
        finished_at = now(),
        recipient_count = greatest(p_recipient_count, 0),
        accepted_count = greatest(p_accepted_count, 0),
        failed_count = greatest(p_failed_count, 0),
        error_message = left(p_error_message, 1000)
    where run_id = p_run_id and status in ('queued', 'sending')
    returning campaign_id into v_campaign_id;
    if not found then raise exception 'Campaign run not found'; end if;

    select recurrence into v_recurrence
    from public.marketing_campaigns where campaign_id = v_campaign_id;
    if v_recurrence = 'once' then
        update public.marketing_campaigns
        set status = case when p_status = 'sent' then 'sent' else 'failed' end,
            last_error = left(p_error_message, 1000),
            updated_at = now()
        where campaign_id = v_campaign_id and status = 'sending';
    end if;
end;
$$;

create or replace function public.record_marketing_open(p_recipient_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_customer_id uuid;
    v_campaign_id uuid;
    v_run_id uuid;
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    select customer_id, campaign_id, run_id
    into v_customer_id, v_campaign_id, v_run_id
    from public.marketing_campaign_recipients
    where recipient_id = p_recipient_id;
    if not found or v_customer_id <> auth.uid() then
        raise exception 'Notification recipient not found';
    end if;
    update public.marketing_campaign_recipients
    set status = 'opened', opened_at = coalesce(opened_at, now())
    where recipient_id = p_recipient_id and status in ('accepted', 'opened');
    if not found then return false; end if;
    insert into public.marketing_campaign_events (campaign_id, run_id, recipient_id, customer_id, event_type)
    values (v_campaign_id, v_run_id, p_recipient_id, v_customer_id, 'opened');
    return true;
end;
$$;

revoke all on function public.claim_due_marketing_campaigns(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.claim_due_marketing_campaigns(timestamptz, integer) to service_role;
revoke all on function public.finish_marketing_campaign_run(uuid, text, integer, integer, integer, text) from public, anon, authenticated;
grant execute on function public.finish_marketing_campaign_run(uuid, text, integer, integer, integer, text) to service_role;
revoke all on function public.record_marketing_open(uuid) from public, anon;
grant execute on function public.record_marketing_open(uuid) to authenticated;
