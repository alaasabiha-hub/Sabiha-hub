begin;
-- No acquiring SDK, card data, or money transfer. Manual attestations are fenced off by default.
create table private.card_terminal_runtime(singleton boolean primary key default true check(singleton),manual_enabled boolean not null default false);
insert into private.card_terminal_runtime values(true,false);
create table private.card_terminal_confirmations(
 request_id uuid primary key,payment_id uuid not null unique references public.business_payment_events(payment_id)deferrable initially deferred,
 invoice_id text not null unique references public.business_invoices(invoice_id),shift_id uuid not null references public.business_cashier_shifts(shift_id),
 branch_id uuid not null references public.business_branches(branch_id),actor_id uuid not null references auth.users(id),
 terminal_id text not null,reference text not null,amount numeric(12,2)not null check(amount>0),credit_version text,
 attestation_language text not null check(attestation_language in('ar','en')),created_at timestamptz not null default clock_timestamp(),creator_xid bigint not null,
 unique(branch_id,terminal_id,reference));
create table private.customer_order_payment_preferences(
 request_id uuid primary key,customer_id uuid not null references public.customers(id),order_id uuid not null unique references public.business_orders(order_id),
 preference text not null check(preference in('cash_on_receipt','card_terminal')),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['card_terminal_runtime','card_terminal_confirmations','customer_order_payment_preferences']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 if t<>'card_terminal_runtime'then execute format('create trigger immutable_terminal_evidence before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end if;
end loop;end$$;
alter table public.business_payment_events drop constraint business_payment_events_method_check;
alter table public.business_payment_events add constraint business_payment_events_method_check check(method in('cash','electronic','card_terminal'));
create function private.confirm_cashier_terminal_payment(p_request uuid,p_shift uuid,p_invoice text,p_terminal text,p_reference text,p_verified boolean,p_language text,p_expected_amount numeric,p_credit_version text)returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;i public.business_invoices;s public.business_cashier_shifts;c private.card_terminal_confirmations;amount numeric;cv text;
begin
 select *into i from public.business_invoices where invoice_id=p_invoice;
 if not found then raise exception 'Invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(i.branch_id);
 if p_request is null or p_shift is null or p_verified is distinct from true or p_language not in('ar','en')or p_language is null
 or coalesce(p_terminal,'')!~'^[A-Za-z0-9_-]{2,60}$'or coalesce(p_reference,'')!~'^[A-Za-z0-9._-]{4,80}$'or p_reference~'[0-9]{12}'or p_expected_amount is null then raise exception 'Verified terminal receipt, non-card reference and exact reviewed amount required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('terminal-request:'||p_request,0));
 select *into c from private.card_terminal_confirmations where request_id=p_request;
 if found then
 if c.actor_id<>actor or c.invoice_id<>p_invoice or c.shift_id<>p_shift then raise exception 'Terminal request unavailable'using errcode='42501';end if;
 if c.terminal_id<>p_terminal or c.reference<>p_reference or c.attestation_language<>p_language or c.amount<>p_expected_amount or c.credit_version is distinct from p_credit_version then raise exception 'Immutable terminal confirmation'using errcode='22023';end if;
 return jsonb_build_object('invoice_id',c.invoice_id,'payment_id',c.payment_id,'sale_recorded',true,'method','card_terminal');end if;
 if not coalesce((select manual_enabled from private.card_terminal_runtime where singleton),false)then raise exception 'Terminal activation requires merchant approval'using errcode='55000';end if;
 select *into s from public.business_cashier_shifts where shift_id=p_shift for update;
 if not found or s.branch_id<>i.branch_id or(s.cashier_id<>actor and private.active_staff_role()not in('owner','manager'))or s.status<>'open'then raise exception 'Authorized open branch shift required'using errcode='42501';end if;
 select *into i from public.business_invoices where invoice_id=p_invoice for update;
 if i.status<>'active'or exists(select 1 from public.business_payment_events where invoice_id=p_invoice and event_type='sale')then raise exception 'Invoice not payable or already collected'using errcode='40001';end if;
 if exists(select 1 from private.cashier_invoice_postings where invoice_id=p_invoice)then amount:=private.cashier_invoice_payable(p_invoice);cv:=private.cashier_unpaid_credit_version(p_invoice);else amount:=i.total;end if;
 if amount<=0 or amount<>p_expected_amount or cv is distinct from p_credit_version then raise exception 'Payable terms changed; review again'using errcode='40001';end if;
 insert into private.card_terminal_confirmations values(p_request,p_request,p_invoice,p_shift,i.branch_id,actor,p_terminal,p_reference,amount,cv,p_language,clock_timestamp(),txid_current());
 insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id)values(p_request,p_shift,p_invoice,'sale','card_terminal',amount,actor);
 update public.business_invoices set payment_method='card_terminal'where invoice_id=p_invoice;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'manual_terminal_receipt_verified','business_payment_events',p_request::text,i.branch_id,jsonb_build_object('invoice_id',p_invoice,'terminal_id',p_terminal,'reference',p_reference,'amount',amount,'evidence_type','cashier_verified_external_terminal_receipt'));
 return jsonb_build_object('invoice_id',p_invoice,'payment_id',p_request,'sale_recorded',true,'method','card_terminal');
end$$;
create function public.confirm_cashier_terminal_payment(p_request uuid,p_shift uuid,p_invoice text,p_terminal text,p_reference text,p_verified boolean,p_language text,p_expected_amount numeric,p_credit_version text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_terminal_payment(p_request,p_shift,p_invoice,p_terminal,p_reference,p_verified,p_language,p_expected_amount,p_credit_version)$$;
revoke all on function private.confirm_cashier_terminal_payment(uuid,uuid,text,text,text,boolean,text,numeric,text),public.confirm_cashier_terminal_payment(uuid,uuid,text,text,text,boolean,text,numeric,text)from public,anon,authenticated,service_role;
grant execute on function private.confirm_cashier_terminal_payment(uuid,uuid,text,text,text,boolean,text,numeric,text),public.confirm_cashier_terminal_payment(uuid,uuid,text,text,text,boolean,text,numeric,text)to authenticated;
-- Direct INSERT cannot masquerade as a successful standalone-terminal operation.
create function private.guard_terminal_payment_evidence()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.method='card_terminal'and not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount and new.event_type='sale')then raise exception 'Exact current verified terminal receipt required'using errcode='42501';end if;return new;end$$;
revoke all on function private.guard_terminal_payment_evidence()from public,anon,authenticated,service_role;
create trigger terminal_payment_evidence before insert on public.business_payment_events for each row execute function private.guard_terminal_payment_evidence();
-- Refunds stay rejected until an audited external-terminal refund adapter is accepted.
create function private.place_product_order_with_payment(p_items jsonb,p_request_id uuid,p_customer_note text,p_coupon_code text,p_preference text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior private.customer_order_payment_preferences;result jsonb;payload jsonb;o public.business_orders;
begin
 if auth.uid()is null or p_request_id is null or p_preference is null or p_preference not in('cash_on_receipt','card_terminal')then raise exception 'Supported unpaid payment preference required'using errcode='22023';end if;
 perform private.require_typed_reward_document_session(null);
 payload:=jsonb_build_object('items',p_items,'note',p_customer_note,'coupon',p_coupon_code,'preference',p_preference);
 perform pg_advisory_xact_lock(hashtextextended('product-payment-preference:'||p_request_id,0));
 select *into prior from private.customer_order_payment_preferences where request_id=p_request_id;
 if found then if prior.customer_id<>auth.uid()then raise exception 'Order request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable order payment preference'using errcode='22023';end if;return prior.result;end if;
 select to_jsonb(placed)into result from public.place_customer_product_order(p_items,p_request_id,p_customer_note,p_coupon_code)placed;
 select *into o from public.business_orders where customer_request_id=p_request_id and customer_id=auth.uid();
 if not found then raise exception 'Owned order required'using errcode='42501';end if;
 result:=result||jsonb_build_object('payment_preference',p_preference,'payment_status',case when p_preference='card_terminal'then'awaiting_terminal_payment'else'unpaid'end);
 insert into private.customer_order_payment_preferences values(p_request_id,auth.uid(),o.order_id,p_preference,payload,result,clock_timestamp());return result;
end$$;
create function public.place_product_order_with_payment(p_items jsonb,p_request_id uuid,p_customer_note text,p_coupon_code text,p_preference text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.place_product_order_with_payment(p_items,p_request_id,p_customer_note,p_coupon_code,p_preference)$$;
revoke all on function private.place_product_order_with_payment(jsonb,uuid,text,text,text),public.place_product_order_with_payment(jsonb,uuid,text,text,text)from public,anon,authenticated,service_role;
grant execute on function private.place_product_order_with_payment(jsonb,uuid,text,text,text),public.place_product_order_with_payment(jsonb,uuid,text,text,text)to authenticated;
CREATE OR REPLACE FUNCTION private.cashier_refund_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;r private.cashier_full_refunds;s record;begin
 select *into p from private.cashier_invoice_postings where invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.cashier_cart_actor(p.branch_id);
 if new.refund_part_id is not null then return new;end if;
 if new.event_type='sale'then if exists(select 1 from private.cashier_unpaid_service_credits where invoice_id=new.invoice_id)and not exists(select 1 from private.cashier_adjusted_cash_confirmations c where c.request_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount and c.credit_version=private.cashier_unpaid_credit_version(new.invoice_id))and not exists(select 1 from private.card_terminal_confirmations c where new.method='card_terminal'and c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount and c.credit_version=private.cashier_unpaid_credit_version(new.invoice_id))then raise exception 'Explicit current adjusted cash confirmation required'using errcode='42501';end if;if new.amount<>private.cashier_invoice_payable(p.invoice_id) then raise exception 'Original amount required'using errcode='55000';end if;return new;end if;
 select *into r from private.cashier_full_refunds where payment_id=new.payment_id and invoice_id=new.invoice_id and creator_xid=txid_current()and actor_id=auth.uid();
 if not found or new.amount<>(p.quote->>'total')::numeric then raise exception 'Explicit canonical full refund required'using errcode='55000';end if;
 if not r.restock then return new;end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(p.quote->'lines'))order by c.item_id for update;
 for s in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(p.quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=s.stock_quantity+s.quantity,updated_at=clock_timestamp()where item_id=s.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(new.payment_id,p.branch_id,s.item_id,'pos_refund',s.stock_quantity,s.stock_quantity+s.quantity,r.reason,auth.uid(),p.invoice_id);
 end loop;return new;end$function$;
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
 invoice:=jsonb_build_object('id',i.invoice_id,'number',i.display_number,'token',i.document_token,'total',i.total,'payable',private.cashier_invoice_payable(i.invoice_id),'unpaid_credit_amount',private.cashier_invoice_unpaid_credit(i.invoice_id),'credit_version',private.cashier_unpaid_credit_version(i.invoice_id),'status',i.status,'refunded_amount',refunded,'net_collected',coalesce(sale.amount,0)-refunded,'payment_status',case when i.status='void'then'cancelled'when i.status='refunded'then'refunded'when sale.payment_id is null and private.cashier_invoice_payable(i.invoice_id)=0 then'settled_by_credit'when sale.payment_id is null then'unpaid'when refunded>0 and refunded<sale.amount then'partially_refunded'when sale.method in('cash','card_terminal')then'paid'else'verification_required'end,'cash_confirmed',sale.payment_id is not null and sale.method='cash');
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'number',result->>'refund_number','amount',amount,'payment_event_recorded',amount>0)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=p.invoice_id;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids),'can_cancel',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.method='cash'and sale.amount=private.cashier_invoice_payable(i.invoice_id) and (select coalesce(sum(r.quantity),0)from private.cashier_partial_refund_lines r where r.invoice_id=w.invoice_id and r.line_id=w.line_id)<w.unit_number,'can_cancel_unpaid',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.payment_id is null and not exists(select 1 from private.paymob_intents where invoice_id=i.invoice_id),'unpaid_credit_preview_amount',(private.cashier_refund_slice_core(p.quote,w.line_id,w.unit_number-1,1)->>'amount')::numeric,'physical_clearance_required',o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans sp where sp.booking_id=w.booking_id and sp.ended_at is null))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and sale.method='cash'and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
 for line in select value from jsonb_array_elements(p.quote->'lines')loop
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p.invoice_id and x.line_id=line->>'line_id';
 remaining:=(line->>'quantity')::integer-previous_quantity-(select count(*)from private.cashier_unpaid_service_credits c where c.invoice_id=p.invoice_id and c.line_id=line->>'line_id');ready:=remaining;
 if line->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then ready:=0;
 else select coalesce(min(pos)-previous_quantity-1,remaining)into ready from(
 select row_number()over(order by w.unit_number)pos,(o.status in('completed','delivered')or(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id)))ready_state
 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p.invoice_id and w.line_id=line->>'line_id'and not exists(select 1 from private.cashier_unpaid_service_credits c where c.invoice_id=w.invoice_id and c.line_id=w.line_id and c.unit_number=w.unit_number))x where pos>previous_quantity and not ready_state;end if;
 end if;
 if remaining>0 then refundable:=refundable||jsonb_build_array(jsonb_build_object('line_id',line->'line_id','name',line->'name','name_en',line->'name_en','item_type',line->'item_type','remaining_quantity',remaining,'refundable_quantity',greatest(ready,0)));end if;
 end loop;end if;
 end if;
 return jsonb_build_object('kind','cashier_checkout_state_v1','draft_id',p_draft,'draft_version',d.version,'branch_id',p_branch,'role',private.active_staff_role(),'time_zone',b.time_zone,'local_today',(clock_timestamp()at time zone b.time_zone)::date,'local_now',clock_timestamp()at time zone b.time_zone,'binding',private.get_cashier_draft_subject(p_branch,p_draft),'state',case when p.invoice_id is null then'draft'else'issued'end,'invoice',invoice,'open_shifts',shifts,'work',coalesce(work,'[]'),'refunds',coalesce(history,'[]'),'refundable_lines',refundable,'can_refund',can_refund,'live_electronic_enabled',false,'terminal_manual_enabled',coalesce((select manual_enabled from private.card_terminal_runtime where singleton),false),'offline_profile_issue_supported',true,'bundle_loyalty_accrual_supported',false);
end$function$;
CREATE OR REPLACE FUNCTION private.cashier_shift_totals(p_shift uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare s public.business_cashier_shifts%rowtype;v_cash numeric;v_electronic numeric;v_movements numeric;begin
 select * into strict s from public.business_cashier_shifts where shift_id=p_shift;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(s.branch_id),false) or (s.cashier_id<>auth.uid() and private.active_staff_role() not in ('owner','manager')) then raise exception 'Shift access denied';end if;
 select coalesce(sum(case when event_type='sale' then amount else -amount end) filter(where method='cash'),0),coalesce(sum(case when event_type='sale' then amount else -amount end) filter(where method='electronic'),0) into v_cash,v_electronic from public.business_payment_events where shift_id=p_shift;
 select coalesce(sum(case when movement_type='deposit' then amount else -amount end),0) into v_movements from public.business_shift_cash_movements where shift_id=p_shift;
 return jsonb_build_object('shift_id',p_shift,'branch_id',s.branch_id,'status',s.status,'opening_cash',s.opening_cash,'cash_payments_net',v_cash,'electronic_payments_net',v_electronic,'cash_movements_net',v_movements,'card_terminal_payments_net',(select coalesce(sum(case when event_type='sale'then amount else -amount end),0)from public.business_payment_events where shift_id=p_shift and method='card_terminal'),'expected_cash',s.opening_cash+v_cash+v_movements,'actual_cash',s.actual_cash,'difference',s.difference,'difference_reason',s.difference_reason);
end; $function$;
create function private.get_customer_payment_options()returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 perform private.require_typed_reward_document_session(null);
 return jsonb_build_object('cash_on_receipt',true,'card_terminal_intent_supported',true,'online_enabled',false,'card_data_requested',false,'terminal_intent_is_payment',false);
end$$;
create function public.get_customer_payment_options()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_customer_payment_options()$$;
revoke all on function private.get_customer_payment_options(),public.get_customer_payment_options()from public,anon,authenticated,service_role;
grant execute on function private.get_customer_payment_options(),public.get_customer_payment_options()to authenticated;
commit;
