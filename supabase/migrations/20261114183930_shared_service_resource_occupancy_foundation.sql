begin;
-- Foundation only: no public work transition, queue change or readiness enable.
create table private.service_resource_events(
 event_id uuid primary key,request_id uuid not null unique,actor_id uuid not null references public.staff_profiles(user_id),
 source_kind text not null check(source_kind in('booking','walk_in')),booking_id uuid references public.bookings(id),walk_in_order_id uuid references private.offline_walk_in_subjects(order_id),
 action text not null check(action in('start','complete','release')),payload jsonb not null,occurred_at timestamptz not null default clock_timestamp(),creator_xid bigint not null,
 check((source_kind='booking'and booking_id is not null and walk_in_order_id is null)or(source_kind='walk_in'and walk_in_order_id is not null and booking_id is null)));
create table private.service_resource_spans(
 span_id uuid primary key,source_kind text not null check(source_kind in('booking','walk_in')),booking_id uuid unique references public.bookings(id),walk_in_order_id uuid unique references private.offline_walk_in_subjects(order_id),
 branch_id uuid not null references public.business_branches(branch_id),resource_key text not null check(resource_key in('wash','polish')),duration_minutes integer not null check(duration_minutes between 5 and 480),
 started_at timestamptz not null,expected_end_at timestamptz not null,start_event_id uuid not null unique references private.service_resource_events(event_id),
 ended_at timestamptz,end_event_id uuid unique references private.service_resource_events(event_id),
 check((source_kind='booking'and booking_id is not null and walk_in_order_id is null)or(source_kind='walk_in'and walk_in_order_id is not null and booking_id is null)),
 check(expected_end_at=started_at+make_interval(mins=>duration_minutes)),check((ended_at is null and end_event_id is null)or(ended_at>=started_at and end_event_id is not null)));
create index service_resource_open_spans on private.service_resource_spans(branch_id,resource_key,expected_end_at)where ended_at is null;
alter table private.service_resource_events enable row level security;alter table private.service_resource_spans enable row level security;
revoke all on private.service_resource_events,private.service_resource_spans from public,anon,authenticated,service_role;
create trigger immutable_service_resource_event before update or delete on private.service_resource_events for each row execute function private.immutable_loyalty_policy();
create function private.guard_service_resource_span()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_e private.service_resource_events;v_branch uuid;v_resource text;v_duration integer;begin
 if tg_op='DELETE'then raise exception 'Physical resource evidence is retained'using errcode='55000';end if;
 if tg_op='INSERT'then
  select * into v_e from private.service_resource_events where event_id=new.start_event_id;
  if v_e.action is distinct from'start'or v_e.source_kind is distinct from new.source_kind or v_e.booking_id is distinct from new.booking_id or v_e.walk_in_order_id is distinct from new.walk_in_order_id or v_e.creator_xid<>txid_current()or v_e.actor_id is distinct from auth.uid()or new.started_at is distinct from v_e.occurred_at or new.ended_at is not null then raise exception 'Current typed start-event proof required'using errcode='55000';end if;
  if new.source_kind='booking'then select branch_id,resource_key,duration_minutes into v_branch,v_resource,v_duration from public.bookings where id=new.booking_id;
  else select branch_id,resource_key,duration_minutes into v_branch,v_resource,v_duration from private.offline_walk_in_subjects where order_id=new.walk_in_order_id;end if;
  if v_branch is distinct from new.branch_id or v_resource is distinct from new.resource_key or v_duration is distinct from new.duration_minutes then raise exception 'Frozen actual service resource binding required'using errcode='55000';end if;
 else
  if(to_jsonb(new)-array['ended_at','end_event_id'])is distinct from(to_jsonb(old)-array['ended_at','end_event_id'])or old.ended_at is not null or new.ended_at is null then raise exception 'Only first witnessed release is permitted'using errcode='55000';end if;
  select * into v_e from private.service_resource_events where event_id=new.end_event_id;
  if v_e.action not in('complete','release')or v_e.source_kind is distinct from new.source_kind or v_e.booking_id is distinct from new.booking_id or v_e.walk_in_order_id is distinct from new.walk_in_order_id or v_e.creator_xid<>txid_current()or v_e.actor_id is distinct from auth.uid()or new.ended_at is distinct from v_e.occurred_at then raise exception 'Current actual typed release-event proof required'using errcode='55000';end if;
 end if;return new;
end$$;
create trigger guard_service_resource_span before insert or update or delete on private.service_resource_spans for each row execute function private.guard_service_resource_span();
create function private.guard_started_booking_resource()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from private.service_resource_spans where booking_id=old.id)and(new.branch_id is distinct from old.branch_id or new.catalog_item_id is distinct from old.catalog_item_id or new.resource_key is distinct from old.resource_key or new.duration_minutes is distinct from old.duration_minutes or new.booking_date is distinct from old.booking_date or new.booking_time is distinct from old.booking_time)then raise exception 'Started physical service resource/interval identity is immutable'using errcode='55000';end if;return new;
end$$;
revoke all on function private.guard_started_booking_resource()from public,anon,authenticated,service_role;
create trigger guard_started_booking_resource before update of branch_id,catalog_item_id,resource_key,duration_minutes,booking_date,booking_time on public.bookings for each row execute function private.guard_started_booking_resource();
create function private.lock_service_resource_days(p_branch uuid,p_resource text,p_days date[])returns void language plpgsql set search_path=pg_catalog as $$declare v_day date;begin
 if p_branch is null or p_resource not in('wash','polish')or p_resource is null or p_days is null or cardinality(p_days)=0 or array_position(p_days,null)is not null then raise exception 'Actual branch/resource/day locks required'using errcode='22023';end if;
 for v_day in select distinct unnest(p_days)order by 1 loop perform pg_advisory_xact_lock(hashtextextended(p_branch::text||v_day::text||p_resource,0));end loop;
end$$;
create function private.service_resource_occupancy(p_branch uuid,p_resource text,p_from timestamptz,p_to timestamptz,p_exclude_booking uuid default null,p_exclude_walk_in uuid default null,p_physical boolean default false)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_capacity integer;v_zone text;v_result jsonb;begin
 if p_branch is null or p_resource is null or p_resource not in('wash','polish')or p_from is null or p_to is null or p_to<=p_from then raise exception 'Actual resource interval required'using errcode='22023';end if;
 select r.capacity,b.time_zone into v_capacity,v_zone from public.business_branch_resources r join public.business_branches b using(branch_id)where r.branch_id=p_branch and r.resource_key=p_resource;
 if v_capacity is null then raise exception 'Resource not configured'using errcode='55000';end if;
 -- Callers hold the resource mutex. Distinct typed keys prevent booking/order double count.
 with booking_sources as(
  select b.id,b.status,(b.booking_date+b.booking_time)at time zone v_zone t0,(b.booking_date+b.booking_time+make_interval(mins=>b.duration_minutes))at time zone v_zone t1,
   b.status='in_progress'or exists(select 1 from public.business_orders o where o.booking_id=b.id and o.order_type='service'and o.status in('in_progress','quality_check'))physical,
   (select count(*)from public.business_orders o where o.booking_id=b.id and o.order_type='service')order_count
  from public.bookings b where b.branch_id=p_branch and b.resource_key=p_resource and b.id is distinct from p_exclude_booking
 ),spans as(
  select s.*,case when s.source_kind='booking'then 'booking:'||s.booking_id::text else 'walk_in:'||s.walk_in_order_id::text end source_key
  from private.service_resource_spans s where s.branch_id=p_branch and s.resource_key=p_resource and s.ended_at is null
   and(p_exclude_booking is null or s.booking_id is distinct from p_exclude_booking)and(p_exclude_walk_in is null or s.walk_in_order_id is distinct from p_exclude_walk_in)
 ),physical_sources as(
  select 'booking:'||b.id::text source_key from booking_sources b where b.physical
  union select s.source_key from spans s
  union select 'walk_in:'||s.order_id::text from private.offline_walk_in_subjects s join public.business_orders o using(order_id)
   where s.branch_id=p_branch and s.resource_key=p_resource and s.order_id is distinct from p_exclude_walk_in and o.status in('in_progress','quality_check')
 ),known_intervals as(
  select 'booking:'||b.id::text source_key,b.t0,b.t1 from booking_sources b where b.status not in('cancelled','completed')
  union all select s.source_key,s.started_at,s.expected_end_at from spans s
 ),overruns as(
  select p.source_key from physical_sources p where not exists(select 1 from known_intervals k where k.source_key=p.source_key and k.t0<=p_from and k.t1>p_from)
 ),intervals as(
  select k.* from known_intervals k
  union all select o.source_key,p_from,p_to from overruns o where p_physical
 ),points as(
  select p_from point union select i.t0 from intervals i where i.t0>p_from and i.t0<p_to
 ),counts as(
  select coalesce(max((select count(distinct i.source_key)from intervals i where i.t0<=p.point and i.t1>p.point)),0)admission_peak from points p
 ),planned_points as(
  select p_from point union select i.t0 from known_intervals i where i.t0>p_from and i.t0<p_to
 ),planned_counts as(
  select coalesce(max((select count(distinct i.source_key)from known_intervals i where i.t0<=p.point and i.t1>p.point)),0)planned_peak from planned_points p
 )select jsonb_build_object('capacity',v_capacity,'planned_peak',pc.planned_peak,'admission_peak',c.admission_peak,'physical_now',(select count(*)from physical_sources),
  'overrun_count',(select count(*)from overruns),'ambiguous_booking_count',(select count(*)from booking_sources where order_count>1),
  'unclassified_active_count',(select count(*)from public.business_orders o where o.branch_id=p_branch and o.order_type='service'and o.booking_id is null and o.status in('in_progress','quality_check')and not exists(select 1 from private.offline_walk_in_subjects s where s.order_id=o.order_id)),
  'typed_active_missing_span_count',(select count(*)from private.offline_walk_in_subjects s join public.business_orders o using(order_id)where s.branch_id=p_branch and s.resource_key=p_resource and s.order_id is distinct from p_exclude_walk_in and o.status in('in_progress','quality_check')and not exists(select 1 from spans r where r.walk_in_order_id=s.order_id)),
  'planning_basis','known_intervals_start_recheck_required','physical_mode',p_physical)into v_result from counts c cross join planned_counts pc;
 return v_result;
end$$;
-- Private assertion only; next reviewed work adapter must call it under the shared mutex.
create function private.assert_service_resource_start(p_branch uuid,p_resource text,p_from timestamptz,p_to timestamptz,p_exclude_booking uuid default null,p_exclude_walk_in uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_facts jsonb;v_required boolean;v_zone text;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Physical admission requires READ COMMITTED'using errcode='55000';end if;
 select inspection_required,time_zone into v_required,v_zone from public.business_branches where branch_id=p_branch and is_active and not temporarily_closed for share;
 if not found then raise exception 'Active branch required'using errcode='55000';end if;
 if p_exclude_walk_in is not null and v_required then raise exception 'Typed inspection adapter required'using errcode='55000';end if;
 perform private.lock_service_resource_days(p_branch,p_resource,array(select distinct d from unnest(array[(p_from at time zone v_zone)::date,(p_to at time zone v_zone)::date,(select booking_date from public.bookings where id=p_exclude_booking)])d where d is not null));
 v_facts:=private.service_resource_occupancy(p_branch,p_resource,p_from,p_to,p_exclude_booking,p_exclude_walk_in,true);
 if(v_facts->>'unclassified_active_count')::integer>0 or(v_facts->>'ambiguous_booking_count')::integer>0 or(v_facts->>'typed_active_missing_span_count')::integer>0 then raise exception 'Unclassified or ambiguous actual work requires management review'using errcode='55000';end if;
 if greatest((v_facts->>'admission_peak')::integer,(v_facts->>'physical_now')::integer)>=(v_facts->>'capacity')::integer then raise exception 'Physical/planned service capacity reached'using errcode='55000';end if;
 return v_facts;
end$$;
revoke all on function private.guard_service_resource_span(),private.lock_service_resource_days(uuid,text,date[]),private.service_resource_occupancy(uuid,text,timestamptz,timestamptz,uuid,uuid,boolean),private.assert_service_resource_start(uuid,text,timestamptz,timestamptz,uuid,uuid)from public,anon,authenticated,service_role;

-- Current LOCAL guard preserved except its overlap-count expression.
CREATE OR REPLACE FUNCTION private.enforce_booking_capacity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare b public.business_branches%rowtype;h public.business_branch_hours%rowtype;e public.business_branch_exceptions%rowtype;
 c public.business_catalog_items%rowtype;v_open time;v_close time;v_start timestamp;v_end timestamp;v_count integer;v_capacity integer;
begin
 if tg_op='UPDATE' and new.branch_id=old.branch_id and new.booking_date=old.booking_date and new.booking_time=old.booking_time and new.catalog_item_id is not distinct from old.catalog_item_id then return new;end if;
 if new.capacity_override_reason is not null and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can override capacity';end if;
 select * into strict b from public.business_branches where branch_id=new.branch_id for share;
 if not b.is_active or b.temporarily_closed then raise exception 'Branch is closed';end if;
 if new.catalog_item_id is not null then
  select * into c from public.business_catalog_items where item_id=new.catalog_item_id and branch_id=new.branch_id and item_type='service' and is_active and is_public;
  if not found then raise exception 'Service does not belong to selected branch';end if;
  new.duration_minutes:=c.duration_minutes;new.resource_key:=c.resource_key;
  if tg_op='INSERT' then new.quoted_price:=c.price;new.service_name:=c.name;new.vehicle_type:=c.vehicle_type;end if;
 end if;
 v_start:=new.booking_date+new.booking_time;v_end:=v_start+make_interval(mins=>new.duration_minutes);
 if v_start at time zone b.time_zone<=now() then raise exception 'Choose a future appointment';end if;
 select * into h from public.business_branch_hours where branch_id=new.branch_id and weekday=extract(dow from new.booking_date)::integer;
 if not found then raise exception 'Branch hours not configured';end if;
 v_open:=h.opens_at;v_close:=h.closes_at;
 select * into e from public.business_branch_exceptions where branch_id=new.branch_id and exception_date=new.booking_date;
 if found then if e.is_closed then raise exception 'Branch closed on this date';end if;v_open:=e.opens_at;v_close:=e.closes_at;
 elsif not h.is_open then raise exception 'Branch closed on this weekday';end if;
 if new.booking_time<v_open or v_end>new.booking_date+v_close then raise exception 'Appointment outside opening hours';end if;
 perform pg_advisory_xact_lock(hashtextextended(new.branch_id::text||new.booking_date::text||new.resource_key,0));
 select capacity into v_capacity from public.business_branch_resources where branch_id=new.branch_id and resource_key=new.resource_key;
 if v_capacity is null then raise exception 'Resource not configured';end if;
 -- Same admission mutex and existing guards; count shared typed intervals.
 v_count:=(private.service_resource_occupancy(new.branch_id,new.resource_key,v_start at time zone b.time_zone,v_end at time zone b.time_zone,new.id,null,false)->>'planned_peak')::integer;
 if v_count>=v_capacity and length(trim(coalesce(new.capacity_override_reason,'')))<5 then raise exception 'Branch capacity reached';end if;
 if new.vehicle_id is not null and exists(select 1 from public.bookings q where q.vehicle_id=new.vehicle_id and q.id is distinct from new.id and q.status not in ('cancelled','completed') and q.booking_date+q.booking_time<v_end and q.booking_date+q.booking_time+make_interval(mins=>q.duration_minutes)>v_start) then raise exception 'Vehicle already booked in this interval';end if;
 if v_count>=v_capacity then insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason) values(auth.uid()::text,auth.uid(),'capacity_override','bookings',new.id::text,new.branch_id,new.capacity_override_reason);end if;
 return new;end; $function$;
notify pgrst,'reload schema';
commit;
