begin;
-- Additive internal unpaid-service credits. Original invoice UUID, number,
-- total, tax and document snapshot are never overwritten. Not an ETA credit note.
create sequence private.cashier_unpaid_credit_reference_seq;
revoke all on sequence private.cashier_unpaid_credit_reference_seq from public,anon,authenticated,service_role;
create table private.cashier_unpaid_service_credits(
 request_id uuid primary key references private.cashier_service_cancellations(request_id)deferrable initially deferred,
 credit_number bigint not null unique,invoice_id text not null references private.cashier_invoice_postings(invoice_id),
 order_id uuid not null unique references private.cashier_service_worklines(order_id),
 line_id text not null,unit_number integer not null check(unit_number>0),
 amount numeric(12,2)not null check(amount>=0),tax_amount_exact numeric(18,5)not null check(tax_amount_exact>=0),
 discount_exact numeric(18,5)not null check(discount_exact>=0),actor_id uuid not null references public.staff_profiles(user_id),
 reason text not null check(length(trim(reason))between 5 and 500),payload jsonb not null,allocation_snapshot jsonb not null,
 creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(invoice_id,line_id,unit_number));
alter table private.cashier_unpaid_service_credits enable row level security;
revoke all on private.cashier_unpaid_service_credits from public,anon,authenticated,service_role;
create trigger immutable_unpaid_service_credit before update or delete on private.cashier_unpaid_service_credits for each row execute function private.immutable_loyalty_policy();
create function private.cashier_invoice_unpaid_credit(p_invoice text)returns numeric language sql stable security invoker set search_path=pg_catalog as $$select coalesce(sum(amount),0)from private.cashier_unpaid_service_credits where invoice_id=p_invoice$$;
create function private.cashier_invoice_unpaid_credit_tax(p_invoice text)returns numeric language sql stable security invoker set search_path=pg_catalog as $$select coalesce(sum(tax_amount_exact),0)from private.cashier_unpaid_service_credits where invoice_id=p_invoice$$;
create function private.cashier_invoice_payable(p_invoice text)returns numeric language sql stable security invoker set search_path=pg_catalog as $$select total-private.cashier_invoice_unpaid_credit(invoice_id)from public.business_invoices where invoice_id=p_invoice$$;
revoke all on function private.cashier_invoice_unpaid_credit(text),private.cashier_invoice_unpaid_credit_tax(text),private.cashier_invoice_payable(text)from public,anon,authenticated,service_role;
create function private.validate_unpaid_service_credit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare w private.cashier_service_worklines;q jsonb;allocation jsonb;begin
 select *into w from private.cashier_service_worklines where order_id=new.order_id;
 if not found or w.invoice_id<>new.invoice_id or w.line_id<>new.line_id or w.unit_number<>new.unit_number or new.actor_id is distinct from auth.uid()or new.creator_xid<>txid_current()or private.active_staff_role()not in('owner','manager')or not private.can_access_branch(w.branch_id)then raise exception 'Exact scoped management credit source required'using errcode='42501';end if;
 if exists(select 1 from public.business_payment_events where invoice_id=new.invoice_id)or exists(select 1 from private.paymob_intents where invoice_id=new.invoice_id)then raise exception 'Only unpaid invoices without gateway attempts can receive an unpaid-service credit'using errcode='55000';end if;
 select quote into q from private.cashier_invoice_postings where invoice_id=w.invoice_id;
 allocation:=private.cashier_refund_slice_core(q,w.line_id,w.unit_number-1,1);
 if allocation<>new.allocation_snapshot or new.amount<>(allocation->>'amount')::numeric or new.tax_amount_exact<>(allocation->>'tax_amount_exact')::numeric or new.discount_exact<>(allocation->>'discount_exact')::numeric then raise exception 'Original exact unit allocation required'using errcode='55000';end if;
 return new;end$$;
create trigger validate_unpaid_service_credit before insert on private.cashier_unpaid_service_credits for each row execute function private.validate_unpaid_service_credit();
create function private.check_unpaid_credit_cancellation_commit()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if not exists(select 1 from private.cashier_service_cancellations c join public.business_orders o on o.order_id=c.order_id where c.request_id=new.request_id and c.order_id=new.order_id and c.invoice_id=new.invoice_id and c.actor_id=new.actor_id and c.creator_xid=new.creator_xid and c.creator_xid=txid_current()and o.status='cancelled')then raise exception 'Unpaid credit requires its exact committed cancellation'using errcode='55000';end if;
 if private.cashier_invoice_payable(new.invoice_id)<0 then raise exception 'Credits exceed original invoice'using errcode='22023';end if;return null;end$$;
create constraint trigger unpaid_credit_cancellation_commit after insert on private.cashier_unpaid_service_credits deferrable initially deferred for each row execute function private.check_unpaid_credit_cancellation_commit();
revoke all on function private.validate_unpaid_service_credit(),private.check_unpaid_credit_cancellation_commit()from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION private.cancel_cashier_service(p_request uuid, p_order uuid, p_expected_status text, p_reason text, p_physical_clearance boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare w private.cashier_service_worklines;o public.business_orders;b public.bookings;posted private.cashier_invoice_postings;
 actor uuid;credit private.cashier_unpaid_service_credits;is_unpaid boolean:=false;prior private.cashier_service_cancellations;payload jsonb;v_result jsonb;event uuid;booking_event uuid;span private.service_resource_spans;release uuid;now_at timestamptz;dummy jsonb;
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
 perform 1 from public.business_invoices where invoice_id=w.invoice_id for update;
 perform pg_advisory_xact_lock(hashtextextended('service-work-pair:'||w.booking_id::text,0));
 select *into strict o from public.business_orders where order_id=p_order for update;
 select *into strict b from public.bookings where id=w.booking_id for update;
 select *into strict posted from private.cashier_invoice_postings where invoice_id=w.invoice_id;

 if o.status<>p_expected_status or b.status not in('pending','confirmed','in_progress')or exists(select 1 from private.cashier_service_cancellations where order_id=p_order)then raise exception 'Service changed; refresh before cancellation'using errcode='40001';end if;
 if exists(select 1 from private.cashier_service_earnings where order_id=p_order)then raise exception 'Earned completed service cannot be cancelled'using errcode='55000';end if;
 -- Initial safe scope is confirmed onsite cash only. Unpaid credits and
 -- gateway cancellation/refund adapters require their own accepted workflows.
 select *into credit from private.cashier_unpaid_service_credits where request_id=p_request and order_id=p_order and actor_id=actor and creator_xid=txid_current();is_unpaid:=found;
 if is_unpaid then
  if not exists(select 1 from public.business_invoices where invoice_id=w.invoice_id and status='active')or exists(select 1 from public.business_payment_events where invoice_id=w.invoice_id)or exists(select 1 from private.paymob_intents where invoice_id=w.invoice_id)then raise exception 'Unpaid-credit state changed'using errcode='40001';end if;
 elsif not exists(select 1 from public.business_invoices i join public.business_payment_events pay using(invoice_id)where i.invoice_id=w.invoice_id and i.status='active'and pay.event_type='sale'and pay.method='cash'and pay.amount=private.cashier_invoice_payable(i.invoice_id))then raise exception 'Confirmed cash or explicit unpaid-credit command required'using errcode='55000';end if;
 if (select coalesce(sum(quantity),0)from private.cashier_partial_refund_lines where invoice_id=w.invoice_id and line_id=w.line_id)>=w.unit_number then raise exception 'This exact service unit is already refunded; review its retained history'using errcode='55000';end if;
 dummy:=private.lock_service_source_resource(w.booking_id,null);
 perform 1 from public.business_orders where order_id=posted.order_id for update;
 select *into span from private.service_resource_spans where booking_id=w.booking_id for update;
 if(o.status in('in_progress','quality_check')or span.span_id is not null)and not p_physical_clearance then raise exception 'Management must confirm vehicle and equipment physically clear before releasing capacity'using errcode='55000';end if;
 if span.span_id is not null and span.ended_at is not null then raise exception 'Physical service already ended; review rather than cancel'using errcode='55000';end if;
 event:=gen_random_uuid();booking_event:=gen_random_uuid();now_at:=clock_timestamp();
 v_result:=jsonb_build_object('kind','cashier_service_cancellation_v1','request_id',p_request,'order_id',p_order,'booking_id',w.booking_id,'invoice_id',w.invoice_id,'status','cancelled','performed_status','cancelled','financial_refund_performed',false,'refund_requires_separate_confirmation',not is_unpaid,'unpaid_credit_applied',is_unpaid,'credit_number',case when is_unpaid then'SH-CRD-'||lpad(credit.credit_number::text,greatest(6,length(credit.credit_number::text)),'0')end,'credit_amount',case when is_unpaid then credit.amount end,'amount_due_after',private.cashier_invoice_payable(w.invoice_id),'physical_span_released',span.span_id is not null);
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
end$function$;
create function private.cancel_unpaid_cashier_service(p_request uuid,p_order uuid,p_expected_status text,p_reason text,p_physical_clearance boolean)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$declare w private.cashier_service_worklines;c private.cashier_unpaid_service_credits;actor uuid;payload jsonb;slice jsonb;q jsonb;number bigint;result jsonb;begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Unpaid cancellation requires READ COMMITTED'using errcode='55000';end if;
 select *into w from private.cashier_service_worklines where order_id=p_order;if not found then raise exception 'Billed service unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(w.branch_id);if private.active_staff_role()not in('owner','manager')then raise exception 'Management required for unpaid-service credits'using errcode='42501';end if;
 if p_request is null or p_expected_status is null or p_expected_status not in('received','in_progress','quality_check')or p_physical_clearance is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit original service state and consent required'using errcode='22023';end if;
 payload:=jsonb_build_object('order_id',p_order,'expected_status',p_expected_status,'reason',trim(p_reason),'physical_clearance',p_physical_clearance);
 perform pg_advisory_xact_lock(hashtextextended('cashier-service-stop:'||p_request,0));perform pg_advisory_xact_lock(hashtextextended('service-work-command:'||p_request::text,0));
 select *into c from private.cashier_unpaid_service_credits where request_id=p_request;
 if found then if c.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if c.payload<>payload then raise exception 'Immutable unpaid credit request'using errcode='22023';end if;select sc.result into strict result from private.cashier_service_cancellations sc where sc.request_id=p_request;return result;end if;
 perform pg_advisory_xact_lock(hashtextextended('service-work-actor:'||actor,0));
 perform 1 from public.business_invoices where invoice_id=w.invoice_id and status='active'for update;if not found then raise exception 'Active unpaid invoice required'using errcode='55000';end if;
 if exists(select 1 from public.business_payment_events where invoice_id=w.invoice_id)or exists(select 1 from private.paymob_intents where invoice_id=w.invoice_id)then raise exception 'Invoice already collected or has a gateway attempt; refresh'using errcode='40001';end if;
 select quote into q from private.cashier_invoice_postings where invoice_id=w.invoice_id;
 slice:=private.cashier_refund_slice_core(q,w.line_id,w.unit_number-1,1);number:=nextval('private.cashier_unpaid_credit_reference_seq');
 insert into private.cashier_unpaid_service_credits(request_id,credit_number,invoice_id,order_id,line_id,unit_number,amount,tax_amount_exact,discount_exact,actor_id,reason,payload,allocation_snapshot,creator_xid)
 values(p_request,number,w.invoice_id,p_order,w.line_id,w.unit_number,(slice->>'amount')::numeric,(slice->>'tax_amount_exact')::numeric,(slice->>'discount_exact')::numeric,actor,trim(p_reason),payload,slice,txid_current());
 result:=private.cancel_cashier_service(p_request,p_order,p_expected_status,p_reason,p_physical_clearance);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data,reason)values(actor::text,actor,'cashier_unpaid_service_credit','business_invoices',w.invoice_id,w.branch_id,jsonb_build_object('request_id',p_request,'credit_amount',(slice->>'amount')::numeric,'original_invoice_unchanged',true),trim(p_reason));return result;
end$$;
create function public.cancel_unpaid_cashier_service(p_request uuid,p_order uuid,p_expected_status text,p_reason text,p_physical_clearance boolean)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.cancel_unpaid_cashier_service(p_request,p_order,p_expected_status,p_reason,p_physical_clearance)$$;
revoke all on function private.cancel_unpaid_cashier_service(uuid,uuid,text,text,boolean),public.cancel_unpaid_cashier_service(uuid,uuid,text,text,boolean)from public,anon,authenticated,service_role;
grant execute on function private.cancel_unpaid_cashier_service(uuid,uuid,text,text,boolean),public.cancel_unpaid_cashier_service(uuid,uuid,text,text,boolean)to authenticated;
CREATE OR REPLACE FUNCTION private.record_shift_payment(p_request uuid, p_shift uuid, p_invoice text, p_event text, p_method text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare s public.business_cashier_shifts%rowtype;i public.business_invoices%rowtype;e public.business_payment_events%rowtype;sale public.business_payment_events%rowtype;
begin
 if p_request is null or p_event not in ('sale','refund') or p_method not in ('cash','electronic') then raise exception 'Invalid payment request';end if;
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(s.branch_id),false) or (s.cashier_id<>auth.uid() and private.active_staff_role() not in ('owner','manager')) then raise exception 'Shift access denied';end if;
 if p_event='refund'and exists(select 1 from private.cashier_partial_refunds r join public.business_invoices x on x.invoice_id=r.invoice_id where r.invoice_id=p_invoice and x.branch_id=s.branch_id)then raise exception 'Use canonical remaining-line refund'using errcode='55000';end if;
 select * into e from public.business_payment_events where payment_id=p_request or(invoice_id=p_invoice and event_type=p_event);
 if found then if e.shift_id<>p_shift or e.invoice_id<>p_invoice or e.event_type<>p_event or e.method<>p_method then raise exception 'Payment already recorded in another request or shift';end if;return e.payment_id;end if;
 if s.status<>'open' then raise exception 'Shift is sealed';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if i.branch_id<>s.branch_id or i.total<=0 or i.status='void' then raise exception 'Invoice is not payable in this branch';end if;
 if p_event='sale'and private.cashier_invoice_payable(p_invoice)<=0 then raise exception 'No cash due; credit settlement has no payment event'using errcode='55000';end if;
 if p_event='sale' and i.status<>'active' then raise exception 'Invoice is not active';end if;
 if p_event='refund' then
  select * into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
  if not found or sale.method<>p_method then raise exception 'A matching recorded payment is required for refund';end if;
 end if;
 insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id) values(p_request,p_shift,p_invoice,p_event,p_method,case when p_event='refund' then sale.amount else private.cashier_invoice_payable(p_invoice) end,auth.uid());
 if p_event='refund' then update public.business_invoices set status='refunded' where invoice_id=p_invoice;else update public.business_invoices set payment_method=p_method where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'record_'||p_event,'business_payment_events',p_request::text,s.branch_id,jsonb_build_object('invoice_id',p_invoice,'method',p_method,'amount',case when p_event='refund' then sale.amount else private.cashier_invoice_payable(p_invoice) end));return p_request;
end; $function$;
CREATE OR REPLACE FUNCTION private.cashier_refund_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;r private.cashier_full_refunds;s record;begin
 select *into p from private.cashier_invoice_postings where invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.cashier_cart_actor(p.branch_id);
 if new.refund_part_id is not null then return new;end if;
 if new.event_type='sale'then if exists(select 1 from private.cashier_unpaid_service_credits where invoice_id=new.invoice_id)and not exists(select 1 from private.cashier_adjusted_cash_confirmations c where c.request_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount and c.credit_version=private.cashier_unpaid_credit_version(new.invoice_id))then raise exception 'Explicit current adjusted cash confirmation required'using errcode='42501';end if;if new.amount<>private.cashier_invoice_payable(p.invoice_id) then raise exception 'Original amount required'using errcode='55000';end if;return new;end if;
 select *into r from private.cashier_full_refunds where payment_id=new.payment_id and invoice_id=new.invoice_id and creator_xid=txid_current()and actor_id=auth.uid();
 if not found or new.amount<>(p.quote->>'total')::numeric then raise exception 'Explicit canonical full refund required'using errcode='55000';end if;
 if not r.restock then return new;end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(p.quote->'lines'))order by c.item_id for update;
 for s in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(p.quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=s.stock_quantity+s.quantity,updated_at=clock_timestamp()where item_id=s.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(new.payment_id,p.branch_id,s.item_id,'pos_refund',s.stock_quantity,s.stock_quantity+s.quantity,r.reason,auth.uid(),p.invoice_id);
 end loop;return new;end$function$;
CREATE OR REPLACE FUNCTION private.preview_cashier_refund_lines(p_invoice text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare p private.cashier_invoice_postings;actor uuid;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]';previous_quantity integer;quantity integer;amount numeric:=0;paid numeric;refunded numeric;version jsonb;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if exists(select 1 from private.cashier_unpaid_service_credits where invoice_id=p_invoice)then raise exception 'Credited invoice refunds require the remaining-unit allocation adapter'using errcode='55000';end if;
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
 if exists(select 1 from private.cashier_unpaid_service_credits where invoice_id=p_invoice)then raise exception 'Credited invoice refunds require the remaining-unit allocation adapter'using errcode='55000';end if;
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
CREATE OR REPLACE FUNCTION private.reserve_paymob_sandbox(p_request uuid, p_invoice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare i public.business_invoices%rowtype;t private.paymob_intents%rowtype;o public.business_orders%rowtype;c public.customers%rowtype;begin
 if auth.uid() is null or not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 if p_request is null then raise exception 'Stable request required';end if;
 perform pg_advisory_xact_lock(hashtextextended('paymob-invoice:'||p_invoice,0));
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if exists(select 1 from private.cashier_unpaid_service_credits where invoice_id=p_invoice)then raise exception 'Adjusted invoice gateway adapter not enabled'using errcode='55000';end if;
 if i.status<>'active' or i.total<=0 or i.total<>round(i.total,2) or exists(select 1 from public.business_payment_events where invoice_id=p_invoice and event_type='sale') then raise exception 'Invoice is not payable';end if;
 select * into t from private.paymob_intents where intent_id=p_request;
 if found and (t.invoice_id<>p_invoice or t.created_by<>auth.uid()) then raise exception 'Payment request mismatch';end if;
 if t.intent_id is null then select * into t from private.paymob_intents where invoice_id=p_invoice and status in ('creating','pending','uncertain','sandbox_succeeded','refund_reported') order by created_at desc limit 1;end if;
 if t.intent_id is not null then return jsonb_build_object('intent_id',t.intent_id,'amount_cents',t.amount_cents,'currency',t.currency,'claimed',false,'status',t.status,'checkout_url',t.checkout_url);end if;
 insert into private.paymob_intents(intent_id,invoice_id,created_by,amount_cents) values(p_request,p_invoice,auth.uid(),(i.total*100)::bigint) returning * into t;
 select * into o from public.business_orders where order_id=i.order_id;
 select * into c from public.customers where id=o.customer_id;
 return jsonb_build_object('intent_id',t.intent_id,'amount_cents',t.amount_cents,'currency',t.currency,'claimed',true,'status',t.status,'customer',jsonb_build_object('full_name',c.full_name,'email',c.email,'phone',c.phone));
end;$function$;
create table private.cashier_adjusted_cash_confirmations(
 request_id uuid primary key references public.business_payment_events(payment_id)deferrable initially deferred,
 invoice_id text not null references private.cashier_invoice_postings(invoice_id),shift_id uuid not null references public.business_cashier_shifts(shift_id),
 actor_id uuid not null references public.staff_profiles(user_id),amount numeric(12,2)not null check(amount>0),credit_version text not null,
 payload jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.cashier_adjusted_cash_confirmations enable row level security;
revoke all on private.cashier_adjusted_cash_confirmations from public,anon,authenticated,service_role;
create trigger immutable_adjusted_cash_confirmation before update or delete on private.cashier_adjusted_cash_confirmations for each row execute function private.immutable_loyalty_policy();
create function private.cashier_unpaid_credit_version(p_invoice text)returns text language sql stable security invoker set search_path=pg_catalog as $$select encode(extensions.digest(coalesce(string_agg(request_id::text||':'||amount::text||':'||line_id||':'||unit_number::text,'|'order by request_id),''),'sha256'),'hex')from private.cashier_unpaid_service_credits where invoice_id=p_invoice$$;
revoke all on function private.cashier_unpaid_credit_version(text)from public,anon,authenticated,service_role;
create function private.confirm_cashier_adjusted_cash(p_request uuid,p_shift uuid,p_invoice text,p_expected_payable numeric,p_credit_version text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare posted private.cashier_invoice_postings;actor uuid;prior private.cashier_adjusted_cash_confirmations;payload jsonb;result jsonb;begin
 select *into posted from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(posted.branch_id);
 if p_request is null or p_shift is null or p_expected_payable is null or p_expected_payable<=0 or p_expected_payable::text in('NaN','Infinity','-Infinity')or p_credit_version is null then raise exception 'Positive exact payable and reviewed credit version required'using errcode='22023';end if;
 payload:=jsonb_build_object('invoice',p_invoice,'shift',p_shift,'amount',p_expected_payable,'credit_version',p_credit_version);
 perform pg_advisory_xact_lock(hashtextextended('cashier-adjusted-cash:'||p_request::text,0));
 select *into prior from private.cashier_adjusted_cash_confirmations where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable adjusted cash request'using errcode='22023';end if;return private.confirm_cashier_cash_payment(p_request,p_shift,p_invoice)||jsonb_build_object('amount',prior.amount,'credit_version',prior.credit_version);end if;
 perform 1 from public.business_cashier_shifts where shift_id=p_shift and branch_id=posted.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))and status='open'for update;
 if not found then raise exception 'Authorized open shift required'using errcode='42501';end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 if p_expected_payable<>private.cashier_invoice_payable(p_invoice)or p_credit_version<>private.cashier_unpaid_credit_version(p_invoice)then raise exception 'Payable or credits changed; review current amount before collecting'using errcode='40001';end if;
 insert into private.cashier_adjusted_cash_confirmations(request_id,invoice_id,shift_id,actor_id,amount,credit_version,payload,creator_xid)values(p_request,p_invoice,p_shift,actor,p_expected_payable,p_credit_version,payload,txid_current());
 result:=private.confirm_cashier_cash_payment(p_request,p_shift,p_invoice);return result||jsonb_build_object('amount',p_expected_payable,'credit_version',p_credit_version);
end$$;
create function public.confirm_cashier_adjusted_cash(p_request uuid,p_shift uuid,p_invoice text,p_expected_payable numeric,p_credit_version text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_adjusted_cash(p_request,p_shift,p_invoice,p_expected_payable,p_credit_version)$$;
revoke all on function private.confirm_cashier_adjusted_cash(uuid,uuid,text,numeric,text),public.confirm_cashier_adjusted_cash(uuid,uuid,text,numeric,text)from public,anon,authenticated,service_role;
grant execute on function private.confirm_cashier_adjusted_cash(uuid,uuid,text,numeric,text),public.confirm_cashier_adjusted_cash(uuid,uuid,text,numeric,text)to authenticated;
commit;
