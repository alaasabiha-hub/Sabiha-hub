begin;

-- Append-only, branch-scoped daily close snapshots for the Flutter operations schema.
-- The legacy Streamlit business_daily_closures table is intentionally untouched.
create table private.branch_daily_closures (
  close_id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  branch_id uuid not null references public.business_branches(branch_id),
  business_date date not null,
  status text not null default 'awaiting_approval'
    check (status in ('awaiting_approval','approved')),
  snapshot jsonb not null check (jsonb_typeof(snapshot)='object'),
  prepared_by uuid not null references auth.users(id),
  prepared_at timestamptz not null default clock_timestamp(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  unique (branch_id,business_date),
  check ((status='awaiting_approval' and approved_by is null and approved_at is null)
      or (status='approved' and approved_by is not null and approved_at is not null))
);
create index branch_daily_closures_date_idx
  on private.branch_daily_closures(branch_id,business_date desc);

create table private.branch_daily_close_corrections (
  correction_id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  close_id uuid not null references private.branch_daily_closures(close_id),
  actor_id uuid not null references auth.users(id),
  reason text not null check (length(trim(reason)) between 8 and 1000),
  correction jsonb not null check (jsonb_typeof(correction)='object'),
  created_at timestamptz not null default clock_timestamp()
);

alter table private.branch_daily_closures enable row level security;
alter table private.branch_daily_close_corrections enable row level security;
revoke all on private.branch_daily_closures,private.branch_daily_close_corrections
  from public,anon,authenticated,service_role;

create function private.guard_branch_daily_close() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin
  if tg_op='DELETE' then
    raise exception 'Daily close history is retained; append a correction instead' using errcode='55000';
  end if;
  if old.status='awaiting_approval' and new.status='approved'
     and (to_jsonb(new)-array['status','approved_by','approved_at'])
         is not distinct from (to_jsonb(old)-array['status','approved_by','approved_at'])
     and new.approved_by=auth.uid() and private.active_staff_role()='owner'
     and new.approved_at is not null then
    return new;
  end if;
  raise exception 'Daily close snapshot is immutable; owner approval or correction record required' using errcode='55000';
end$$;
create trigger branch_daily_close_immutable
  before update or delete on private.branch_daily_closures
  for each row execute function private.guard_branch_daily_close();
create trigger branch_daily_close_correction_immutable
  before update or delete on private.branch_daily_close_corrections
  for each row execute function private.immutable_loyalty_policy();
revoke all on function private.guard_branch_daily_close() from public,anon,authenticated,service_role;

create function private.get_branch_daily_close(p_branch uuid,p_date date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare role_name text:=private.active_staff_role(); actor uuid:=auth.uid(); result jsonb;
begin
  if actor is null or role_name not in ('owner','manager') or p_branch is null or p_date is null
     or not coalesce(private.can_access_branch(p_branch),false) then
    raise exception 'Owner or authorized branch manager required' using errcode='42501';
  end if;
  select jsonb_build_object('close_id',d.close_id,'branch_id',d.branch_id,'business_date',d.business_date,
    'status',d.status,'snapshot',d.snapshot,'prepared_by',d.prepared_by,'prepared_at',d.prepared_at,
    'approved_by',d.approved_by,'approved_at',d.approved_at,
    'corrections',coalesce((select jsonb_agg(jsonb_build_object('correction_id',c.correction_id,'actor_id',c.actor_id,'reason',c.reason,'correction',c.correction,'created_at',c.created_at) order by c.created_at)
      from private.branch_daily_close_corrections c where c.close_id=d.close_id),'[]'::jsonb))
  into result from private.branch_daily_closures d
  where d.branch_id=p_branch and d.business_date=p_date;
  return result;
end$$;

create function private.prepare_branch_daily_close(p_request uuid,p_branch uuid,p_date date)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); role_name text:=private.active_staff_role(); zone text; day_start timestamptz; day_end timestamptz;
  prior private.branch_daily_closures%rowtype; report_data jsonb; shift_data jsonb; payment_data jsonb; expense_data jsonb; snap jsonb; result jsonb;
begin
  if actor is null or role_name not in ('owner','manager') or p_request is null or p_branch is null or p_date is null
     or not coalesce(private.can_access_branch(p_branch),false) then
    raise exception 'Owner or authorized branch manager required' using errcode='42501';
  end if;
  select time_zone into zone from public.business_branches where branch_id=p_branch and is_active;
  if zone is null then raise exception 'Active branch required' using errcode='55000';end if;
  if p_date >= (clock_timestamp() at time zone zone)::date then
    raise exception 'Only a completed business day can be closed' using errcode='22023';
  end if;
  day_start:=p_date::timestamp at time zone zone;
  day_end:=(p_date+1)::timestamp at time zone zone;
  perform pg_advisory_xact_lock(hashtextextended('branch-daily-close:'||p_branch::text||':'||p_date::text,0));
  select * into prior from private.branch_daily_closures where request_id=p_request for update;
  if found then
    if prior.prepared_by<>actor or prior.branch_id<>p_branch or prior.business_date<>p_date then
      raise exception 'Daily close request identity mismatch' using errcode='22023';
    end if;
    return private.get_branch_daily_close(p_branch,p_date);
  end if;
  select * into prior from private.branch_daily_closures where branch_id=p_branch and business_date=p_date for update;
  if found then raise exception 'This branch business day already has a close record' using errcode='55000';end if;

  -- Any cashier shift spanning this day must already have owner approval before sealing it.
  perform 1 from public.business_cashier_shifts s
   where s.branch_id=p_branch and s.opened_at<day_end and coalesce(s.closed_at,clock_timestamp())>=day_start
   order by s.shift_id for update;
  if exists(select 1 from public.business_cashier_shifts s where s.branch_id=p_branch
      and s.opened_at<day_end and coalesce(s.closed_at,clock_timestamp())>=day_start and s.status<>'closed') then
    raise exception 'Every shift spanning this business day must be closed and owner-approved first' using errcode='55000';
  end if;

  report_data:=private.admin_console_data(p_date::timestamp,(p_date+1)::timestamp,p_branch,null,null,null,'');
  select coalesce(jsonb_agg(jsonb_build_object('shift_id',s.shift_id,'cashier_id',s.cashier_id,
      'opened_at',s.opened_at,'closed_at',s.closed_at,'expected_cash',s.expected_cash,
      'actual_cash',s.actual_cash,'difference',s.difference,'difference_reason',s.difference_reason,
      'approved_by',s.approved_by,'approved_at',s.approved_at) order by s.opened_at,s.shift_id),'[]'::jsonb)
    into shift_data from public.business_cashier_shifts s
    where s.branch_id=p_branch and s.status='closed' and s.closed_at>=day_start and s.closed_at<day_end;
  select jsonb_build_object('cash_collected',coalesce(sum(amount) filter(where method='cash' and event_type='sale'),0),
      'card_collected',coalesce(sum(amount) filter(where method='electronic' and event_type='sale'),0),
      'cash_refunded',coalesce(sum(amount) filter(where method='cash' and event_type='refund'),0),
      'card_refunded',coalesce(sum(amount) filter(where method='electronic' and event_type='refund'),0),
      'event_count',count(*)) into payment_data
    from public.business_payment_events e join public.business_cashier_shifts s using(shift_id)
    where s.branch_id=p_branch and e.created_at>=day_start and e.created_at<day_end;
  select jsonb_build_object('total',coalesce(sum(amount),0),'by_category',coalesce(jsonb_agg(jsonb_build_object('category',category,'amount',amount) order by category),'[]'::jsonb))
    into expense_data from public.business_expenses where branch_id=p_branch and expense_date=p_date;
  snap:=jsonb_build_object('business_date',p_date,'time_zone',zone,'captured_at',clock_timestamp(),
    'report',report_data->'report','invoice_basis','issue_time_in_business_timezone',
    'payment_basis','payment_event_time_in_business_timezone','shift_reconciliation_basis','shift_close_time_in_business_timezone','payment_activity',payment_data,
    'shift_reconciliation',shift_data,'expenses',expense_data,
    'profit_status',coalesce(report_data#>>'{report,profit_status}','not_available'));
  insert into private.branch_daily_closures(request_id,branch_id,business_date,snapshot,prepared_by)
    values(p_request,p_branch,p_date,snap,actor);
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)
    values(actor::text,actor,'prepare_daily_close','branch_daily_closures',p_branch::text||':'||p_date::text,p_branch,snap);
  return private.get_branch_daily_close(p_branch,p_date);
end$$;

create function private.approve_branch_daily_close(p_branch uuid,p_date date)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); d private.branch_daily_closures%rowtype;
begin
  if actor is null or private.active_staff_role() is distinct from 'owner' then
    raise exception 'Owner approval required' using errcode='42501';
  end if;
  select * into strict d from private.branch_daily_closures where branch_id=p_branch and business_date=p_date for update;
  if d.status='approved' then return private.get_branch_daily_close(p_branch,p_date);end if;
  update private.branch_daily_closures set status='approved',approved_by=actor,approved_at=clock_timestamp() where close_id=d.close_id;
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)
    values(actor::text,actor,'approve_daily_close','branch_daily_closures',d.close_id::text,p_branch,
      jsonb_build_object('status',d.status),jsonb_build_object('status','approved','approved_at',clock_timestamp()));
  return private.get_branch_daily_close(p_branch,p_date);
end$$;

create function private.record_branch_daily_close_correction(p_request uuid,p_close_id uuid,p_reason text,p_correction jsonb)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); d private.branch_daily_closures%rowtype; prior private.branch_daily_close_corrections%rowtype;
begin
  if actor is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Owner correction required' using errcode='42501';end if;
  if p_request is null or p_close_id is null or length(trim(coalesce(p_reason,''))) not between 8 and 1000
     or jsonb_typeof(p_correction) is distinct from 'object' then raise exception 'Correction request, reason, and object are required' using errcode='22023';end if;
  select * into strict d from private.branch_daily_closures where close_id=p_close_id;
  if d.status<>'approved' then raise exception 'Only an approved close can receive a correction record' using errcode='55000';end if;
  select * into prior from private.branch_daily_close_corrections where request_id=p_request;
  if found then
    if prior.actor_id<>actor or prior.close_id<>p_close_id or prior.reason<>trim(p_reason) or prior.correction<>p_correction then
      raise exception 'Correction request identity mismatch' using errcode='22023';end if;
    return prior.correction_id;
  end if;
  insert into private.branch_daily_close_corrections(request_id,close_id,actor_id,reason,correction)
    values(p_request,p_close_id,actor,trim(p_reason),p_correction) returning correction_id into prior.correction_id;
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data)
    values(actor::text,actor,'correct_daily_close','branch_daily_close_corrections',prior.correction_id::text,d.branch_id,trim(p_reason),p_correction);
  return prior.correction_id;
end$$;

do $$declare f text;begin
 foreach f in array array[
  'private.get_branch_daily_close(uuid,date)','private.prepare_branch_daily_close(uuid,uuid,date)',
  'private.approve_branch_daily_close(uuid,date)','private.record_branch_daily_close_correction(uuid,uuid,text,jsonb)']
 loop
  execute format('revoke all on function %s from public,anon,service_role',f);
  execute format('grant execute on function %s to authenticated',f);
 end loop;
end$$;

create function public.get_branch_daily_close(p_branch uuid,p_date date)
returns jsonb language sql stable security invoker set search_path=pg_catalog
as $$ select private.get_branch_daily_close(p_branch,p_date); $$;
create function public.prepare_branch_daily_close(p_request uuid,p_branch uuid,p_date date)
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.prepare_branch_daily_close(p_request,p_branch,p_date); $$;
create function public.approve_branch_daily_close(p_branch uuid,p_date date)
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.approve_branch_daily_close(p_branch,p_date); $$;
create function public.record_branch_daily_close_correction(p_request uuid,p_close_id uuid,p_reason text,p_correction jsonb)
returns uuid language sql security invoker set search_path=pg_catalog
as $$ select private.record_branch_daily_close_correction(p_request,p_close_id,p_reason,p_correction); $$;

do $$declare f text;begin
 foreach f in array array[
  'public.get_branch_daily_close(uuid,date)','public.prepare_branch_daily_close(uuid,uuid,date)',
  'public.approve_branch_daily_close(uuid,date)','public.record_branch_daily_close_correction(uuid,uuid,text,jsonb)']
 loop
  execute format('revoke all on function %s from public,anon',f);
  execute format('grant execute on function %s to authenticated',f);
 end loop;
end$$;

commit;
