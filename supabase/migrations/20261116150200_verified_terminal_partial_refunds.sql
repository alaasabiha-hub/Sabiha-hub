begin;
create table private.card_terminal_refund_receipts(
 request_id uuid primary key,payment_id uuid not null unique references public.business_payment_events(payment_id)deferrable initially deferred,
 invoice_id text not null references private.cashier_invoice_postings(invoice_id),shift_id uuid not null references public.business_cashier_shifts(shift_id),
 actor_id uuid not null references auth.users(id),branch_id uuid not null references public.business_branches(branch_id),terminal_id text not null,reference text not null,
 payload jsonb not null,amount numeric(12,2)not null check(amount>0),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(branch_id,terminal_id,reference));
alter table private.card_terminal_refund_receipts enable row level security;
revoke all on private.card_terminal_refund_receipts from public,anon,authenticated,service_role;
create trigger immutable_verified_terminal_refund before update or delete on private.card_terminal_refund_receipts for each row execute function private.immutable_loyalty_policy();
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
 select pe.amount into paid from public.business_payment_events pe where pe.invoice_id=p_invoice and pe.event_type='sale'and pe.method in('cash','card_terminal');if not found then raise exception 'Confirmed cash payment required'using errcode='55000';end if;
 for entry in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(entry)is distinct from'object'or(select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['line_id','quantity','restock'])or jsonb_typeof(entry->'line_id')is distinct from'string'or jsonb_typeof(entry->'quantity')is distinct from'number'or(entry->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(entry->'restock')is distinct from'boolean'then raise exception 'Line identity, integer quantity and stock-return choice only'using errcode='22023';end if;
 select value into original from jsonb_array_elements(p.quote->'lines')where value->>'line_id'=entry->>'line_id';if original is null then raise exception 'Original line unavailable'using errcode='42501';end if;
 quantity:=(entry->>'quantity')::integer;select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p_invoice and x.line_id=entry->>'line_id';
 slice:=private.cashier_paid_refund_slice(p_invoice,entry->>'line_id',previous_quantity,quantity);
 if original->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then raise exception 'Service refund requires management'using errcode='42501';end if;
 if(entry->>'restock')::boolean or exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number in(select value::integer from jsonb_array_elements_text(slice->'unit_numbers')) and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id))))or(select count(*)from private.cashier_service_worklines where invoice_id=p_invoice and line_id=entry->>'line_id'and unit_number in(select value::integer from jsonb_array_elements_text(slice->'unit_numbers')))<>quantity then raise exception 'Completed service units required; cancellation is separate'using errcode='55000';end if;
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

 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Explicit refund permission required'using errcode='42501';end if;
 if p_request is null or p_shift is null or jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Exact original lines, quantities and reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('invoice',p_invoice,'shift',p_shift,'lines',p_lines,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('cashier-partial-refund:'||p_request,0));select *into prior from private.cashier_partial_refunds where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable refund request'using errcode='22023';end if;return prior.result;end if;
 select *into shift from public.business_cashier_shifts where shift_id=p_shift and branch_id=p.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))for update;
 if not found then raise exception 'Authorized branch shift required'using errcode='42501';end if;if shift.status<>'open'then raise exception 'Open shift required'using errcode='55000';end if;
 select *into strict i from public.business_invoices where invoice_id=p_invoice for update;
 select *into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
 if not found or sale.method not in('cash','card_terminal')or i.status='void'then raise exception 'Confirmed cash payment required; electronic refunds require the gateway adapter'using errcode='55000';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already fully refunded'using errcode='40001';end if;
 if(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'One explicit quantity per original line required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(entry)is distinct from'object'or(select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['line_id','quantity','restock'])or jsonb_typeof(entry->'line_id')is distinct from'string'or jsonb_typeof(entry->'quantity')is distinct from'number'or(entry->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(entry->'restock')is distinct from'boolean'then raise exception 'Original line, integer quantity and stock-return decision only'using errcode='22023';end if;
 select value into original from jsonb_array_elements(p.quote->'lines')where value->>'line_id'=entry->>'line_id';
 if original is null then raise exception 'Original invoice line unavailable'using errcode='42501';end if;
 quantity:=(entry->>'quantity')::integer;
 select coalesce(sum(x.quantity),0)::integer into previous_quantity from private.cashier_partial_refund_lines x where x.invoice_id=p_invoice and x.line_id=entry->>'line_id';
 slice:=private.cashier_paid_refund_slice(p_invoice,entry->>'line_id',previous_quantity,quantity);
 if original->>'item_type'='service'then
 if private.active_staff_role()not in('owner','manager')then raise exception 'Service financial refunds require management'using errcode='42501';end if;
 if(entry->>'restock')::boolean then raise exception 'A service cannot return product stock'using errcode='22023';end if;
 if exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number in(select value::integer from jsonb_array_elements_text(slice->'unit_numbers')) and (o.status not in('completed','delivered')and not(o.status='cancelled'and exists(select 1 from private.cashier_service_cancellations stop where stop.order_id=w.order_id and stop.booking_id=w.booking_id and stop.invoice_id=w.invoice_id))))then raise exception 'Unfinished service requires a coordinated cancellation/stop adapter; no refund or capacity release performed'using errcode='55000';end if;
 if(select count(*)from private.cashier_service_worklines w where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number in(select value::integer from jsonb_array_elements_text(slice->'unit_numbers')))<>quantity then raise exception 'Complete service-unit coverage required'using errcode='55000';end if;
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
 if amount>0 then insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id,refund_part_id)values(p_request,p_shift,p_invoice,'refund',sale.method,amount,actor,p_request);end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(prepared)where value->>'item_type'='product'and(value->>'restock')::boolean)order by c.item_id for update;
 for stock in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(prepared)x on c.item_id=(x.value->>'item_id')::uuid where x.value->>'item_type'='product'and(x.value->>'restock')::boolean group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=stock.stock_quantity+stock.quantity,updated_at=clock_timestamp()where item_id=stock.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(p_request,p.branch_id,stock.item_id,'pos_refund',stock.stock_quantity,stock.stock_quantity+stock.quantity,trim(p_reason),actor,p_invoice);
 end loop;
 if prior_refund+amount=sale.amount and i.status='active'then update public.business_invoices set status='refunded'where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data,reason)values(actor::text,actor,'cashier_partial_refund','business_invoices',p_invoice,p.branch_id,jsonb_build_object('refund_id',p_request,'amount',amount,'lines',prepared,'earned_commissions_retained',true),trim(p_reason));
 return result;
end$function$;
CREATE OR REPLACE FUNCTION private.guard_cashier_partial_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$begin
 if new.refund_part_id is not null then
 if new.event_type<>'refund'or new.method not in('cash','card_terminal')or not exists(select 1 from private.cashier_partial_refunds r where r.request_id=new.refund_part_id and r.request_id=new.payment_id and r.invoice_id=new.invoice_id and r.actor_id=auth.uid()and r.creator_xid=txid_current()and r.amount=new.amount and r.shift_id=new.shift_id)then raise exception 'Exact current canonical partial-refund proof required'using errcode='42501';end if;
 end if;return new;end$function$;
create or replace function private.guard_terminal_payment_evidence()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.method='card_terminal'then
 if new.event_type='sale'then
 if not exists(select 1 from private.card_terminal_confirmations c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount)then raise exception 'Exact current verified terminal receipt required'using errcode='42501';end if;
 else
 if not exists(select 1 from private.card_terminal_refund_receipts c where c.payment_id=new.payment_id and c.invoice_id=new.invoice_id and c.shift_id=new.shift_id and c.actor_id=auth.uid()and c.creator_xid=txid_current()and c.amount=new.amount and new.refund_part_id=c.request_id)then raise exception 'Exact current verified terminal refund receipt required'using errcode='42501';end if;
 end if;end if;return new;end$$;
create function private.confirm_cashier_terminal_refund(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text,p_quote_hash text,p_reference text,p_verified boolean,p_language text)returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;original private.card_terminal_confirmations;prior private.card_terminal_refund_receipts;payload jsonb;preview jsonb;result jsonb;
begin
 select *into original from private.card_terminal_confirmations where invoice_id=p_invoice;
 if not found then raise exception 'Original verified terminal payment required'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(original.branch_id);
 if p_request is null or p_verified is distinct from true or p_language is null or p_language not in('ar','en')or coalesce(p_reference,'')!~'^[A-Za-z0-9._-]{4,80}$'or p_reference~'[0-9]{12}'then raise exception 'Verified refund receipt and reference required'using errcode='22023';end if;
 payload:=jsonb_build_object('invoice',p_invoice,'shift',p_shift,'lines',p_lines,'reason',p_reason,'quote_hash',p_quote_hash,'reference',p_reference,'language',p_language);
 perform pg_advisory_xact_lock(hashtextextended('cashier-partial-refund:'||p_request,0));
 select *into prior from private.card_terminal_refund_receipts where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Refund request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable terminal refund receipt'using errcode='22023';end if;return(select r.result from private.cashier_partial_refunds r where r.request_id=p_request);end if;
 if not coalesce((select manual_enabled from private.card_terminal_runtime where singleton),false)then raise exception 'Terminal activation requires merchant approval'using errcode='55000';end if;
 perform 1 from public.business_cashier_shifts where shift_id=p_shift and branch_id=original.branch_id and status='open'and(cashier_id=actor or private.active_staff_role()in('owner','manager'))for update;
 if not found then raise exception 'Authorized open branch shift required'using errcode='42501';end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 preview:=private.preview_cashier_refund_lines(p_invoice,p_lines);
 if preview->>'quote_hash'is distinct from p_quote_hash or(preview->>'amount')::numeric<=0 then raise exception 'Refund preview changed; review again'using errcode='40001';end if;
 insert into private.card_terminal_refund_receipts values(p_request,p_request,p_invoice,p_shift,actor,original.branch_id,original.terminal_id,p_reference,payload,(preview->>'amount')::numeric,txid_current(),clock_timestamp());
 result:=private.confirm_cashier_refund(p_request,p_shift,p_invoice,p_lines,p_reason,p_quote_hash);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data)values(actor::text,actor,'manual_terminal_refund_verified','business_payment_events',p_request::text,original.branch_id,p_reason,jsonb_build_object('original_payment',original.payment_id,'terminal',original.terminal_id,'reference',p_reference,'amount',preview->'amount'));
 return result;
end$$;
create function public.confirm_cashier_terminal_refund(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text,p_quote_hash text,p_reference text,p_verified boolean,p_language text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.confirm_cashier_terminal_refund(p_request,p_shift,p_invoice,p_lines,p_reason,p_quote_hash,p_reference,p_verified,p_language)$$;
revoke all on function private.confirm_cashier_terminal_refund(uuid,uuid,text,jsonb,text,text,text,boolean,text),public.confirm_cashier_terminal_refund(uuid,uuid,text,jsonb,text,text,text,boolean,text)from public,anon,authenticated,service_role;
grant execute on function private.confirm_cashier_terminal_refund(uuid,uuid,text,jsonb,text,text,text,boolean,text),public.confirm_cashier_terminal_refund(uuid,uuid,text,jsonb,text,text,text,boolean,text)to authenticated;
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
 invoice:=jsonb_build_object('id',i.invoice_id,'payment_method',i.payment_method,'number',i.display_number,'token',i.document_token,'total',i.total,'payable',private.cashier_invoice_payable(i.invoice_id),'unpaid_credit_amount',private.cashier_invoice_unpaid_credit(i.invoice_id),'credit_version',private.cashier_unpaid_credit_version(i.invoice_id),'status',i.status,'refunded_amount',refunded,'net_collected',coalesce(sale.amount,0)-refunded,'payment_status',case when i.status='void'then'cancelled'when i.status='refunded'then'refunded'when sale.payment_id is null and private.cashier_invoice_payable(i.invoice_id)=0 then'settled_by_credit'when sale.payment_id is null then'unpaid'when refunded>0 and refunded<sale.amount then'partially_refunded'when sale.method in('cash','card_terminal')then'paid'else'verification_required'end,'cash_confirmed',sale.payment_id is not null and sale.method='cash');
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'number',result->>'refund_number','amount',amount,'payment_event_recorded',amount>0)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=p.invoice_id;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids),'can_cancel',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.method='cash'and sale.amount=private.cashier_invoice_payable(i.invoice_id) and (select coalesce(sum(r.quantity),0)from private.cashier_partial_refund_lines r where r.invoice_id=w.invoice_id and r.line_id=w.line_id)<w.unit_number,'can_cancel_unpaid',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.payment_id is null and not exists(select 1 from private.paymob_intents where invoice_id=i.invoice_id),'unpaid_credit_preview_amount',(private.cashier_refund_slice_core(p.quote,w.line_id,w.unit_number-1,1)->>'amount')::numeric,'physical_clearance_required',o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans sp where sp.booking_id=w.booking_id and sp.ended_at is null))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and sale.method in('cash','card_terminal')and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
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
commit;
