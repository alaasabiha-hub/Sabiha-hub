begin;
-- Arrival priority is independent of service approval, payment and inspection.
create table private.wash_reception_entries(
 booking_id uuid primary key references public.bookings(id),branch_id uuid not null references public.business_branches(branch_id),
 arrived_at timestamptz not null default clock_timestamp(),priority text not null check(priority in ('normal','vip')),
 revision integer not null default 1 check(revision>0),changed_by uuid not null references auth.users(id),updated_at timestamptz not null default clock_timestamp());
create table private.wash_reception_requests(request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.wash_reception_entries enable row level security;
alter table private.wash_reception_requests enable row level security;
revoke all on private.wash_reception_entries,private.wash_reception_requests from public,anon,authenticated,service_role;
create function private.update_wash_reception(p_request uuid,p_booking uuid,p_action text,p_priority text,p_expected_revision integer,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid();b public.bookings%rowtype;e private.wash_reception_entries%rowtype;prior private.wash_reception_requests%rowtype;payload jsonb;before_value jsonb;result jsonb;
begin
 if actor is null or private.active_staff_role() not in ('owner','manager') or private.active_staff_role() is null then raise exception 'Reception management permission required' using errcode='42501';end if;
 select * into b from public.bookings where id=p_booking for update;
 if not found or not coalesce(private.can_access_branch(b.branch_id),false) then raise exception 'Reception branch access denied' using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in ('arrive','priority') or p_priority is null or p_priority not in ('normal','vip') or p_expected_revision is null or p_expected_revision<0 or length(trim(coalesce(p_reason,''))) not between 5 and 300 then raise exception 'Valid arrival, priority and reason required' using errcode='22023';end if;
 payload:=jsonb_build_object('booking',p_booking,'action',p_action,'priority',p_priority,'expected_revision',p_expected_revision,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('wash-reception-request:'||p_request::text,0));
 select * into prior from private.wash_reception_requests where request_id=p_request;
 if found then
  if prior.actor_id<>actor then raise exception 'Reception request access denied' using errcode='42501';end if;
  if prior.payload<>payload then raise exception 'Reception request payload mismatch' using errcode='22023';end if;
  return prior.result;
 end if;
 if b.status<>'confirmed' or b.booking_date<>(clock_timestamp() at time zone 'Africa/Cairo')::date then raise exception 'Reception changes require a confirmed appointment today' using errcode='55000';end if;
 select * into e from private.wash_reception_entries where booking_id=b.id for update;
 if e.booking_id is not null and e.branch_id<>b.branch_id then raise exception 'Reception branch differs from booking; management review required' using errcode='55000';end if;
 if p_action='arrive' then
  if e.booking_id is not null or p_expected_revision<>0 then raise exception 'Arrival already registered; refresh the queue' using errcode='40001';end if;
  insert into private.wash_reception_entries(booking_id,branch_id,priority,changed_by) values(b.id,b.branch_id,p_priority,actor) returning * into e;
 else
  if e.booking_id is null or e.revision<>p_expected_revision then raise exception 'Reception priority changed; refresh the queue' using errcode='40001';end if;
  before_value:=to_jsonb(e);
  update private.wash_reception_entries set priority=p_priority,revision=revision+1,changed_by=actor,updated_at=clock_timestamp() where booking_id=b.id returning * into e;
 end if;
 result:=to_jsonb(e);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data) values(actor::text,actor,'wash_reception_'||p_action,'bookings',b.id::text,b.branch_id,trim(p_reason),before_value,result);
 insert into private.wash_reception_requests(request_id,actor_id,payload,result) values(p_request,actor,payload,result);
 return result;
end;$$;
create function private.get_wash_reception_queue(p_branch uuid default null) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare role_name text:=private.active_staff_role();begin
 if auth.uid() is null or role_name is null or role_name not in ('owner','manager','employee') then raise exception 'Staff reception access required' using errcode='42501';end if;
 if p_branch is not null and not coalesce(private.can_access_branch(p_branch),false) then raise exception 'Reception branch access denied' using errcode='42501';end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.in_service desc,q.arrived desc,q.vip desc,q.arrived_at nulls last,q.booking_time,q.id) from(
  select b.id,coalesce(b.display_number,'SH-'||upper(left(replace(b.id::text,'-',''),8))) booking_number,b.branch_id,br.name_ar branch_name_ar,br.name_en branch_name_en,b.service_name,b.booking_date,b.booking_time,b.status,
   v.plate_number,exists(select 1 from private.wash_reception_entries mismatch where mismatch.booking_id=b.id and mismatch.branch_id<>b.branch_id) branch_conflict,b.status='in_progress' in_service,e.booking_id is not null arrived,e.priority='vip' vip,e.priority,e.arrived_at,coalesce(e.revision,0) revision
  from public.bookings b join public.business_branches br on br.branch_id=b.branch_id
  left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
  left join private.wash_reception_entries e on e.booking_id=b.id and e.branch_id=b.branch_id
  where b.booking_date=(now() at time zone 'Africa/Cairo')::date and b.status in ('confirmed','in_progress')
    and (p_branch is null or b.branch_id=p_branch) and coalesce(private.can_access_branch(b.branch_id),false)
    and (role_name in ('owner','manager') or auth.uid()=any(b.assigned_staff_ids))
 )q),'[]'::jsonb);
end;$$;
create function public.update_wash_reception(p_request uuid,p_booking uuid,p_action text,p_priority text,p_expected_revision integer,p_reason text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.update_wash_reception(p_request,p_booking,p_action,p_priority,p_expected_revision,p_reason);$$;
create function public.get_wash_reception_queue(p_branch uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_wash_reception_queue(p_branch);$$;
revoke all on function private.update_wash_reception(uuid,uuid,text,text,integer,text),public.update_wash_reception(uuid,uuid,text,text,integer,text),private.get_wash_reception_queue(uuid),public.get_wash_reception_queue(uuid) from public,anon;
grant execute on function private.update_wash_reception(uuid,uuid,text,text,integer,text),public.update_wash_reception(uuid,uuid,text,text,integer,text),private.get_wash_reception_queue(uuid),public.get_wash_reception_queue(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
