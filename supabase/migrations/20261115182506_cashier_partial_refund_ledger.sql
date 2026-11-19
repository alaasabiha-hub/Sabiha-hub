begin;
-- Append-only cash refunds from original snapshots. Active/unstarted services
-- require a separate stop/cancellation adapter and are rejected, never freed silently.
create sequence private.cashier_refund_reference_seq;
revoke all on sequence private.cashier_refund_reference_seq from public,anon,authenticated,service_role;
create table private.cashier_partial_refunds(
 request_id uuid primary key,refund_number bigint not null unique,invoice_id text not null references private.cashier_invoice_postings(invoice_id),
 actor_id uuid not null references auth.users(id),shift_id uuid not null references public.business_cashier_shifts(shift_id),payload jsonb not null,
 amount numeric(12,2)not null check(amount>=0),reason text not null,result jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(request_id,invoice_id));
create table private.cashier_partial_refund_lines(
 request_id uuid not null,invoice_id text not null,line_id text not null,quantity integer not null check(quantity>0),restock boolean not null,
 amount numeric(12,2)not null check(amount>=0),tax_amount_exact numeric(18,5)not null,discount_exact numeric(18,5)not null,
 snapshot jsonb not null,primary key(request_id,line_id),foreign key(request_id,invoice_id)references private.cashier_partial_refunds(request_id,invoice_id));
create index cashier_partial_refund_totals on private.cashier_partial_refund_lines(invoice_id,line_id);
do $$declare t text;begin foreach t in array array['cashier_partial_refunds','cashier_partial_refund_lines']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_cashier_partial_refund before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end loop;end$$;
alter table public.business_payment_events add column refund_part_id uuid references private.cashier_partial_refunds(request_id)deferrable initially deferred;
alter table public.business_payment_events drop constraint business_payment_events_invoice_id_event_type_key;
create unique index one_invoice_sale_event on public.business_payment_events(invoice_id)where event_type='sale';
create unique index one_invoice_legacy_full_refund on public.business_payment_events(invoice_id)where event_type='refund'and refund_part_id is null;
create unique index one_cashier_partial_refund_payment on public.business_payment_events(refund_part_id)where refund_part_id is not null;
create function private.refund_cashier_invoice_lines(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
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
 if exists(select 1 from private.cashier_service_worklines w join public.business_orders o using(order_id)where w.invoice_id=p_invoice and w.line_id=entry->>'line_id'and w.unit_number>previous_quantity and w.unit_number<=previous_quantity+quantity and o.status not in('completed','delivered'))then raise exception 'Unfinished service requires a coordinated cancellation/stop adapter; no refund or capacity release performed'using errcode='55000';end if;
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
end$$;
create function public.refund_cashier_invoice_lines(p_request uuid,p_shift uuid,p_invoice text,p_lines jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.refund_cashier_invoice_lines(p_request,p_shift,p_invoice,p_lines,p_reason)$$;
revoke all on function private.refund_cashier_invoice_lines(uuid,uuid,text,jsonb,text),public.refund_cashier_invoice_lines(uuid,uuid,text,jsonb,text)from public,anon,authenticated,service_role;
grant execute on function private.refund_cashier_invoice_lines(uuid,uuid,text,jsonb,text),public.refund_cashier_invoice_lines(uuid,uuid,text,jsonb,text)to authenticated;

create function private.guard_cashier_partial_payment()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.refund_part_id is not null then
 if new.event_type<>'refund'or new.method<>'cash'or not exists(select 1 from private.cashier_partial_refunds r where r.request_id=new.refund_part_id and r.request_id=new.payment_id and r.invoice_id=new.invoice_id and r.actor_id=auth.uid()and r.creator_xid=txid_current()and r.amount=new.amount and r.shift_id=new.shift_id)then raise exception 'Exact current canonical partial-refund proof required'using errcode='42501';end if;
 end if;return new;end$$;
revoke all on function private.guard_cashier_partial_payment()from public,anon,authenticated,service_role;
create trigger guard_cashier_partial_payment before insert on public.business_payment_events for each row execute function private.guard_cashier_partial_payment();
CREATE OR REPLACE FUNCTION private.cashier_refund_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;r private.cashier_full_refunds;s record;begin
 select *into p from private.cashier_invoice_postings where invoice_id=new.invoice_id;if not found then return new;end if;
 perform private.cashier_cart_actor(p.branch_id);
 if new.refund_part_id is not null then return new;end if;
 if new.event_type='sale'then if new.amount<>(p.quote->>'total')::numeric then raise exception 'Original amount required'using errcode='55000';end if;return new;end if;
 select *into r from private.cashier_full_refunds where payment_id=new.payment_id and invoice_id=new.invoice_id and creator_xid=txid_current()and actor_id=auth.uid();
 if not found or new.amount<>(p.quote->>'total')::numeric then raise exception 'Explicit canonical full refund required'using errcode='55000';end if;
 if not r.restock then return new;end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(p.quote->'lines'))order by c.item_id for update;
 for s in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(p.quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid group by c.item_id,c.stock_quantity order by c.item_id loop
 update public.business_catalog_items set stock_quantity=s.stock_quantity+s.quantity,updated_at=clock_timestamp()where item_id=s.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(new.payment_id,p.branch_id,s.item_id,'pos_refund',s.stock_quantity,s.stock_quantity+s.quantity,r.reason,auth.uid(),p.invoice_id);
 end loop;return new;end$function$;
CREATE OR REPLACE FUNCTION private.guard_cashier_posting()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;begin
 if tg_table_schema='private'then
 if exists(select 1 from private.cashier_invoice_postings where draft_id=old.draft_id)then raise exception 'Issued draft and customer binding are sealed'using errcode='55000';end if;return new;
 end if;
 select *into p from private.cashier_invoice_postings where invoice_id=case when tg_op='DELETE'then old.invoice_id else new.invoice_id end;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Issued invoice is retained'using errcode='55000';end if;
 if tg_op='INSERT'then
 if private.cashier_invoice_has_services(p.invoice_id)and(new.commission_model<>'cashier_frozen_lines'or(select count(*)from private.cashier_service_worklines where invoice_id=p.invoice_id)<>(select sum((v->>'quantity')::integer)from jsonb_array_elements(p.quote->'lines')v where v->>'item_type'='service'))then raise exception 'Complete service work bindings required'using errcode='55000';end if;
 if p.creator_xid<>txid_current()or new.order_id<>p.order_id or new.branch_id<>p.branch_id or new.total<>(p.quote->>'total')::numeric or new.discount<>round((p.quote->>'invoice_discount_exact')::numeric,2) or new.sale_type<>(case when private.cashier_invoice_has_services(p.invoice_id)then'mixed'else'product'end)or new.commission_total<>0 or new.commission_share<>0 or new.workers<>'[]'::jsonb or new.reward_snapshot is not null then raise exception 'Complete original posting proof required'using errcode='55000';end if;
 else
 if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued financial terms are immutable'using errcode='55000';end if;
 if new.status is distinct from old.status and not(new.status='refunded'and (exists(select 1 from private.cashier_full_refunds r where r.invoice_id=p.invoice_id and r.creator_xid=txid_current())or(exists(select 1 from private.cashier_partial_refunds r where r.invoice_id=p.invoice_id and r.creator_xid=txid_current())and(select coalesce(sum(amount),0)from public.business_payment_events where invoice_id=p.invoice_id and event_type='refund')=new.total)))then raise exception 'Use canonical refund or cancellation'using errcode='55000';end if;
 end if;return new;end$function$;
CREATE OR REPLACE FUNCTION private.refund_cashier_invoice(p_request uuid, p_shift uuid, p_invoice text, p_restock boolean, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare p private.cashier_invoice_postings;prior private.cashier_full_refunds;payload jsonb;actor uuid;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;
 if not found then raise exception 'Cashier-issued invoice required'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);
 if private.cashier_invoice_has_services(p_invoice)then raise exception 'Service-aware refund policy adapter pending; no refund performed'using errcode='55000';end if;
 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Explicit refund permission required'using errcode='42501';end if;
 if p_request is null or p_restock is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit stock-return decision and reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('shift',p_shift,'invoice',p_invoice,'restock',p_restock,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('cashier-full-refund:'||p_request,0));select *into prior from private.cashier_full_refunds where request_id=p_request;
 if found then if prior.actor_id<>actor or prior.payload<>payload then raise exception 'Immutable refund request'using errcode='22023';end if;return prior.payment_id;end if;
 perform 1 from public.business_cashier_shifts where shift_id=p_shift and branch_id=p.branch_id and(cashier_id=actor or private.active_staff_role()in('owner','manager'))for update;
 if not found then raise exception 'Authorized shift required'using errcode='42501';end if;
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 if exists(select 1 from private.cashier_partial_refunds where invoice_id=p_invoice)then raise exception 'Use remaining original-line refunds after a partial refund'using errcode='55000';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already refunded'using errcode='40001';end if;
 insert into private.cashier_full_refunds values(p_request,actor,payload,p_invoice,p_request,p_restock,trim(p_reason),txid_current());
 return private.record_shift_payment(p_request,p_shift,p_invoice,'refund','cash');
end$function$;
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
 if p_event='sale' and i.status<>'active' then raise exception 'Invoice is not active';end if;
 if p_event='refund' then
  select * into sale from public.business_payment_events where invoice_id=p_invoice and event_type='sale';
  if not found or sale.method<>p_method then raise exception 'A matching recorded payment is required for refund';end if;
 end if;
 insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id) values(p_request,p_shift,p_invoice,p_event,p_method,case when p_event='refund' then sale.amount else i.total end,auth.uid());
 if p_event='refund' then update public.business_invoices set status='refunded' where invoice_id=p_invoice;else update public.business_invoices set payment_method=p_method where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'record_'||p_event,'business_payment_events',p_request::text,s.branch_id,jsonb_build_object('invoice_id',p_invoice,'method',p_method,'amount',case when p_event='refund' then sale.amount else i.total end));return p_request;
end; $function$;
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
 if new.status='cancelled'and old.status<>'cancelled'then raise exception 'Use canonical refund; legacy cancellation cannot restore posted stock'using errcode='55000';end if;
 return new;end$function$;
CREATE OR REPLACE FUNCTION private.enqueue_payment_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare p public.business_printers%rowtype;v_branch uuid;begin
 if new.refund_part_id is not null then return new;end if;
 select branch_id into v_branch from public.business_invoices where invoice_id=new.invoice_id;
 select * into p from public.business_printers where branch_id=v_branch and is_default and is_active and auto_print;
 if found then insert into public.business_print_jobs(job_id,invoice_id,branch_id,printer_id,payment_id,purpose,requested_by,is_reprint)
 values(gen_random_uuid(),new.invoice_id,v_branch,p.printer_id,new.payment_id,'automatic',new.actor_id,new.event_type='refund') on conflict(payment_id,purpose) do nothing;end if;return new;end; $function$;
CREATE OR REPLACE FUNCTION private.invoice_document_data_before_cashier_partial(p_token uuid, p_allow_revoked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare invoice_branch uuid;
begin
 select branch_id into invoice_branch from public.business_invoices where document_token=p_token;
 perform private.require_typed_reward_document_session(invoice_branch);
 return private.invoice_document_data_before_typed_session_guard(p_token,p_allow_revoked);
end $function$;
revoke all on function private.invoice_document_data_before_cashier_partial(uuid,boolean)from public,anon,authenticated,service_role;
create or replace function private.invoice_document_data(p_token uuid,p_allow_revoked boolean)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare doc jsonb;paid numeric;refunded numeric;history jsonb;begin
 doc:=private.invoice_document_data_before_cashier_partial(p_token,p_allow_revoked);
 if not exists(select 1 from private.cashier_partial_refunds where invoice_id=doc->>'invoice_id')then return doc;end if;
 select coalesce(sum(amount)filter(where event_type='sale'),0),coalesce(sum(amount)filter(where event_type='refund'),0)into paid,refunded from public.business_payment_events where invoice_id=doc->>'invoice_id';
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'refund_number',result->>'refund_number','amount',amount,'created_at',created_at)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=doc->>'invoice_id';
 return doc||jsonb_build_object('refund_amount',refunded,'net_collected',paid-refunded,'remaining_refundable',paid-refunded,'refund_history',history,'payment_status',case when refunded>0 and refunded<paid then'partially_refunded'else doc->>'payment_status'end);
end$$;
create function private.get_invoice_refund_document(p_request uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare r private.cashier_partial_refunds;token uuid;doc jsonb;begin
 select *into r from private.cashier_partial_refunds where request_id=p_request;
 if not found then raise exception 'Refund document unavailable'using errcode='42501';end if;
 select document_token into token from public.business_invoices where invoice_id=r.invoice_id;
 doc:=private.invoice_document_data(token,false); -- All existing live-session and ownership checks run first.
 return doc||jsonb_build_object('refund_receipt',jsonb_build_object('refund_id',r.request_id,'refund_number',r.result->>'refund_number','created_at',r.created_at,'amount',r.amount,'currency','EGP','payment_event_recorded',r.amount>0,'lines',r.result->'lines','eta_credit_note_accepted',false));
end$$;
create function public.get_invoice_refund_document(p_request uuid)returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select private.get_invoice_refund_document(p_request)$$;
revoke all on function private.get_invoice_refund_document(uuid),public.get_invoice_refund_document(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_invoice_refund_document(uuid),public.get_invoice_refund_document(uuid)to authenticated;
CREATE OR REPLACE FUNCTION private.shift_invoice_options(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;begin
 if not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Cashier branch permission required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'total',i.total,'status',i.status,'paid',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale'),'refunded',case when exists(select 1 from private.cashier_partial_refunds where invoice_id=i.invoice_id)then coalesce((select sum(amount)filter(where event_type='refund')>=sum(amount)filter(where event_type='sale')from public.business_payment_events where invoice_id=i.invoice_id),false)else exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='refund')end,'refunded_amount',coalesce((select sum(amount)from public.business_payment_events where invoice_id=i.invoice_id and event_type='refund'),0),'partially_refunded',coalesce((select sum(amount)filter(where event_type='refund')>0 and sum(amount)filter(where event_type='refund')<sum(amount)filter(where event_type='sale')from public.business_payment_events where invoice_id=i.invoice_id),false))),'[]') into result from (select * from public.business_invoices where branch_id=p_branch and status<>'void' and not(total=0 and coalesce(private.reward_invoice_coverage(invoice_id)->>'state'='covered_by_reward',false)) order by issued_at desc limit 200) i;return result;
end; $function$;
notify pgrst,'reload schema';
commit;
