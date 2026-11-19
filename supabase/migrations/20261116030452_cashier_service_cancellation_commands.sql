begin;
-- Explicit, audited service stop. No automatic money refund, earned-wage reversal,
-- product return, paid snapshot rewrite or loyalty publication.
create table private.cashier_service_cancellations(
 request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),
 order_id uuid not null unique references public.business_orders(order_id),
 booking_id uuid not null unique references public.bookings(id),invoice_id text not null references public.business_invoices(invoice_id),
 branch_id uuid not null references public.business_branches(branch_id),expected_status text not null,
 reason text not null check(length(trim(reason))between 5 and 500),physical_clearance_confirmed boolean not null,
 payload jsonb not null,result jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.cashier_service_cancellations enable row level security;
revoke all on private.cashier_service_cancellations from public,anon,authenticated,service_role;
create trigger immutable_cashier_service_cancellation before update or delete on private.cashier_service_cancellations for each row execute function private.immutable_loyalty_policy();
create function private.cashier_current_cancellation_witness(p_order uuid,p_booking uuid,p_expected text)returns boolean
language sql stable security invoker set search_path=pg_catalog as $$
 select exists(select 1 from private.cashier_service_cancellations c
 where ((p_order is not null and c.order_id=p_order)or(p_booking is not null and c.booking_id=p_booking))
 and c.actor_id=auth.uid()and c.creator_xid=txid_current()
 and exists(select 1 from private.service_work_ledger e where e.command_id=c.request_id and e.actor_id=c.actor_id and e.creator_xid=c.creator_xid and e.next_status='cancelled'and e.expected_status=p_expected
 and((p_order is not null and e.order_id=p_order)or(p_booking is not null and e.booking_id=p_booking))))
$$;
revoke all on function private.cashier_current_cancellation_witness(uuid,uuid,text)from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION private.guard_cashier_service_child()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare w private.cashier_service_worklines;current_staff uuid[];event_found boolean;begin
 if tg_table_name='bookings'then select *into w from private.cashier_service_worklines where booking_id=old.id;
 else select *into w from private.cashier_service_worklines where order_id=old.order_id;end if;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Billed service history retained'using errcode='55000';end if;
 if tg_table_name='bookings'then
 if new.id<>old.id or new.customer_id<>old.customer_id or new.vehicle_id is distinct from old.vehicle_id or new.branch_id<>old.branch_id or new.catalog_item_id is distinct from old.catalog_item_id or new.quoted_price is distinct from old.quoted_price then raise exception 'Billed service identity immutable'using errcode='55000';end if;
 else
 if(to_jsonb(new)-array['status','updated_at','assigned_staff_ids','assigned_workers'])is distinct from(to_jsonb(old)-array['status','updated_at','assigned_staff_ids','assigned_workers'])then raise exception 'Billed work identity immutable'using errcode='55000';end if;
 end if;
 if new.status='cancelled'and old.status<>'cancelled'and not private.cashier_current_cancellation_witness(case when tg_table_name='business_orders'then w.order_id end,case when tg_table_name='bookings'then w.booking_id end,old.status)then raise exception 'Use explicit management service cancellation'using errcode='55000';end if;
 if exists(select 1 from private.cashier_service_commissions where order_id=w.order_id)and(new.assigned_staff_ids is distinct from old.assigned_staff_ids or new.assigned_workers is distinct from old.assigned_workers)then raise exception 'Started crew is frozen; explicit management stop adapter required'using errcode='55000';end if;
 if new.status is distinct from old.status then
 select exists(select 1 from private.service_work_ledger e where e.command_id is not null and e.actor_id=auth.uid()and e.creator_xid=txid_current()and e.expected_status=old.status and e.next_status=new.status and((tg_table_name='bookings'and e.booking_id=w.booking_id)or(tg_table_name='business_orders'and e.order_id=w.order_id)))into event_found;
 if not event_found then raise exception 'Use durable service work command'using errcode='55000';end if;
 end if;return new;end$function$;
CREATE OR REPLACE FUNCTION private.enforce_shared_service_work()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_o public.business_orders;v_b public.bookings;v_event private.service_work_ledger;v_count integer;v_booking uuid;v_walkin uuid;v_branch uuid;v_assigned boolean;v_command uuid;v_paired boolean;v_active boolean;v_dummy jsonb;v_role text;begin
 if new.status is not distinct from old.status then return new;end if;
 if new.status='cancelled'and private.cashier_current_cancellation_witness(case when tg_table_name='business_orders'then(to_jsonb(old)->>'order_id')::uuid end,case when tg_table_name='bookings'then(to_jsonb(old)->>'id')::uuid end,old.status)then return new;end if;
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
end$function$;
CREATE OR REPLACE FUNCTION private.cashier_service_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare w private.cashier_service_worklines;p private.cashier_invoice_postings;worker uuid;e private.hr_employment;name text;event uuid;staff_count integer;parent_status text;next_parent text;all_quality boolean;all_completed boolean;all_delivered boolean;begin
 if old.status is not distinct from new.status then return new;end if;
 select *into w from private.cashier_service_worklines where order_id=new.order_id;if not found then return new;end if;
 select *into p from private.cashier_invoice_postings where invoice_id=w.invoice_id;
 select event_id into event from private.service_work_ledger where order_id=new.order_id and actor_id=auth.uid()and command_id is not null and creator_xid=txid_current()and next_status=new.status order by created_at desc limit 1;
 if event is null then raise exception 'Durable actual work event required'using errcode='55000';end if;
 if new.status='in_progress'then
 if cardinality(new.assigned_staff_ids)=0 or new.assigned_staff_ids is distinct from(select assigned_staff_ids from public.bookings where id=w.booking_id)then raise exception 'Confirm matching actual booking and work crew before starting'using errcode='55000';end if;
 staff_count:=cardinality(new.assigned_staff_ids);
 for worker in select unnest(new.assigned_staff_ids)order by 1 loop
 perform pg_advisory_xact_lock(hashtextextended('hr:'||worker,0));
 select *into e from private.hr_employment where staff_id=worker and currency='EGP'and starts_on<=current_date and(ends_on is null or ends_on>=current_date)for share;
 if not found or not exists(select 1 from public.staff_profiles x where x.user_id=worker and x.is_active and(x.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=worker and a.branch_id=w.branch_id)))then raise exception 'Actual eligible crew and EGP employment required'using errcode='55000';end if;
 select full_name into name from public.staff_profiles where user_id=worker;
 insert into private.cashier_service_commissions(order_id,staff_id,staff_name,base_before_discount_exact,rate_percent,assigned_count,amount,employment_snapshot)values(new.order_id,worker,name,w.base_before_discount_exact,e.commission_percent,staff_count,round(w.base_before_discount_exact*e.commission_percent/100/staff_count,2),to_jsonb(e));
 end loop;
 elsif new.status='completed'then
 if(select count(*)from private.cashier_service_commissions where order_id=new.order_id)<>cardinality(new.assigned_staff_ids)or exists(select 1 from private.cashier_service_commissions where order_id=new.order_id and not(staff_id=any(new.assigned_staff_ids)))then raise exception 'Exact performed frozen crew required'using errcode='55000';end if;
 for worker in select staff_id from private.cashier_service_commissions where order_id=new.order_id order by staff_id loop
 perform pg_advisory_xact_lock(hashtextextended('hr:'||worker,0));
 insert into private.cashier_service_earnings(order_id,staff_id,work_event)values(new.order_id,worker,event);
 end loop;
 end if;
 select status into parent_status from public.business_orders where order_id=p.order_id for update;
 select bool_and(o.status in('quality_check','completed','delivered','cancelled')),bool_and(o.status in('completed','delivered','cancelled')),bool_and(o.status in('delivered','cancelled'))into all_quality,all_completed,all_delivered from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id;
 loop
 next_parent:=case when parent_status<>'cancelled'and not exists(select 1 from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id and o.status<>'cancelled')then'cancelled'when parent_status='received'and exists(select 1 from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id and o.status not in('received','cancelled'))then'in_progress'when parent_status='in_progress'and all_quality then'quality_check'when parent_status='quality_check'and all_completed then'completed'when parent_status='completed'and all_delivered then'delivered'else null end;
 exit when next_parent is null;
 insert into private.cashier_bundle_events(order_id,next_status,source_event,actor_id,creator_xid)values(p.order_id,next_parent,event,auth.uid(),txid_current());
 update public.business_orders set status=next_parent,updated_at=clock_timestamp()where order_id=p.order_id;parent_status:=next_parent;
 end loop;
 return new;end$function$;
CREATE OR REPLACE FUNCTION private.refund_cashier_invoice_lines(p_request uuid, p_shift uuid, p_invoice text, p_lines jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare p private.cashier_invoice_postings;prior private.cashier_partial_refunds;shift public.business_cashier_shifts;i public.business_invoices;sale public.business_payment_events;
 actor uuid;payload jsonb;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]';previous_quantity integer;quantity integer;amount numeric:=0;prior_refund numeric;number bigint;result jsonb;stock record;
begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Explicit refund permission required'using errcode='42501';end if;
 if p_request is null or p_shift is null or jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Exact original lines, quantities and reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('invoice',p_invoice,'shift',p_shift,'lines',p_lines,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('cashier-partial-refund:'||p_request,0));select *into prior from private.cashier_partial_refunds where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable refund request'using errcode='22023';end if;return prior.result;end if;
 select *into shift from public.business_cashier_shifts where shift_id=p_shift and branch_id=p.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))for update;
 if not found then raise exception 'Authorized branch shift required'using errcode='42501';end if;if shift.status<>'open'then raise exception 'Open shift required'using errcode='55000';end if;
 select *into strict i from public.business_invoices where invoice_id=p_invoice for update;
 select *into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
 if not found or sale.method<>'cash'or i.status='void'then raise exception 'Confirmed cash payment required; electronic refunds require the gateway adapter'using errcode='55000';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already fully refunded'using errcode='40001';end if;
 if(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'One explicit quantity per original line required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(entry)is distinct from'object'or(select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['line_id','quantity','restock'])or jsonb_typeof(entry->'line_id')is distinct from'string'or jsonb_typeof(entry->'quantity')is distinct from'number'or(entry->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(entry->'restock')is distinct from'boolean'then raise exception 'Original line, integer quantity and stock-return decision only'using errcode='22023';end if;
 select value into original from jsonb_array_elements(p.quote->'lines')where value->>'line_id'=entry->>'line_id';
 if original is null then raise exception 'Original invoice line unavailable'using errcode='42501';end if;
 quantity:=(entry->>'quantity')::integer;
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p_invoice and x.line_id=entry->>'line_id';
 slice:=private.cashier_refund_slice_core(p.quote,entry->>'line_id',previous_quantity,quantity);
 if original->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then raise exception 'Service financial refunds require management'using errcode='42501';end if;
 if(entry->>'restock')::boolean then raise exception 'A service cannot return product stock'using errcode='22023';end if;
 if exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number>previous_quantity and w.unit_number<=previous_quantity+quantity and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id))))then raise exception 'Unfinished service requires a coordinated cancellation/stop adapter; no refund or capacity release performed'using errcode='55000';end if;
 if(select count(*)from private.cashier_service_worklines w where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number>previous_quantity and w.unit_number<=previous_quantity+quantity)<>quantity then raise exception 'Complete service-unit coverage required'using errcode='55000';end if;
 end if;
 prepared:=prepared||jsonb_build_array(slice||jsonb_build_object('item_id',original->'item_id','name',original->'name','name_en',original->'name_en','item_type',original->'item_type','restock',entry->'restock'));
 amount:=amount+(slice->>'amount')::numeric;
 end loop;
 select coalesce(sum(pe.amount),0)into prior_refund from public.business_payment_events pe where pe.invoice_id=p_invoice and pe.event_type='refund';
 if prior_refund+amount>sale.amount then raise exception 'Refund exceeds original collected amount'using errcode='22023';end if;
 number:=nextval('private.cashier_refund_reference_seq');
 result:=jsonb_build_object('refund_id',p_request,'refund_number','SH-RFD-'||lpad(number::text,greatest(6,length(number::text)),'0'),'invoice_id',p_invoice,'amount',amount,'currency','EGP','payment_event_recorded',amount>0,'lines',prepared,'original_invoice_unchanged',true,'earned_service_commissions_unchanged',true,'eta_credit_note_accepted',false,'payment_status_requires_refresh',true);
 insert into private.cashier_partial_refunds(request_id,refund_number,invoice_id,actor_id,shift_id,payload,amount,reason,result,creator_xid)values(p_request,number,p_invoice,actor,p_shift,payload,amount,trim(p_reason),result,txid_current());
 for entry in select value from jsonb_array_elements(prepared)loop
 insert into private.cashier_partial_refund_lines values(p_request,p_invoice,entry->>'line_id',(entry->>'quantity')::integer,(entry->>'restock')::boolean,(entry->>'amount')::numeric,(entry->>'tax_amount_exact')::numeric,(entry->>'discount_exact')::numeric,entry);
 end loop;
 if amount>0 then insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id,refund_part_id)values(p_request,p_shift,p_invoice,'refund','cash',amount,actor,p_request);end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(prepared)where value->>'item_type'='product'and(value->>'restock')::boolean)order by c.item_id for update;
 for stock in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(prepared)x on c.item_id=(x.value->>'item_id')::uuid where x.value->>'item_type'='product'and(x.value->>'restock')::boolean group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=stock.stock_quantity+stock.quantity,updated_at=clock_timestamp()where item_id=stock.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(p_request,p.branch_id,stock.item_id,'pos_refund',stock.stock_quantity,stock.stock_quantity+stock.quantity,trim(p_reason),actor,p_invoice);
 end loop;
 if prior_refund+amount=sale.amount and i.status='active'then update public.business_invoices set status='refunded'where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data,reason)values(actor::text,actor,'cashier_partial_refund','business_invoices',p_invoice,p.branch_id,jsonb_build_object('refund_id',p_request,'amount',amount,'lines',prepared,'earned_commissions_retained',true),trim(p_reason));
 return result;
end$function$;
create function private.cancel_cashier_service(p_request uuid,p_order uuid,p_expected_status text,p_reason text,p_physical_clearance boolean)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare w private.cashier_service_worklines;o public.business_orders;b public.bookings;posted private.cashier_invoice_postings;
 actor uuid;prior private.cashier_service_cancellations;payload jsonb;v_result jsonb;event uuid;booking_event uuid;span private.service_resource_spans;release uuid;now_at timestamptz;dummy jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Service cancellation requires READ COMMITTED'using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 select *into w from private.cashier_service_worklines where order_id=p_order;
 if not found then raise exception 'Billed service unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(w.branch_id);
 if private.active_staff_role()not in('owner','manager')then raise exception 'Scoped management approval required'using errcode='42501';end if;
 if p_request is null or p_physical_clearance is null or p_expected_status is null or p_expected_status not in('received','in_progress','quality_check')or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Expected unfinished status, reason and physical clearance decision required'using errcode='22023';end if;
 payload:=jsonb_build_object('order_id',p_order,'expected_status',p_expected_status,'reason',trim(p_reason),'physical_clearance',p_physical_clearance);
 perform pg_advisory_xact_lock(hashtextextended('cashier-service-stop:'||p_request,0));
 perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));
 select *into prior from private.cashier_service_cancellations where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable cancellation request'using errcode='22023';end if;return prior.result;end if;
 -- Match the work kernel lock order: command actor, own order, own booking,
 -- invoice parent, then vehicle/resource days. No shifts or HR rows are rewritten.
 perform pg_advisory_xact_lock(hashtextextended('service-work-actor:'||actor,0));
 perform pg_advisory_xact_lock(hashtextextended('service-work-pair:'||w.booking_id::text,0));
 select *into strict o from public.business_orders where order_id=p_order for update;
 select *into strict b from public.bookings where id=w.booking_id for update;
 select *into strict posted from private.cashier_invoice_postings where invoice_id=w.invoice_id;

 if o.status<>p_expected_status or b.status not in('pending','confirmed','in_progress')or exists(select 1 from private.cashier_service_cancellations where order_id=p_order)then raise exception 'Service changed; refresh before cancellation'using errcode='40001';end if;
 if exists(select 1 from private.cashier_service_earnings where order_id=p_order)then raise exception 'Earned completed service cannot be cancelled'using errcode='55000';end if;
 -- Initial safe scope is confirmed onsite cash only. Unpaid credits and
 -- gateway cancellation/refund adapters require their own accepted workflows.
 if not exists(select 1 from public.business_invoices i join public.business_payment_events pay using(invoice_id)where i.invoice_id=w.invoice_id and i.status='active'and pay.event_type='sale'and pay.method='cash'and pay.amount=i.total)then raise exception 'Confirmed cash invoice required; unpaid or gateway cancellation adapter unavailable'using errcode='55000';end if;
 if exists(select 1 from private.cashier_partial_refund_lines where invoice_id=w.invoice_id and line_id=w.line_id)then raise exception 'Resolve existing line refund before service cancellation'using errcode='55000';end if;
 dummy:=private.lock_service_source_resource(w.booking_id,null);
 perform 1 from public.business_orders where order_id=posted.order_id for update;
 select *into span from private.service_resource_spans where booking_id=w.booking_id for update;
 if(o.status in('in_progress','quality_check')or span.span_id is not null)and not p_physical_clearance then raise exception 'Management must confirm vehicle and equipment physically clear before releasing capacity'using errcode='55000';end if;
 if span.span_id is not null and span.ended_at is not null then raise exception 'Physical service already ended; review rather than cancel'using errcode='55000';end if;
 event:=gen_random_uuid();booking_event:=gen_random_uuid();now_at:=clock_timestamp();
 v_result:=jsonb_build_object('kind','cashier_service_cancellation_v1','request_id',p_request,'order_id',p_order,'booking_id',w.booking_id,'invoice_id',w.invoice_id,'status','cancelled','performed_status','cancelled','financial_refund_performed',false,'refund_requires_separate_confirmation',true,'physical_span_released',span.span_id is not null);
 insert into private.service_work_commands(request_id,actor_id,order_id,branch_id,payload,source_snapshot,state)values(p_request,actor,p_order,w.branch_id,jsonb_build_object('next_status','cancelled','reason',trim(p_reason)),private.service_work_source_snapshot(p_order),'prepared');
 insert into private.cashier_service_cancellations values(p_request,actor,p_order,w.booking_id,w.invoice_id,w.branch_id,o.status,trim(p_reason),p_physical_clearance,payload,v_result,txid_current(),now_at);
 insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,order_id,expected_status,next_status,reason,purpose,creator_xid)values(event,p_request,actor,'order',p_order,o.status,'cancelled',trim(p_reason),'cashier_explicit_management_stop',txid_current());
 insert into private.service_work_ledger(event_id,command_id,actor_id,target_kind,booking_id,expected_status,next_status,reason,purpose,creator_xid)values(booking_event,p_request,actor,'booking',w.booking_id,b.status,'cancelled',trim(p_reason),'cashier_explicit_management_stop',txid_current());
 if span.span_id is not null then
 release:=gen_random_uuid();insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,action,payload,occurred_at,creator_xid)values(release,event,actor,'booking',w.booking_id,'release',jsonb_build_object('cancellation_request',p_request,'work_event_id',event,'reason',trim(p_reason),'physical_clearance_confirmed',true),now_at,txid_current());
 update private.service_resource_spans set ended_at=now_at,end_event_id=release where span_id=span.span_id;
 end if;
 update public.bookings set status='cancelled'where id=w.booking_id;
 update public.business_orders set status='cancelled',updated_at=now_at where order_id=p_order;
 update private.service_work_commands set state='succeeded',result=v_result,resolved_at=now_at where request_id=p_request;
 update private.service_work_commands set acknowledged_at=now_at where request_id=p_request;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason)values(actor::text,actor,'cashier_service_cancel','business_orders',p_order::text,w.branch_id,trim(p_reason));
 return v_result;
end$$;
revoke all on function private.cancel_cashier_service(uuid,uuid,text,text,boolean)from public,anon,authenticated,service_role;
grant execute on function private.cancel_cashier_service(uuid,uuid,text,text,boolean)to authenticated;
create function public.cancel_cashier_service(p_request uuid,p_order uuid,p_expected_status text,p_reason text,p_physical_clearance boolean)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.cancel_cashier_service(p_request,p_order,p_expected_status,p_reason,p_physical_clearance)$$;
revoke all on function public.cancel_cashier_service(uuid,uuid,text,text,boolean)from public,anon,service_role;
grant execute on function public.cancel_cashier_service(uuid,uuid,text,text,boolean)to authenticated;
CREATE OR REPLACE FUNCTION private.preview_cashier_refund_lines(p_invoice text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare p private.cashier_invoice_postings;actor uuid;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]';previous_quantity integer;quantity integer;amount numeric:=0;paid numeric;refunded numeric;version jsonb;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Refund permission required'using errcode='42501';end if;
 if jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'Distinct original lines required'using errcode='22023';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already fully refunded'using errcode='40001';end if;
 select pe.amount into paid from public.business_payment_events pe where pe.invoice_id=p_invoice and pe.event_type='sale'and pe.method='cash';if not found then raise exception 'Confirmed cash payment required'using errcode='55000';end if;
 for entry in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(entry)is distinct from'object'or(select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['line_id','quantity','restock'])or jsonb_typeof(entry->'line_id')is distinct from'string'or jsonb_typeof(entry->'quantity')is distinct from'number'or(entry->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(entry->'restock')is distinct from'boolean'then raise exception 'Line identity, integer quantity and stock-return choice only'using errcode='22023';end if;
 select value into original from jsonb_array_elements(p.quote->'lines')where value->>'line_id'=entry->>'line_id';if original is null then raise exception 'Original line unavailable'using errcode='42501';end if;
 quantity:=(entry->>'quantity')::integer;select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p_invoice and x.line_id=entry->>'line_id';
 slice:=private.cashier_refund_slice_core(p.quote,entry->>'line_id',previous_quantity,quantity);
 if original->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then raise exception 'Service refund requires management'using errcode='42501';end if;
 if(entry->>'restock')::boolean or exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number>previous_quantity and w.unit_number<=previous_quantity+quantity and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id))))or(select count(*)from private.cashier_service_worklines where invoice_id=p_invoice and line_id=entry->>'line_id'and unit_number>previous_quantity and unit_number<=previous_quantity+quantity)<>quantity then raise exception 'Completed service units required; cancellation is separate'using errcode='55000';end if;
 end if;
 amount:=amount+(slice->>'amount')::numeric;prepared:=prepared||jsonb_build_array(slice||jsonb_build_object('name',original->'name','name_en',original->'name_en','restock',entry->'restock'));
 end loop;
 select coalesce(sum(e.amount),0)into refunded from public.business_payment_events e where e.invoice_id=p_invoice and e.event_type='refund';if amount+refunded>paid then raise exception 'Original collected amount exceeded'using errcode='22023';end if;
 version:=jsonb_build_object('version','cashier-refund-preview-v1','invoice',p_invoice,'requested_lines',p_lines,'calculated_lines',prepared,'amount',amount,'paid',paid,'refunded',refunded);
 return jsonb_build_object('quote_hash',encode(extensions.digest(version::text,'sha256'),'hex'),'amount',amount,'currency','EGP','lines',prepared,'quote_only',true,'financial_event_created',false);
end$function$;
CREATE OR REPLACE FUNCTION private.get_cashier_checkout_state(p_branch uuid, p_draft uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;p private.cashier_invoice_postings;i public.business_invoices;sale public.business_payment_events;
 b public.business_branches;shifts jsonb;invoice jsonb;work jsonb;refundable jsonb:='[]';history jsonb;line jsonb;previous_quantity integer;remaining integer;ready integer;refunded numeric:=0;can_refund boolean;begin
 actor:=private.cashier_cart_actor(p_branch);select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and branch_id=p_branch and actor_id=actor;
 if not found then raise exception 'Own saved draft required'using errcode='42501';end if;
 select *into b from public.business_branches where branch_id=p_branch;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.shift_id,'cashier_name',s.full_name,'opened_local',x.opened_at at time zone b.time_zone)order by x.opened_at,x.shift_id),'[]')into shifts from public.business_cashier_shifts x join public.staff_profiles s on s.user_id=x.cashier_id where x.branch_id=p_branch and x.status='open'and(x.cashier_id=actor or private.active_staff_role()in('owner','manager'));
 can_refund:=private.active_staff_role()in('owner','manager')or exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true');
 select *into p from private.cashier_invoice_postings where draft_id=p_draft;
 if found then
 select *into strict i from public.business_invoices where invoice_id=p.invoice_id;
 select *into sale from public.business_payment_events where invoice_id=p.invoice_id and event_type='sale';
 select coalesce(sum(amount),0)into refunded from public.business_payment_events where invoice_id=p.invoice_id and event_type='refund';
 invoice:=jsonb_build_object('id',i.invoice_id,'number',i.display_number,'token',i.document_token,'total',i.total,'status',i.status,'refunded_amount',refunded,'net_collected',coalesce(sale.amount,0)-refunded,'payment_status',case when i.status='void'then'cancelled'when i.status='refunded'then'refunded'when sale.payment_id is null then'unpaid'when refunded>0 and refunded<sale.amount then'partially_refunded'when sale.method='cash'then'paid'else'verification_required'end,'cash_confirmed',sale.payment_id is not null and sale.method='cash');
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'number',result->>'refund_number','amount',amount,'payment_event_recorded',amount>0)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=p.invoice_id;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids),'can_cancel',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.method='cash'and sale.amount=i.total and not exists(select 1 from private.cashier_partial_refund_lines r where r.invoice_id=w.invoice_id and r.line_id=w.line_id),'physical_clearance_required',o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans sp where sp.booking_id=w.booking_id and sp.ended_at is null))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and sale.method='cash'and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
 for line in select value from jsonb_array_elements(p.quote->'lines')loop
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p.invoice_id and x.line_id=line->>'line_id';
 remaining:=(line->>'quantity')::integer-previous_quantity;ready:=remaining;
 if line->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then ready:=0;
 else select coalesce(min(w.unit_number)-previous_quantity-1,remaining)into ready from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p.invoice_id and w.line_id=line->>'line_id'and w.unit_number>previous_quantity and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id)));end if;
 end if;
 if remaining>0 then refundable:=refundable||jsonb_build_array(jsonb_build_object('line_id',line->'line_id','name',line->'name','name_en',line->'name_en','item_type',line->'item_type','remaining_quantity',remaining,'refundable_quantity',greatest(ready,0)));end if;
 end loop;end if;
 end if;
 return jsonb_build_object('kind','cashier_checkout_state_v1','draft_id',p_draft,'draft_version',d.version,'branch_id',p_branch,'role',private.active_staff_role(),'time_zone',b.time_zone,'local_today',(clock_timestamp()at time zone b.time_zone)::date,'local_now',clock_timestamp()at time zone b.time_zone,'binding',private.get_cashier_draft_subject(p_branch,p_draft),'state',case when p.invoice_id is null then'draft'else'issued'end,'invoice',invoice,'open_shifts',shifts,'work',coalesce(work,'[]'),'refunds',coalesce(history,'[]'),'refundable_lines',refundable,'can_refund',can_refund,'live_electronic_enabled',false,'offline_profile_issue_supported',false,'bundle_loyalty_accrual_supported',false);
end$function$;
CREATE OR REPLACE FUNCTION private.guard_cashier_posted_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;begin
 select *into p from private.cashier_invoice_postings where order_id=old.order_id;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Issued order retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['status','updated_at','order_number'])is distinct from(to_jsonb(old)-array['status','updated_at','order_number'])then raise exception 'Issued customer, car and order identity immutable'using errcode='55000';end if;
 if new.order_number is distinct from old.order_number and not(p.creator_xid=txid_current()and new.order_number=(select display_number from public.business_invoices where invoice_id=p.invoice_id))then raise exception 'Issued reference immutable'using errcode='55000';end if;
 if new.status is distinct from old.status and(exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)or(not private.cashier_invoice_has_services(p.invoice_id)and(select status from public.business_invoices where invoice_id=p.invoice_id)='refunded'))then raise exception 'Refunded order cannot advance or restore stock again'using errcode='55000';end if;
 if private.cashier_invoice_has_services(p.invoice_id)and new.status is distinct from old.status and not exists(select 1 from private.cashier_bundle_events where order_id=p.order_id and next_status=new.status and actor_id=auth.uid()and creator_xid=txid_current())then raise exception 'Bundle status follows actual component work only'using errcode='55000';end if;
 if new.status='cancelled'and old.status<>'cancelled'and not(private.cashier_invoice_has_services(p.invoice_id)and exists(select 1 from private.cashier_bundle_events e where e.order_id=p.order_id and e.next_status='cancelled'and e.actor_id=auth.uid()and e.creator_xid=txid_current())and not exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p.invoice_id and(o.status<>'cancelled'or not exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.invoice_id=w.invoice_id))))then raise exception 'Use canonical refund; legacy cancellation cannot restore posted stock'using errcode='55000';end if;
 return new;end$function$;
commit;
