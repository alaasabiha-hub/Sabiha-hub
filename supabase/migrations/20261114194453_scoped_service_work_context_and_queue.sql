begin;
-- Follow-up to kernel185821. Read-only operational UI context; no money/identity/crew rewriting.
do $$begin if to_regclass('private.service_work_commands')is null then raise exception 'Install reviewed work kernel before its UI adapter'using errcode='55000';end if;end$$;
create or replace function private.service_work_authorized(p_order uuid,p_next text)returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid()is not null and exists(select 1 from public.business_orders o join public.staff_profiles a on a.user_id=auth.uid()and a.is_active
 left join public.bookings b on b.id=o.booking_id where o.order_id=p_order and o.order_type='service'and private.can_access_branch(o.branch_id)
 and(o.booking_id is null or(b.branch_id=o.branch_id and(select count(*)from public.business_orders pair where pair.booking_id=b.id and pair.order_type='service')=1))
 and((p_next='delivered'and a.role in('owner','manager'))or(p_next in('in_progress','quality_check','completed')and(a.role in('owner','manager')or auth.uid()=any(o.assigned_staff_ids)or(o.booking_id is not null and auth.uid()=any(b.assigned_staff_ids))))));
$$;
create function private.service_work_source_snapshot(p_order uuid)returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('version',2,'branch_id',o.branch_id,'booking_id',o.booking_id,'staff_ids',to_jsonb(o.assigned_staff_ids),'booking',case when b.id is not null then jsonb_build_object('branch_id',b.branch_id,'catalog_item_id',b.catalog_item_id,'staff_ids',to_jsonb(b.assigned_staff_ids),'resource_key',b.resource_key,'duration_minutes',b.duration_minutes,'booking_date',b.booking_date,'booking_time',b.booking_time)end)
 from public.business_orders o left join public.bookings b on b.id=o.booking_id where o.order_id=p_order;
$$;
revoke all on function private.service_work_authorized(uuid,text),private.service_work_source_snapshot(uuid)from public,anon,authenticated,service_role;

-- Actual booking-assigned employee is an existing same-source worker, not a payroll reassignment.
create or replace function private.enforce_shared_service_work()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
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
  v_assigned:=auth.uid()=any(old.assigned_staff_ids)or(v_booking is not null and v_b.branch_id=old.branch_id and v_count=1 and auth.uid()=any(v_b.assigned_staff_ids));
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

create or replace function private.prepare_service_work(p_request uuid,p_order uuid,p_expected_status text,p_next_status text,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
 insert into private.service_work_commands(request_id,actor_id,order_id,branch_id,payload,source_snapshot,state)values(p_request,auth.uid(),p_order,v_o.branch_id,v_payload,private.service_work_source_snapshot(v_o.order_id),'prepared');return private.get_service_work_command(p_request);
end$$;

-- Revalidate authoritative booking dispatch/resource after BOTH source rows are locked.
create or replace function private.place_service_work(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
 if v_c.source_snapshot->>'version'is distinct from'2'or v_o.branch_id::text is distinct from v_c.source_snapshot->>'branch_id'or v_o.booking_id::text is distinct from v_c.source_snapshot->>'booking_id'then raise exception 'Stale source snapshot; close command and refresh'using errcode='40001';end if;
 if v_o.booking_id is not null then select * into strict v_b from public.bookings where id=v_o.booking_id for update;end if;
 if private.service_work_source_snapshot(v_o.order_id)is distinct from v_c.source_snapshot then raise exception 'Actual order/booking dispatch or frozen resource changed; close command and refresh'using errcode='40001';end if;
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
create function private.get_service_work_context(p_order uuid default null,p_booking uuid default null)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare v_role text:=private.active_staff_role();v_o public.business_orders;v_b public.bookings;v_br public.business_branches;v_s private.offline_walk_in_subjects;v_span private.service_resource_spans;v_kind text;v_next text;v_n integer;v_blockers text[]:=array[]::text[];v_can boolean;v_ready boolean;v_resource text;v_duration integer;v_occupancy jsonb;v_now timestamptz:=clock_timestamp();v_local timestamp;v_open time;v_close time;v_h public.business_branch_hours;v_e public.business_branch_exceptions;v_arrival timestamptz;v_priority text;v_plate text;v_crew jsonb;v_physical boolean;v_continuation boolean;
begin
 if auth.uid()is null or v_role is null or v_role not in('owner','manager','employee')then raise exception 'Active scoped service staff required'using errcode='42501';end if;
 if num_nonnulls(p_order,p_booking)<>1 then raise exception 'One actual order or booking reference required'using errcode='22023';end if;
 if p_booking is not null then
  select * into v_b from public.bookings where id=p_booking;
  if not found or not coalesce(private.can_access_branch(v_b.branch_id),false)or(v_role='employee'and not(auth.uid()=any(v_b.assigned_staff_ids)or exists(select 1 from public.business_orders o where o.booking_id=v_b.id and o.order_type='service'and o.branch_id=v_b.branch_id and auth.uid()=any(o.assigned_staff_ids))))then raise exception 'Service context unavailable'using errcode='42501';end if;
  select count(*)into v_n from public.business_orders where booking_id=v_b.id and order_type='service';
  if v_n=0 then return jsonb_build_object('source_kind','unpaired_booking','booking_id',v_b.id,'booking_status',v_b.status,'work_reference',coalesce(v_b.display_number,'SH-'||upper(left(replace(v_b.id::text,'-',''),8))),'canonical_work_supported',false,'legacy_unpaired_booking',true,'can_prepare',false,'blockers',jsonb_build_array('unpaired_booking_uses_existing_route'));end if;
  if v_n<>1 then raise exception 'Ambiguous actual paired service requires management review'using errcode='55000';end if;
  select * into v_o from public.business_orders where booking_id=v_b.id and order_type='service';
 else
  select * into v_o from public.business_orders where order_id=p_order and order_type='service';
  if not found then raise exception 'Service context unavailable'using errcode='42501';end if;
  if v_o.booking_id is not null then select * into v_b from public.bookings where id=v_o.booking_id;end if;
 end if;
 if not coalesce(private.can_access_branch(v_o.branch_id),false)or(v_role='employee'and not(auth.uid()=any(v_o.assigned_staff_ids)or(v_b.id is not null and v_b.branch_id=v_o.branch_id and auth.uid()=any(v_b.assigned_staff_ids))))then raise exception 'Service context unavailable'using errcode='42501';end if;
 if v_o.booking_id is not null and(v_b.branch_id is distinct from v_o.branch_id or(select count(*)from public.business_orders where booking_id=v_b.id and order_type='service')<>1)then raise exception 'Unambiguous same-branch service required'using errcode='55000';end if;
 select * into strict v_br from public.business_branches where branch_id=v_o.branch_id;
 select * into v_s from private.offline_walk_in_subjects where order_id=v_o.order_id;
 v_kind:=case when v_s.order_id is not null then 'walk_in'when v_b.id is not null then 'booking'else 'legacy_order'end;
 if v_kind='walk_in'then v_resource:=v_s.resource_key;v_duration:=v_s.duration_minutes;select arrived_at,priority into v_arrival,v_priority from private.offline_walk_in_reception where order_id=v_o.order_id;
 elsif v_kind='booking'then v_resource:=v_b.resource_key;v_duration:=v_b.duration_minutes;select arrived_at,priority into v_arrival,v_priority from private.wash_reception_entries where booking_id=v_b.id and branch_id=v_o.branch_id;end if;
 v_plate:=v_o.plate_number;if v_plate is null and v_b.vehicle_id is not null then select plate_number into v_plate from public.vehicles where id=v_b.vehicle_id and customer_id=v_b.customer_id;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',s.user_id,'name',s.full_name,'active',s.is_active)order by s.full_name,s.user_id),'[]')into v_crew from public.staff_profiles s where s.user_id=any(v_o.assigned_staff_ids)or s.user_id=any(coalesce(v_b.assigned_staff_ids,'{}'::uuid[]));
 select * into v_span from private.service_resource_spans where walk_in_order_id=v_o.order_id or booking_id=v_b.id;
 v_physical:=v_span.span_id is not null and v_span.ended_at is null or v_o.status in('in_progress','quality_check')or v_b.status='in_progress';
 v_continuation:=v_span.span_id is not null and v_span.ended_at is null or v_b.status='in_progress';
 v_next:=case v_o.status when 'received'then 'in_progress'when 'in_progress'then 'quality_check'when 'quality_check'then 'completed'when 'completed'then 'delivered'end;
 v_ready:=to_regprocedure('public.place_service_work(uuid)')is not null and to_regclass('private.service_work_commands')is not null;
 if not v_ready then v_blockers:=array_append(v_blockers,'work_kernel_unavailable');end if;
 if v_kind='legacy_order'then v_blockers:=array_append(v_blockers,'legacy_resource_binding_required');end if;
 if v_kind='booking'and((v_next='in_progress'and v_b.status not in('confirmed','in_progress'))or(v_next in('quality_check','completed')and v_b.status<>'in_progress')or(v_next='delivered'and v_b.status<>'completed'))then v_blockers:=array_append(v_blockers,'booking_state_requires_review');end if;
 if v_next is null then v_blockers:=array_append(v_blockers,'no_next_work_action');end if;
 if v_next is not null and not coalesce(private.service_work_authorized(v_o.order_id,v_next),false)then v_blockers:=array_append(v_blockers,'current_work_permission_required');end if;
 if v_resource is not null and v_duration is not null then
  begin v_occupancy:=private.service_resource_occupancy(v_o.branch_id,v_resource,v_now,v_now+make_interval(mins=>v_duration),v_b.id,case when v_kind='walk_in'then v_o.order_id end,true);
  exception when sqlstate'55000'or sqlstate'22023'then v_blockers:=array_append(v_blockers,'resource_not_configured');end;
 end if;
 if v_next='in_progress'and not coalesce(v_continuation,false)then
  if not v_br.is_active or v_br.temporarily_closed then v_blockers:=array_append(v_blockers,'branch_closed_for_start');end if;
  v_local:=v_now at time zone v_br.time_zone;
  if v_kind='booking'and v_b.booking_date<>v_local::date then v_blockers:=array_append(v_blockers,'booking_service_day_required');end if;
  select * into v_h from public.business_branch_hours where branch_id=v_br.branch_id and weekday=extract(dow from v_local)::integer;v_open:=v_h.opens_at;v_close:=v_h.closes_at;
  select * into v_e from public.business_branch_exceptions where branch_id=v_br.branch_id and exception_date=v_local::date;
  if v_e.branch_id is not null then if v_e.is_closed then v_blockers:=array_append(v_blockers,'branch_closed_for_start');end if;v_open:=v_e.opens_at;v_close:=v_e.closes_at;
  elsif v_h.branch_id is null or not v_h.is_open then v_blockers:=array_append(v_blockers,'service_hours_not_open');end if;
  if v_open is null or v_close is null or v_local::time<v_open or v_local+make_interval(mins=>coalesce(v_duration,0))>v_local::date+v_close then v_blockers:=array_append(v_blockers,'service_hours_not_open');end if;
  if v_occupancy is not null then
   if greatest((v_occupancy->>'admission_peak')::integer,(v_occupancy->>'physical_now')::integer)>=(v_occupancy->>'capacity')::integer then v_blockers:=array_append(v_blockers,'capacity_recheck_required');end if;
   if(v_occupancy->>'unclassified_active_count')::integer>0 or(v_occupancy->>'ambiguous_booking_count')::integer>0 or(v_occupancy->>'typed_active_missing_span_count')::integer>0 then v_blockers:=array_append(v_blockers,'unclassified_active_work_requires_review');end if;
  end if;
 end if;
 if v_kind='walk_in'and v_br.inspection_required and v_next in('in_progress','completed')then v_blockers:=array_append(v_blockers,'typed_inspection_adapter_required');end if;
 if v_kind='booking'and v_br.inspection_required and v_next='completed'and(select count(distinct phase)from public.vehicle_inspections where booking_id=v_b.id and status='approved')<>2 then v_blockers:=array_append(v_blockers,'approved_before_after_inspections_required');end if;
 if v_kind='walk_in'and v_next in('quality_check','completed')and(v_span.span_id is null or v_span.ended_at is not null)then v_blockers:=array_append(v_blockers,'actual_open_start_required');end if;
 v_can:=v_ready and v_kind in('walk_in','booking')and cardinality(v_blockers)=0;
 return jsonb_build_object('source_kind',v_kind,'order_id',v_o.order_id,'booking_id',v_b.id,'branch',jsonb_build_object('id',v_br.branch_id,'name_ar',v_br.name_ar,'name_en',v_br.name_en),'work_reference',private.service_work_reference(v_o.order_id),
  'service',jsonb_build_object('name',v_o.service_name,'resource_key',v_resource,'duration_minutes',v_duration),'plate_number',v_plate,'assigned_staff',v_crew,'work_status',v_o.status,'booking_status',v_b.status,
  'arrived',v_arrival is not null,'arrived_at',v_arrival,'priority',v_priority,'vip',coalesce(v_priority='vip',false),'physical_open',coalesce(v_physical,false),'overrun',coalesce(v_span.ended_at is null and v_span.expected_end_at<v_now,false),
  'canonical_work_supported',v_kind in('walk_in','booking'),'legacy_unpaired_booking',false,'legacy_active_progress',v_kind='legacy_order'and v_o.status in('in_progress','quality_check','completed'),'legacy_booking_alignment',v_kind='booking'and v_b.status='confirmed'and v_o.status in('in_progress','quality_check'),
  'next_status',v_next,'admission_is_continuation',coalesce(v_continuation,false),'can_prepare',v_can,'blockers',to_jsonb(v_blockers),'occupancy',v_occupancy,'occupancy_is_advisory',true,'active_stop_supported',false,'refund_automatic',false,'walk_in_loyalty_enabled',false,'official_tax_invoice',false);
end$$;
create function private.list_service_work_queue(p_branch uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare v_role text:=private.active_staff_role();v_rows jsonb;v_more boolean;begin
 if auth.uid()is null or v_role is null or v_role not in('owner','manager','employee')then raise exception 'Active scoped branch staff required'using errcode='42501';end if;
 if p_branch is null then raise exception 'Actual branch required'using errcode='22023';end if;
 if not exists(select 1 from public.business_branches where branch_id=p_branch)or not coalesce(private.can_access_branch(p_branch),false)then raise exception 'Active scoped branch staff required'using errcode='42501';end if;
 with eligible as(select o.order_id,o.created_at,o.status,b.id booking_id,coalesce(wr.arrived_at,br.arrived_at)arrival,coalesce(wr.priority,br.priority)priority,
  coalesce(o.status in('in_progress','quality_check')or b.status='in_progress'or exists(select 1 from private.service_resource_spans s where(s.walk_in_order_id=o.order_id or s.booking_id=b.id)and s.ended_at is null),false)physical
  from public.business_orders o left join public.bookings b on b.id=o.booking_id left join private.offline_walk_in_reception wr on wr.order_id=o.order_id left join private.wash_reception_entries br on br.booking_id=b.id and br.branch_id=o.branch_id
  where o.order_type='service'and o.branch_id=p_branch and o.status in('received','in_progress','quality_check','completed')and(v_role in('owner','manager')or auth.uid()=any(o.assigned_staff_ids)or(b.branch_id=o.branch_id and auth.uid()=any(b.assigned_staff_ids)))),limited as(
  select * from eligible order by physical desc,(arrival is not null)desc,(priority='vip')desc nulls last,arrival nulls last,created_at,order_id limit 100
 )select coalesce(jsonb_agg(private.get_service_work_context(l.order_id,null)order by l.physical desc,(l.arrival is not null)desc,(l.priority='vip')desc nulls last,l.arrival nulls last,l.created_at,l.order_id),'[]'),(select count(*)>100 from eligible)into v_rows,v_more from limited l;
 return jsonb_build_object('branch_id',p_branch,'items',v_rows,'limit',100,'more_available',v_more,'active_stop_supported',false,'refund_automatic',false,'walk_in_loyalty_enabled',false);
end$$;
revoke all on function private.get_service_work_context(uuid,uuid),private.list_service_work_queue(uuid)from public,anon,service_role;
grant execute on function private.get_service_work_context(uuid,uuid),private.list_service_work_queue(uuid)to authenticated;
create function public.get_service_work_context(p_order uuid default null,p_booking uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_service_work_context(p_order,p_booking)$$;
create function public.list_service_work_queue(p_branch uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_service_work_queue(p_branch)$$;
revoke all on function public.get_service_work_context(uuid,uuid),public.list_service_work_queue(uuid)from public,anon,service_role;
grant execute on function public.get_service_work_context(uuid,uuid),public.list_service_work_queue(uuid)to authenticated;
-- Replacements retain the existing exact RPC signatures and authenticated-only grants.
revoke all on function private.prepare_service_work(uuid,uuid,text,text,text),private.place_service_work(uuid),private.enforce_shared_service_work()from public,anon,service_role;
grant execute on function private.prepare_service_work(uuid,uuid,text,text,text),private.place_service_work(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
