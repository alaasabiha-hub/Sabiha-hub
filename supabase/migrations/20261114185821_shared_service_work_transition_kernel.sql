begin;
-- Actual work only; no queue UI, price/payment/commission rewrite or new loyalty eligibility.
create table private.service_work_commands(
 request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),order_id uuid references public.business_orders(order_id),branch_id uuid references public.business_branches(branch_id),
 payload jsonb not null,source_snapshot jsonb,state text not null check(state in('prepared','succeeded','closed')),result jsonb,created_at timestamptz not null default clock_timestamp(),resolved_at timestamptz,acknowledged_at timestamptz);
-- Closed tombstones fence their UUID without blocking resolution of a different own command.
create unique index one_open_service_work_command on private.service_work_commands(actor_id)where acknowledged_at is null and state in('prepared','succeeded');
create table private.service_work_ledger(
 event_id uuid primary key,command_id uuid references private.service_work_commands(request_id),actor_id uuid not null references public.staff_profiles(user_id),
 target_kind text not null check(target_kind in('booking','order')),booking_id uuid references public.bookings(id),order_id uuid references public.business_orders(order_id),
 expected_status text not null,next_status text not null,reason text not null,purpose text not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),
 check((target_kind='booking'and booking_id is not null and order_id is null)or(target_kind='order'and order_id is not null and booking_id is null)));
alter table private.service_work_commands enable row level security;alter table private.service_work_ledger enable row level security;
revoke all on private.service_work_commands,private.service_work_ledger from public,anon,authenticated,service_role;
create trigger immutable_service_work_ledger before update or delete on private.service_work_ledger for each row execute function private.immutable_loyalty_policy();
create function private.guard_service_work_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Work commands are retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['state','result','resolved_at','acknowledged_at'])is distinct from(to_jsonb(old)-array['state','result','resolved_at','acknowledged_at'])then raise exception 'Work command actor/source/payload is immutable'using errcode='55000';end if;
 if old.state='prepared'and new.state in('succeeded','closed')then
  if new.resolved_at is null or new.acknowledged_at is not null then raise exception 'Invalid work resolution'using errcode='55000';end if;
  if new.state='closed'and new.result is distinct from '{"status":"closed"}'::jsonb then raise exception 'Canonical close result required'using errcode='55000';end if;
  if new.state='succeeded'and(new.result->>'order_id'is distinct from new.order_id::text or new.result->>'performed_status'is distinct from new.payload->>'next_status')then raise exception 'Exact actual work result required'using errcode='55000';end if;
  if new.state='succeeded'and not exists(select 1 from private.service_work_ledger e where e.command_id=new.request_id and e.creator_xid=txid_current()and e.actor_id=new.actor_id and e.order_id=new.order_id)then raise exception 'Actual current work witness required'using errcode='55000';end if;
 elsif old.state=new.state and old.state in('succeeded','closed')and old.result is not distinct from new.result and old.resolved_at is not distinct from new.resolved_at then
  if old.acknowledged_at is not null and old.acknowledged_at is distinct from new.acknowledged_at then raise exception 'Acknowledgment cannot change'using errcode='55000';end if;
 else raise exception 'Resolved work command cannot reopen'using errcode='55000';end if;return new;
end$$;
create trigger guard_service_work_command before update or delete on private.service_work_commands for each row execute function private.guard_service_work_command();
create function private.service_work_authorized(p_order uuid,p_next text)returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid()is not null and exists(select 1 from public.business_orders o join public.staff_profiles a on a.user_id=auth.uid()and a.is_active where o.order_id=p_order and o.order_type='service'and private.can_access_branch(o.branch_id)and
 ((p_next='delivered'and a.role in('owner','manager'))or(p_next in('in_progress','quality_check','completed')and(a.role in('owner','manager')or auth.uid()=any(o.assigned_staff_ids)))));
$$;
create function private.check_booked_work_inspections(p_booking uuid)returns void language plpgsql security definer set search_path=pg_catalog as $$begin
 if exists(select 1 from public.bookings b join public.business_branches br on br.branch_id=b.branch_id where b.id=p_booking and br.inspection_required)and(select count(distinct phase)from public.vehicle_inspections where booking_id=p_booking and status='approved')<>2 then raise exception 'Approve actual before and after inspections before completing service'using errcode='55000';end if;
end$$;
create function private.service_source_resource(p_booking uuid,p_walk_in uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare v jsonb;begin
 if(p_booking is null)=(p_walk_in is null)then raise exception 'One actual service source required'using errcode='22023';end if;
 if p_booking is not null then select jsonb_build_object('branch',b.branch_id,'resource',b.resource_key,'duration',b.duration_minutes,'day',b.booking_date,'vehicle',b.vehicle_id,'car_ref',null)into v from public.bookings b where b.id=p_booking;
 else select jsonb_build_object('branch',s.branch_id,'resource',s.resource_key,'duration',s.duration_minutes,'day',null,'vehicle',null,'car_ref',s.car_ref_id)into v from private.offline_walk_in_subjects s where s.order_id=p_walk_in;end if;
 if v is null then raise exception 'Canonical resource source required'using errcode='55000';end if;return v;
end$$;
create function private.lock_service_source_resource(p_booking uuid,p_walk_in uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v jsonb;v_zone text;v_start_day date;v_today date;begin
 v:=private.service_source_resource(p_booking,p_walk_in);
 -- Own order/booking row is held by caller before these locks. Never lock foreign work rows.
 if v->>'vehicle'is not null then perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||(v->>'vehicle'),0));
 elsif v->>'car_ref'is not null then perform pg_advisory_xact_lock(hashtextextended('service-offline-car:'||(v->>'car_ref'),0));end if;
 select time_zone into v_zone from public.business_branches where branch_id=(v->>'branch')::uuid for share;
 v_today:=(clock_timestamp()at time zone v_zone)::date;
 select(started_at at time zone v_zone)::date into v_start_day from private.service_resource_spans where booking_id=p_booking or walk_in_order_id=p_walk_in;
 perform private.lock_service_resource_days((v->>'branch')::uuid,v->>'resource',array(select distinct d from unnest(array[v_today-1,v_today,v_today+1,(v->>'day')::date,v_start_day])d where d is not null));
 return v||jsonb_build_object('zone',v_zone,'today',v_today);
end$$;
create function private.admit_service_source(p_booking uuid,p_walk_in uuid,p_work_event uuid,p_already_active boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v jsonb;v_s private.service_resource_spans;v_b public.business_branches;v_h public.business_branch_hours;v_e public.business_branch_exceptions;v_now timestamptz;v_local timestamp;v_end timestamptz;v_open time;v_close time;v_event uuid;v_span uuid;v_facts jsonb;begin
 v:=private.lock_service_source_resource(p_booking,p_walk_in);v_now:=clock_timestamp();
 if abs((v_now at time zone(v->>'zone'))::date-(v->>'today')::date)>1 then raise exception 'Business day changed during admission; refresh'using errcode='55000';end if;
 select * into v_s from private.service_resource_spans where booking_id=p_booking or walk_in_order_id=p_walk_in;
 if found then
  if v_s.ended_at is not null then raise exception 'Certified service is finished; work cannot restart'using errcode='55000';end if;
  return jsonb_build_object('mode','existing_physical_span','span_id',v_s.span_id);
 end if;
 -- Existing active legacy booking work has an unknown original start. Do not fake one.
 if coalesce(p_already_active,false)and p_booking is not null then return jsonb_build_object('mode','observed_existing_booked_work','original_start_unknown',true);end if;
 select * into v_b from public.business_branches where branch_id=(v->>'branch')::uuid;
 v_local:=v_now at time zone(v->>'zone');v_end:=v_now+make_interval(mins=>(v->>'duration')::integer);
 if not v_b.is_active or v_b.temporarily_closed then raise exception 'Branch closed for new starts'using errcode='55000';end if;
 if p_booking is not null and(v->>'day')::date<>v_local::date then raise exception 'Actual booking start requires its service day; management review otherwise'using errcode='55000';end if;
 select * into v_h from public.business_branch_hours where branch_id=v_b.branch_id and weekday=extract(dow from v_local)::integer;
 if not found then raise exception 'Configured service hours required'using errcode='55000';end if;v_open:=v_h.opens_at;v_close:=v_h.closes_at;
 select * into v_e from public.business_branch_exceptions where branch_id=v_b.branch_id and exception_date=v_local::date;
 if found then if v_e.is_closed then raise exception 'Branch closed today'using errcode='55000';end if;v_open:=v_e.opens_at;v_close:=v_e.closes_at;
 elsif not v_h.is_open then raise exception 'Branch closed today'using errcode='55000';end if;
 if v_local::time<v_open or(v_end at time zone(v->>'zone'))>v_local::date+v_close then raise exception 'Actual service start outside configured hours'using errcode='55000';end if;
 if v->>'vehicle'is not null and exists(select 1 from public.bookings b where b.vehicle_id=(v->>'vehicle')::uuid and b.id is distinct from p_booking and(b.status='in_progress'or exists(select 1 from public.business_orders o where o.booking_id=b.id and o.status in('in_progress','quality_check'))or exists(select 1 from private.service_resource_spans s where s.booking_id=b.id and s.ended_at is null)))then raise exception 'Actual vehicle is already in service'using errcode='55000';end if;
 if v->>'car_ref'is not null and exists(select 1 from private.offline_walk_in_subjects s join public.business_orders o using(order_id)where s.car_ref_id=(v->>'car_ref')::uuid and s.order_id is distinct from p_walk_in and(o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans r where r.walk_in_order_id=s.order_id and r.ended_at is null)))then raise exception 'Actual intake car is already in service'using errcode='55000';end if;
 v_facts:=private.assert_service_resource_start(v_b.branch_id,v->>'resource',v_now,v_end,p_booking,p_walk_in);
 v_event:=gen_random_uuid();v_span:=gen_random_uuid();
 insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_event,p_work_event,auth.uid(),case when p_booking is not null then 'booking'else 'walk_in'end,p_booking,p_walk_in,'start',jsonb_build_object('work_event_id',p_work_event,'admission',v_facts),v_now,txid_current());
 insert into private.service_resource_spans(span_id,source_kind,booking_id,walk_in_order_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id)values(v_span,case when p_booking is not null then 'booking'else 'walk_in'end,p_booking,p_walk_in,v_b.branch_id,v->>'resource',(v->>'duration')::integer,v_now,v_end,v_event);
 return jsonb_build_object('mode','new_actual_admission','span_id',v_span,'admission',v_facts);
end$$;
create function private.complete_service_source(p_booking uuid,p_walk_in uuid,p_work_event uuid)returns void language plpgsql security definer set search_path=pg_catalog as $$
declare v jsonb;v_s private.service_resource_spans;v_event uuid:=gen_random_uuid();v_now timestamptz;v_command uuid;begin
 v:=private.lock_service_source_resource(p_booking,p_walk_in);v_now:=clock_timestamp();
 if abs((v_now at time zone(v->>'zone'))::date-(v->>'today')::date)>1 then raise exception 'Business day changed during release; refresh'using errcode='55000';end if;
 select * into v_s from private.service_resource_spans where booking_id=p_booking or walk_in_order_id=p_walk_in;
 if p_walk_in is not null and v_s.span_id is null then raise exception 'Walk-in completion requires its actual witnessed start'using errcode='55000';end if;
 if p_booking is not null then perform private.check_booked_work_inspections(p_booking);
 elsif exists(select 1 from public.business_branches where branch_id=(v->>'branch')::uuid and inspection_required)then raise exception 'Actual typed inspections required; no completion bypass'using errcode='55000';end if;
 if v_s.ended_at is not null then return;end if;
 select command_id into v_command from private.service_work_ledger where event_id=p_work_event;
 if v_s.span_id is null and v_command is not null and exists(select 1 from private.service_resource_events e where e.action='complete'and e.creator_xid=txid_current()and e.booking_id=p_booking and e.payload->>'command_id'=v_command::text)then return;end if;
 insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_event,p_work_event,auth.uid(),case when p_booking is not null then 'booking'else 'walk_in'end,p_booking,p_walk_in,'complete',jsonb_build_object('work_event_id',p_work_event,'command_id',v_command,'legacy_start_unknown',v_s.span_id is null),v_now,txid_current());
 if v_s.span_id is not null then update private.service_resource_spans set ended_at=v_now,end_event_id=v_event where span_id=v_s.span_id;end if;
end$$;
create function private.enforce_shared_service_work()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_o public.business_orders;v_b public.bookings;v_event private.service_work_ledger;v_count integer;v_booking uuid;v_walkin uuid;v_branch uuid;v_assigned boolean;v_command uuid;v_paired boolean;v_active boolean;v_dummy jsonb;v_role text;begin
 if new.status is not distinct from old.status then return new;end if;
 if tg_table_name='business_orders'then if new.order_type<>'service'then return new;end if;end if;
 if tg_table_name='bookings'then
  v_b:=old;v_booking:=old.id;v_branch:=old.branch_id;
  select count(*)into v_count from public.business_orders where booking_id=old.id and order_type='service';
  if v_count=1 then select * into v_o from public.business_orders where booking_id=old.id and order_type='service';end if;
  if new.status='cancelled'and(old.status='in_progress'or v_o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans where booking_id=old.id and ended_at is null))then raise exception 'Started service requires explicit management stop; cancellation cannot silently free occupancy'using errcode='55000';end if;
  if new.status not in('in_progress','completed')then return new;end if;
  if new.branch_id is distinct from old.branch_id or new.catalog_item_id is distinct from old.catalog_item_id or new.booking_date is distinct from old.booking_date or new.booking_time is distinct from old.booking_time or new.resource_key is distinct from old.resource_key or new.duration_minutes is distinct from old.duration_minutes or new.assigned_staff_ids is distinct from old.assigned_staff_ids then raise exception 'Dispatch/reschedule separately before actual work'using errcode='55000';end if;
  v_assigned:=auth.uid()=any(old.assigned_staff_ids)or auth.uid()=any(coalesce(v_o.assigned_staff_ids,'{}'::uuid[]));
 else
  v_o:=old;v_branch:=old.branch_id;v_booking:=old.booking_id;
  if exists(select 1 from private.offline_walk_in_subjects where order_id=old.order_id)then v_walkin:=old.order_id;end if;
  if new.status='cancelled'and old.status in('in_progress','quality_check')then raise exception 'Started service requires explicit management stop'using errcode='55000';end if;
  if new.status not in('in_progress','quality_check','completed','delivered')then return new;end if;
  if new.branch_id is distinct from old.branch_id or new.booking_id is distinct from old.booking_id or new.assigned_staff_ids is distinct from old.assigned_staff_ids then raise exception 'Dispatch/source changes must precede actual work'using errcode='55000';end if;
  if v_booking is not null then select * into v_b from public.bookings where id=v_booking;select count(*)into v_count from public.business_orders where booking_id=v_booking and order_type='service';end if;
  v_assigned:=auth.uid()=any(old.assigned_staff_ids);
 end if;
 select role into v_role from public.staff_profiles where user_id=auth.uid()and is_active for share;
 if not found or auth.uid()is null or not coalesce(private.can_access_branch(v_branch),false)or(new.status='delivered'and v_role not in('owner','manager'))or(new.status<>'delivered'and v_role not in('owner','manager')and not coalesce(v_assigned,false))then raise exception 'Assigned active worker or scoped management required; management delivers'using errcode='42501';end if;
 if v_booking is not null and v_o.order_id is not null and v_o.branch_id is distinct from v_b.branch_id then raise exception 'Paired service branch mismatch'using errcode='55000';end if;
 if v_booking is not null and v_count>1 then raise exception 'Ambiguous paired service orders require management reconciliation'using errcode='55000';end if;
 if tg_table_name='bookings'then select * into v_event from private.service_work_ledger where booking_id=old.id and target_kind='booking'and expected_status=old.status and next_status=new.status and creator_xid=txid_current()and actor_id=auth.uid()order by created_at desc limit 1;
 else select * into v_event from private.service_work_ledger where order_id=old.order_id and target_kind='order'and expected_status=old.status and next_status=new.status and creator_xid=txid_current()and actor_id=auth.uid()order by created_at desc limit 1;end if;
 if v_walkin is not null and v_event.event_id is null then raise exception 'Use exact durable work command for typed walk-in progress'using errcode='55000';end if;
 if v_event.event_id is null then
  v_event.event_id:=gen_random_uuid();v_event.actor_id:=auth.uid();v_event.expected_status:=old.status;v_event.next_status:=new.status;v_event.reason:='Direct authorized legacy service progress';v_event.creator_xid:=txid_current();
  if tg_table_name='bookings'then
   insert into private.service_work_ledger(event_id,actor_id,target_kind,booking_id,expected_status,next_status,reason,purpose,creator_xid)values(v_event.event_id,auth.uid(),'booking',old.id,old.status,new.status,v_event.reason,'legacy_direct_authorized_progress',txid_current());
  else
   insert into private.service_work_ledger(event_id,actor_id,target_kind,order_id,expected_status,next_status,reason,purpose,creator_xid)values(v_event.event_id,auth.uid(),'order',old.order_id,old.status,new.status,v_event.reason,'legacy_direct_authorized_progress',txid_current());
  end if;
 end if;
 v_command:=v_event.command_id;
 if v_booking is null and v_walkin is null then
  if new.status='in_progress'and old.status='received'then raise exception 'Actual resource binding required before legacy work starts'using errcode='55000';end if;
  -- Existing unclassified active work may finish through its original guarded graph.
  return new;
 end if;
 if new.status='in_progress'then
  if tg_table_name='business_orders'and v_booking is not null and v_b.status<>'in_progress'then raise exception 'Start the actual booking first, or use canonical paired work command'using errcode='55000';end if;
  v_active:=case when tg_table_name='bookings'then v_o.status in('in_progress','quality_check')else v_b.status='in_progress'end;
  v_dummy:=private.admit_service_source(v_booking,v_walkin,v_event.event_id,coalesce(v_active,false));
 elsif new.status='quality_check'then
  v_dummy:=private.lock_service_source_resource(v_booking,v_walkin);
  if v_walkin is not null and not exists(select 1 from private.service_resource_spans where walk_in_order_id=v_walkin and ended_at is null)then raise exception 'Actual open physical start required for quality check'using errcode='55000';end if;
 elsif new.status='completed'then
  if v_booking is not null then
   perform private.check_booked_work_inspections(v_booking);
   if tg_table_name='bookings'then
    v_paired:=v_count=0 or v_o.status in('completed','delivered')or(v_command is not null and exists(select 1 from private.service_work_ledger e where e.command_id=v_command and e.target_kind='order'and e.order_id=v_o.order_id and e.expected_status='quality_check'and e.next_status='completed'and e.actor_id=auth.uid()and e.creator_xid=txid_current()));
   else
    v_paired:=v_b.status='completed'or(v_command is not null and exists(select 1 from private.service_work_ledger e where e.command_id=v_command and e.target_kind='booking'and e.booking_id=v_booking and e.expected_status='in_progress'and e.next_status='completed'and e.actor_id=auth.uid()and e.creator_xid=txid_current()));
   end if;
   if not coalesce(v_paired,false)then raise exception 'Complete real quality-checked paired order and booking atomically through work command'using errcode='55000';end if;
  end if;
  perform private.complete_service_source(v_booking,v_walkin,v_event.event_id);
 elsif new.status='delivered'then
  if v_booking is not null and v_b.status<>'completed'then raise exception 'Paired service must be coherently completed before delivery'using errcode='55000';end if;
  if exists(select 1 from private.service_resource_spans where(booking_id=v_booking or walk_in_order_id=v_walkin)and ended_at is null)then raise exception 'Actual physical service is still open'using errcode='55000';end if;
 end if;
 return new;
end$$;
create trigger shared_service_work_guard before update of status on public.bookings for each row execute function private.enforce_shared_service_work();
create trigger shared_service_work_guard before update of status on public.business_orders for each row execute function private.enforce_shared_service_work();

-- Only typed status witness predicate changes; issued finance/commission guards preserved.
CREATE OR REPLACE FUNCTION private.guard_offline_walk_in_finance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_s private.offline_walk_in_subjects;v_total numeric;v_share numeric;v_rates integer;v_ids uuid[];v_workers jsonb;begin
 if tg_op='DELETE'then
  if tg_table_name='business_orders'then
   if exists(select 1 from private.offline_walk_in_subjects where order_id=old.order_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  else
   if exists(select 1 from private.offline_walk_in_subjects where invoice_id=old.invoice_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  end if;return old;
 end if;
 if tg_table_name='business_orders'then
  select * into v_s from private.offline_walk_in_subjects where order_id=new.order_id;
  if not found then return new;end if;
  if new.customer_id is not null or new.booking_id is not null or new.order_type<>'service'or new.branch_id<>v_s.branch_id or new.assigned_staff_ids<>v_s.staff_ids then raise exception 'Typed offline subject/assignment mismatch'using errcode='55000';end if;
  if tg_op='INSERT'then
   if new.status<>'received'or v_s.creator_xid<>txid_current()then raise exception 'Only canonical received creation supported'using errcode='55000';end if;
  else
   if new.order_number is distinct from old.order_number and not(v_s.creator_xid=txid_current()and old.order_number=v_s.invoice_id and new.order_number=(select display_number from public.business_invoices where invoice_id=v_s.invoice_id))then raise exception 'Issued work reference is immutable'using errcode='55000';end if;
   if(to_jsonb(new)-array['status','updated_at','order_number'])is distinct from(to_jsonb(old)-array['status','updated_at','order_number'])then raise exception 'Issued walk-in identity and assignment are immutable'using errcode='55000';end if;
   if new.status is distinct from old.status and not((old.status='received'and new.status='cancelled'and exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=new.order_id::text))or exists(select 1 from private.service_work_ledger e where e.target_kind='order'and e.order_id=new.order_id and e.expected_status=old.status and e.next_status=new.status and e.creator_xid=txid_current()and e.actor_id=auth.uid()and e.command_id is not null))then raise exception 'Exact authorized work witness required'using errcode='55000';end if;
  end if;return new;
 end if;
 select * into v_s from private.offline_walk_in_subjects where invoice_id=new.invoice_id;
 if not found then
  if exists(select 1 from private.offline_walk_in_subjects where order_id=new.order_id)then raise exception 'Typed work already has its canonical invoice'using errcode='55000';end if;
  if new.commission_model<>'legacy_scalar'or new.commission_share is null then raise exception 'Typed commission requires canonical sidecar proof'using errcode='55000';end if;return new;
 end if;
 select sum(c.amount),case when count(distinct c.rate_percent)=1 then min(c.amount)end,count(distinct c.rate_percent),array_agg(c.staff_id order by c.staff_id),jsonb_agg(c.staff_name order by c.staff_id)
 into v_total,v_share,v_rates,v_ids,v_workers from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id;
 if new.commission_model<>'walk_in_frozen_workers'or new.order_id is distinct from v_s.order_id or new.branch_id<>v_s.branch_id or new.total<>v_s.gross or new.discount<>0 or new.sale_type<>'service'or new.reward_snapshot is not null or new.commission_total is distinct from v_total or new.commission_share is distinct from v_share or v_ids is distinct from v_s.staff_ids or new.workers is distinct from v_workers or exists(select 1 from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id and(c.gross<>v_s.gross or c.assigned_count<>cardinality(v_s.staff_ids)))then raise exception 'Complete truthful frozen worker commission proof required'using errcode='55000';end if;
 if tg_op='INSERT'and v_s.creator_xid<>txid_current()then raise exception 'Invoice must be issued with new canonical proof'using errcode='55000';end if;
 if tg_op='UPDATE'then
  if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued walk-in finance and commission facts are immutable'using errcode='55000';end if;
  if new.status='void'and old.status<>'void'and not exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=v_s.order_id::text)then raise exception 'Use canonical unpaid cancellation'using errcode='55000';end if;
 end if;return new;
end$function$;
create function private.service_work_reference(p_order uuid)returns text language sql stable security definer set search_path=pg_catalog as $$
 select coalesce((select min(i.display_number)from public.business_invoices i where i.order_id=o.order_id and i.display_number is not null having count(*)=1),b.display_number,case when o.order_number~'^SH-[A-Z]+-[0-9]+$'then o.order_number else 'SH-'||upper(left(replace(o.order_id::text,'-',''),8))end)from public.business_orders o left join public.bookings b on b.id=o.booking_id where o.order_id=p_order;
$$;
revoke all on function private.service_work_reference(uuid)from public,anon,authenticated,service_role;
-- Client INSERT cannot manufacture active/completed work to evade UPDATE admission.
-- Invoker context intentionally distinguishes real server migration/service-role writes.
create function private.guard_service_work_insert()returns trigger language plpgsql security invoker set search_path=pg_catalog as $$begin
 if auth.uid()is null then
  if current_user in('postgres','supabase_admin','service_role')and coalesce(auth.role(),'')not in('anon','authenticated')then return new;end if;
  raise exception 'Identified client or explicit trusted historical server context required'using errcode='42501';
 end if;
 if tg_table_name='bookings'then
  if new.status not in('pending','confirmed')then raise exception 'Client bookings begin pending/confirmed; active work requires guarded transition'using errcode='55000';end if;
 else
  if new.order_type='service'and new.status<>'received'then raise exception 'Client service orders begin received; active work requires guarded transition'using errcode='55000';end if;
 end if;return new;
end$$;
revoke all on function private.guard_service_work_insert()from public,anon,authenticated,service_role;
create trigger guard_service_work_insert before insert on public.bookings for each row execute function private.guard_service_work_insert();
create trigger guard_service_work_insert before insert on public.business_orders for each row execute function private.guard_service_work_insert();
create function private.get_service_work_command(p_request uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.service_work_commands;v_result jsonb;v_o public.business_orders;v_b public.bookings;begin
 if auth.uid()is null or private.active_staff_role()is null then raise exception 'Active staff required'using errcode='42501';end if;
 if p_request is null then select * into v_c from private.service_work_commands where actor_id=auth.uid()and acknowledged_at is null order by case when state in('prepared','succeeded')then 0 else 1 end,created_at desc limit 1;
 else select * into v_c from private.service_work_commands where request_id=p_request;end if;
 if v_c.request_id is null then return jsonb_build_object('status','absent','definitive_failure',false);end if;
 if v_c.actor_id<>auth.uid()then raise exception 'Own active staff work receipt required'using errcode='42501';end if;
 v_result:=v_c.result;
 if v_c.order_id is not null and v_c.state<>'closed'and coalesce(private.service_work_authorized(v_c.order_id,v_c.payload->>'next_status'),false)then
  select * into v_o from public.business_orders where order_id=v_c.order_id;select * into v_b from public.bookings where id=v_o.booking_id;
  v_result:=coalesce(v_result,'{}')||jsonb_build_object('order_id',v_o.order_id,'work_reference',private.service_work_reference(v_o.order_id),'current_work_status',v_o.status,'current_booking_status',v_b.status,'current_state_available',true,'physical_open',exists(select 1 from private.service_resource_spans where(walk_in_order_id=v_o.order_id or booking_id=v_o.booking_id)and ended_at is null));
 else v_result:=coalesce(v_result,'{}')||jsonb_build_object('current_state_available',false);
 end if;
 return jsonb_build_object('request_id',v_c.request_id,'status',v_c.state,'payload',v_c.payload,'result',v_result,'acknowledged',v_c.acknowledged_at is not null,'loyalty_walk_in_enabled',false,'eta_official_invoice',false);
end$$;
create function private.prepare_service_work(p_request uuid,p_order uuid,p_expected_status text,p_next_status text,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.service_work_commands;v_o public.business_orders;v_payload jsonb;begin
 if not coalesce(private.service_work_authorized(p_order,p_next_status),false)then raise exception 'Assigned active worker or scoped management required; management delivers'using errcode='42501';end if;
 if p_request is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 or not coalesce((p_expected_status='received'and p_next_status='in_progress')or(p_expected_status='in_progress'and p_next_status='quality_check')or(p_expected_status='quality_check'and p_next_status='completed')or(p_expected_status='completed'and p_next_status='delivered'),false)then raise exception 'Exact supported work transition and reason required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Work commands require READ COMMITTED'using errcode='55000';end if;perform set_config('lock_timeout','20s',true);
 v_payload:=jsonb_build_object('order_id',p_order,'expected_status',p_expected_status,'next_status',p_next_status,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('service-work-actor:'||auth.uid()::text,0));
 select * into v_c from private.service_work_commands where request_id=p_request;
 if found then
  if v_c.actor_id<>auth.uid()then raise exception 'Work command unavailable'using errcode='42501';end if;
  if v_c.payload<>v_payload then raise exception 'Work command payload changed'using errcode='22023';end if;return private.get_service_work_command(p_request);
 end if;
 select * into v_o from public.business_orders where order_id=p_order for share;
 if v_o.status<>p_expected_status then raise exception 'Work state changed; refresh before preparation'using errcode='40001';end if;
 if v_o.booking_id is null and not exists(select 1 from private.offline_walk_in_subjects where order_id=p_order)then raise exception 'Canonical booking or typed walk-in source required'using errcode='55000';end if;
 if v_o.booking_id is not null and(select count(*)from public.business_orders where booking_id=v_o.booking_id and order_type='service')<>1 then raise exception 'Ambiguous paired orders require management review'using errcode='55000';end if;
 insert into private.service_work_commands(request_id,actor_id,order_id,branch_id,payload,source_snapshot,state)values(p_request,auth.uid(),p_order,v_o.branch_id,v_payload,jsonb_build_object('branch_id',v_o.branch_id,'booking_id',v_o.booking_id,'staff_ids',to_jsonb(v_o.assigned_staff_ids)),'prepared');return private.get_service_work_command(p_request);
end$$;
create function private.place_service_work(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.service_work_commands;v_o public.business_orders;v_b public.bookings;v_event uuid:=gen_random_uuid();v_booking_event uuid;v_next text;v_expected text;v_result jsonb;begin
 if auth.uid()is null or private.active_staff_role()is null then raise exception 'Active staff required'using errcode='42501';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Work commands require READ COMMITTED'using errcode='55000';end if;perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));select * into v_c from private.service_work_commands where request_id=p_request;
 if not found or v_c.actor_id<>auth.uid()or not coalesce(private.service_work_authorized(v_c.order_id,v_c.payload->>'next_status'),false)then raise exception 'Own current authorized work command required'using errcode='42501';end if;
 if v_c.state='succeeded'then return private.get_service_work_command(p_request);end if;
 if v_c.state<>'prepared'then raise exception 'Closed command fences delayed work execution'using errcode='55000';end if;
 select * into v_o from public.business_orders where order_id=v_c.order_id;
 -- Canonical APIs take the pair mutex before BOTH rows. Legacy row triggers never lock foreign rows.
 if v_o.booking_id is not null then perform pg_advisory_xact_lock(hashtextextended('service-work-pair:'||v_o.booking_id::text,0));end if;
 select * into v_o from public.business_orders where order_id=v_c.order_id for update;
 if jsonb_build_object('branch_id',v_o.branch_id,'booking_id',v_o.booking_id,'staff_ids',to_jsonb(v_o.assigned_staff_ids))is distinct from v_c.source_snapshot then raise exception 'Actual source/dispatch changed; close command and refresh'using errcode='40001';end if;
 if v_o.booking_id is not null then select * into strict v_b from public.bookings where id=v_o.booking_id for update;end if;
 v_next:=v_c.payload->>'next_status';v_expected:=v_c.payload->>'expected_status';
 if v_o.status<>v_expected then raise exception 'Actual work state changed; close command and refresh'using errcode='40001';end if;
 if not coalesce(private.service_work_authorized(v_o.order_id,v_next),false)then raise exception 'Current assignment required'using errcode='42501';end if;
 if v_o.booking_id is not null then
  if(select count(*)from public.business_orders where booking_id=v_o.booking_id and order_type='service')<>1 or v_o.branch_id<>v_b.branch_id then raise exception 'Unambiguous same-branch paired service required'using errcode='55000';end if;
  if v_next='in_progress'and v_b.status not in('confirmed','in_progress')then raise exception 'Actual confirmed booking required; approval cannot be bypassed'using errcode='55000';end if;
  if v_next in('quality_check','completed')and v_b.status<>'in_progress'then raise exception 'Actual paired booking must be in progress; reconcile explicitly'using errcode='55000';end if;
  if v_next='delivered'and v_b.status<>'completed'then raise exception 'Actual paired booking must be completed'using errcode='55000';end if;
  if v_next='completed'then perform private.check_booked_work_inspections(v_b.id);end if;
 end if;
 insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,order_id,expected_status,next_status,reason,purpose,creator_xid)values(v_event,p_request,auth.uid(),'order',v_o.order_id,v_o.status,v_next,v_c.payload->>'reason',case when auth.uid()=any(v_o.assigned_staff_ids)then 'canonical_assigned_work'else 'canonical_management_certification'end,txid_current());
 if v_o.booking_id is not null and((v_next='in_progress'and v_b.status='confirmed')or v_next='completed')then
  v_booking_event:=gen_random_uuid();insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,booking_id,expected_status,next_status,reason,purpose,creator_xid)values(v_booking_event,p_request,auth.uid(),'booking',v_b.id,v_b.status,case when v_next='completed'then 'completed'else 'in_progress'end,v_c.payload->>'reason','canonical_paired_work_command',txid_current());
 end if;
 if v_booking_event is not null and v_next='in_progress'then update public.bookings set status='in_progress'where id=v_b.id;end if;
 update public.business_orders set status=v_next where order_id=v_o.order_id;
 if v_booking_event is not null and v_next='completed'then update public.bookings set status='completed'where id=v_b.id;end if;
 v_result:=jsonb_build_object('order_id',v_o.order_id,'work_reference',private.service_work_reference(v_o.order_id),'booking_id',v_o.booking_id,'performed_status',v_next,'work_event_id',v_event,'paired_event_id',v_booking_event);
 update private.service_work_commands set state='succeeded',result=v_result,resolved_at=clock_timestamp()where request_id=p_request;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data)values(auth.uid()::text,auth.uid(),'canonical_service_work','business_orders',v_o.order_id::text,v_o.branch_id,v_c.payload->>'reason',jsonb_build_object('status',v_o.status,'booking_status',v_b.status),v_result);
 return private.get_service_work_command(p_request);
end$$;
create function private.close_service_work_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.service_work_commands;begin
 if auth.uid()is null or private.active_staff_role()is null then raise exception 'Active staff required'using errcode='42501';end if;
 if p_request is null then raise exception 'Stable work request required'using errcode='22023';end if;perform set_config('lock_timeout','20s',true);perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));select * into v_c from private.service_work_commands where request_id=p_request;
 if not found then insert into private.service_work_commands(request_id,actor_id,payload,state,result,resolved_at)values(p_request,auth.uid(),'{}','closed','{"status":"closed"}',clock_timestamp());
 elsif v_c.actor_id<>auth.uid()then raise exception 'Own active staff work receipt required'using errcode='42501';
 elsif v_c.state='prepared'then update private.service_work_commands set state='closed',result='{"status":"closed"}',resolved_at=clock_timestamp()where request_id=p_request;end if;
 return private.get_service_work_command(p_request);
end$$;
create function private.ack_service_work_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.service_work_commands;begin
 if auth.uid()is null or private.active_staff_role()is null then raise exception 'Active staff required'using errcode='42501';end if;
 perform set_config('lock_timeout','20s',true);perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));select * into v_c from private.service_work_commands where request_id=p_request;
 if not found or v_c.actor_id<>auth.uid()then raise exception 'Own active staff work receipt required'using errcode='42501';end if;
 if v_c.state='prepared'then raise exception 'Cannot acknowledge unresolved work'using errcode='55000';end if;
 update private.service_work_commands set acknowledged_at=coalesce(acknowledged_at,clock_timestamp())where request_id=p_request;return private.get_service_work_command(p_request);
end$$;

revoke all on function private.guard_service_work_command(),private.service_work_authorized(uuid,text),private.check_booked_work_inspections(uuid),private.service_source_resource(uuid,uuid),private.lock_service_source_resource(uuid,uuid),private.admit_service_source(uuid,uuid,uuid,boolean),private.complete_service_source(uuid,uuid,uuid),private.enforce_shared_service_work()from public,anon,authenticated,service_role;
create function public.prepare_service_work(p_request uuid,p_order uuid,p_expected_status text,p_next_status text,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_service_work(p_request,p_order,p_expected_status,p_next_status,p_reason)$$;
revoke all on function private.prepare_service_work(uuid,uuid,text,text,text),public.prepare_service_work(uuid,uuid,text,text,text)from public,anon,service_role;
grant execute on function private.prepare_service_work(uuid,uuid,text,text,text),public.prepare_service_work(uuid,uuid,text,text,text)to authenticated;
create function public.place_service_work(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.place_service_work(p_request)$$;
revoke all on function private.place_service_work(uuid),public.place_service_work(uuid)from public,anon,service_role;
grant execute on function private.place_service_work(uuid),public.place_service_work(uuid)to authenticated;
create function public.get_service_work_command(p_request uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_service_work_command(p_request)$$;
revoke all on function private.get_service_work_command(uuid),public.get_service_work_command(uuid)from public,anon,service_role;
grant execute on function private.get_service_work_command(uuid),public.get_service_work_command(uuid)to authenticated;
create function public.close_service_work_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_service_work_command(p_request)$$;
revoke all on function private.close_service_work_command(uuid),public.close_service_work_command(uuid)from public,anon,service_role;
grant execute on function private.close_service_work_command(uuid),public.close_service_work_command(uuid)to authenticated;
create function public.ack_service_work_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.ack_service_work_command(p_request)$$;
revoke all on function private.ack_service_work_command(uuid),public.ack_service_work_command(uuid)from public,anon,service_role;
grant execute on function private.ack_service_work_command(uuid),public.ack_service_work_command(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
