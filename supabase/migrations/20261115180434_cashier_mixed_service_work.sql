begin;
alter table public.business_orders drop constraint business_orders_order_type_check;
alter table public.business_orders add constraint business_orders_order_type_check check(order_type in('service','product','mixed'));
alter table public.business_invoices drop constraint business_invoices_sale_type_check;
alter table public.business_invoices add constraint business_invoices_sale_type_check check(sale_type in('service','product','mixed'));
alter table public.business_invoices drop constraint business_invoices_commission_model_check;
alter table public.business_invoices add constraint business_invoices_commission_model_check check(commission_model in('legacy_scalar','walk_in_frozen_workers','cashier_frozen_lines'));
create table private.cashier_service_worklines(
 order_id uuid primary key references public.business_orders(order_id)deferrable initially deferred,
 booking_id uuid not null unique references public.bookings(id)deferrable initially deferred,
 invoice_id text not null references private.cashier_invoice_postings(invoice_id),
 line_id text not null,unit_number integer not null check(unit_number>0),branch_id uuid not null references public.business_branches(branch_id),
 item_id uuid not null references public.business_catalog_items(item_id),base_before_discount_exact numeric(18,5)not null check(base_before_discount_exact>=0),
 allocated_payable numeric(12,2)not null check(allocated_payable>=0),creator_xid bigint not null,unique(invoice_id,line_id,unit_number));
create table private.cashier_service_commissions(
 order_id uuid not null references private.cashier_service_worklines(order_id),staff_id uuid not null references public.staff_profiles(user_id),
 staff_name text not null,base_before_discount_exact numeric(18,5)not null,rate_percent numeric(7,4)not null check(rate_percent between 0 and 100),
 assigned_count integer not null check(assigned_count>0),amount numeric(12,2)not null check(amount>=0),employment_snapshot jsonb not null,
 started_at timestamptz not null default clock_timestamp(),primary key(order_id,staff_id),check(amount=round(base_before_discount_exact*rate_percent/100/assigned_count,2)));
create table private.cashier_service_earnings(order_id uuid not null,staff_id uuid not null,earned_at timestamptz not null default clock_timestamp(),work_event uuid not null references private.service_work_ledger(event_id),primary key(order_id,staff_id),foreign key(order_id,staff_id)references private.cashier_service_commissions(order_id,staff_id));
create table private.cashier_bundle_events(event_id uuid primary key default gen_random_uuid(),order_id uuid not null references public.business_orders(order_id),next_status text not null,source_event uuid not null references private.service_work_ledger(event_id),actor_id uuid not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(order_id,next_status));
do $$declare t text;begin foreach t in array array['cashier_service_worklines','cashier_service_commissions','cashier_service_earnings','cashier_bundle_events']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_cashier_service_data before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);end loop;end$$;
create function private.cashier_invoice_has_services(p_invoice text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select exists(select 1 from private.cashier_invoice_postings p cross join lateral jsonb_array_elements(p.quote->'lines')v where p.invoice_id=p_invoice and v->>'item_type'='service')$$;
revoke all on function private.cashier_invoice_has_services(text)from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION private.issue_cashier_mixed_invoice(p_request uuid, p_branch uuid, p_draft uuid, p_expected_draft_version integer, p_expected_binding_version integer, p_start timestamptz)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;prior private.cashier_invoice_postings;
 payload jsonb;current_quote jsonb;subject jsonb;invoice text;work uuid;line jsonb;number text;stock record;service public.business_catalog_items;next_slot timestamptz;zone text;unit integer;child uuid;booking uuid;staff uuid[];names jsonb;unit_base numeric;unit_payable numeric;resource text;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_draft_version is null or p_expected_binding_version is null then raise exception 'Saved draft and subject versions required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'draft',p_draft,'draft_version',p_expected_draft_version,'binding_version',p_expected_binding_version,'service_start',p_start);
 perform pg_advisory_xact_lock(hashtextextended('cashier-issue:'||p_request,0));select *into prior from private.cashier_invoice_postings where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable issuance request'using errcode='22023';end if;
 return jsonb_build_object('invoice_id',prior.invoice_id,'order_id',prior.order_id,'invoice_number',(select display_number from public.business_invoices where invoice_id=prior.invoice_id),'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);end if;
 select *into d from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if not found or d.actor_id<>actor or d.branch_id<>p_branch then raise exception 'Draft unavailable'using errcode='42501';end if;
 if d.version<>p_expected_draft_version or exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then raise exception 'Draft changed or already issued'using errcode='40001';end if;
 select *into b from private.cashier_draft_subjects where draft_id=p_draft for update;
 if not found or b.version<>p_expected_binding_version or b.draft_version<>d.version then raise exception 'Current customer/car confirmation required'using errcode='40001';end if;
 if b.subject_kind<>'app_customer' then raise exception 'Offline invoice history adapter is not ready; no invoice issued'using errcode='55000';end if;
 perform 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by c.item_id for update;
 perform 1 from private.owner_tax_active t where t.branch_id=p_branch and t.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(d.payload->'items'))order by t.item_id for share;
 current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->'items',d.payload->>'discount_mode',(d.payload->>'discount_value')::numeric);
 if(current_quote-'as_of')is distinct from(d.quote-'as_of')then raise exception 'Prices, stock or classification changed; save and confirm again'using errcode='40001';end if;
 if not exists(select 1 from jsonb_array_elements(current_quote->'lines')where value->>'item_type'='service')then raise exception 'Use the existing product issuing endpoint'using errcode='22023';end if;
 if p_start is null or not isfinite(p_start)or p_start<=clock_timestamp()or current_quote->>'staff_configuration_complete'<>'true'then raise exception 'Future service start and configured service workers required'using errcode='22023';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(current_quote->'lines')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'One-visit work must fit a business day; plan separate visits'using errcode='22023';end if;
 if exists(select 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(current_quote->'lines'))and c.item_type='product'and c.stock_quantity is null)then raise exception 'Tracked product stock required'using errcode='55000';end if;
 if(current_quote->>'total')::numeric<=0 then raise exception 'Positive payable invoice required; use the separately authorized reward route'using errcode='55000';end if;
 perform 1 from public.customers where id=b.subject_id for share;
 perform 1 from public.vehicles where id=b.car_id for share;
 subject:=private.cashier_subject_snapshot(p_branch,b.subject_kind,b.subject_id,b.car_id);
 if subject<>b.subject_snapshot then raise exception 'Customer or car changed; confirm again'using errcode='40001';end if;
 invoice:=gen_random_uuid()::text;work:=gen_random_uuid();
 insert into private.cashier_invoice_postings values(p_request,actor,payload,p_draft,invoice,work,p_branch,current_quote,subject,txid_current(),clock_timestamp());
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,order_type,branch_id,created_by)
 values(work,invoice,b.subject_id,subject->>'name',(select phone from public.customers where id=b.subject_id),subject->'car'->>'plate_number','خدمات ومنتجات / Services and products','mixed',p_branch,actor::text);
 for line in select value from jsonb_array_elements(current_quote->'lines')loop
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(work,(line->>'item_id')::uuid,line->>'name',(line->>'quantity')::integer,(line->>'unit_price')::numeric,(line->>'catalog_amount')::numeric);
 end loop;
 select time_zone into zone from public.business_branches where branch_id=p_branch;
 perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||b.car_id,0));
 for resource in select distinct c.resource_key from jsonb_array_elements(current_quote->'lines')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service'order by c.resource_key loop
 perform private.lock_service_resource_days(p_branch,resource,array[(p_start at time zone zone)::date,(p_start at time zone zone)::date+1]);end loop;
 next_slot:=p_start;
 for line in select value from jsonb_array_elements(current_quote->'lines')where value->>'item_type'='service'order by value->>'line_id'loop
 select *into strict service from public.business_catalog_items where item_id=(line->>'item_id')::uuid;
 select array_agg(value::uuid order by value::uuid)into staff from jsonb_array_elements_text(line->'staff_ids');
 select jsonb_agg(full_name order by user_id)into names from public.staff_profiles where user_id=any(staff);
 for unit in 1..(line->>'quantity')::integer loop
 if(((next_slot at time zone zone)::date+(next_slot at time zone zone)::time)at time zone zone)<>next_slot then raise exception 'Ambiguous local service time requires review'using errcode='22023';end if;
 child:=gen_random_uuid();booking:=gen_random_uuid();
 unit_base:=round((line->>'base_before_discount_exact')::numeric*unit/(line->>'quantity')::numeric,5)-round((line->>'base_before_discount_exact')::numeric*(unit-1)/(line->>'quantity')::numeric,5);
 unit_payable:=(private.cashier_refund_slice_core(current_quote,line->>'line_id',unit-1,1)->>'amount')::numeric;
 insert into private.cashier_service_worklines values(child,booking,invoice,line->>'line_id',unit,p_branch,service.item_id,unit_base,unit_payable,txid_current());
 insert into public.bookings(id,customer_id,branch_id,vehicle_id,catalog_item_id,service_name,booking_date,booking_time,status,assigned_staff_ids,assigned_workers,duration_minutes,resource_key)
 values(booking,b.subject_id,p_branch,b.car_id,service.item_id,service.name,(next_slot at time zone zone)::date,(next_slot at time zone zone)::time,'confirmed',staff,names,service.duration_minutes,service.resource_key);
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,booking_id,order_type,branch_id,assigned_staff_ids,assigned_workers,created_by)
 values(child,'WORK-'||booking,b.subject_id,subject->>'name',(select phone from public.customers where id=b.subject_id),subject->'car'->>'plate_number',service.name,booking,'service',p_branch,staff,names,actor::text);
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(child,service.item_id,service.name,1,service.price,service.price);
 next_slot:=next_slot+make_interval(mins=>service.duration_minutes);
 end loop;end loop;
 insert into public.business_invoices(invoice_id,order_id,plate_number,service_name,total,discount,sale_type,payment_method,commission_total,commission_share,workers,branch_id,created_by,commission_model)
 values(invoice,work,subject->'car'->>'plate_number','خدمات ومنتجات / Services and products',(current_quote->>'total')::numeric,(current_quote->>'invoice_discount_exact')::numeric,'mixed','cash_on_receipt',0,0,'[]',p_branch,actor::text,'cashier_frozen_lines');
 for stock in select c.item_id,c.stock_quantity,sum((x.value->>'quantity')::integer)::integer quantity from public.business_catalog_items c join jsonb_array_elements(current_quote->'lines')x on c.item_id=(x.value->>'item_id')::uuid where c.item_type='product'group by c.item_id,c.stock_quantity order by c.item_id loop
 if stock.quantity>stock.stock_quantity then raise exception 'Insufficient stock'using errcode='55000';end if;
 update public.business_catalog_items set stock_quantity=stock.stock_quantity-stock.quantity,updated_at=clock_timestamp()where item_id=stock.item_id;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id,invoice_id)values(p_request,p_branch,stock.item_id,'pos_sale',stock.stock_quantity,stock.stock_quantity-stock.quantity,'Issued cashier product invoice',actor,invoice);
 end loop;
 select display_number into number from public.business_invoices where invoice_id=invoice;
 update public.business_orders set order_number=number where order_id=work;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(actor::text,actor,'cashier_invoice_issued','business_invoices',invoice,p_branch,jsonb_build_object('draft_id',p_draft,'order_id',work,'total',current_quote->'total','payment_confirmed',false));
 return jsonb_build_object('invoice_id',invoice,'order_id',work,'invoice_number',number,'issued',true,'payment_status_at_issuance','unpaid','payment_status_requires_refresh',true,'payment_requires_cashier_confirmation',true);
end$function$;
create function public.issue_cashier_mixed_invoice(p_request uuid,p_branch uuid,p_draft uuid,p_expected_draft_version integer,p_expected_binding_version integer,p_start timestamptz)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.issue_cashier_mixed_invoice(p_request,p_branch,p_draft,p_expected_draft_version,p_expected_binding_version,p_start)$$;
revoke all on function private.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamptz),public.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamptz)from public,anon,authenticated,service_role;
grant execute on function private.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamptz),public.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamptz)to authenticated;
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
 if new.status is distinct from old.status and not(new.status='refunded'and exists(select 1 from private.cashier_full_refunds r where r.invoice_id=p.invoice_id and r.creator_xid=txid_current()))then raise exception 'Use canonical refund or cancellation'using errcode='55000';end if;
 end if;return new;end$function$;
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
 if new.commission_model='cashier_frozen_lines'and private.cashier_invoice_has_services(new.invoice_id)then return new;end if;
 select * into v_s from private.offline_walk_in_subjects where invoice_id=new.invoice_id;
 if not found then
  if exists(select 1 from private.offline_walk_in_subjects where order_id=new.order_id)then raise exception 'Typed work already has its canonical invoice'using errcode='55000';end if;
  if new.commission_model<>'legacy_scalar'or new.commission_share is null then raise exception 'Typed commission requires canonical sidecar proof'using errcode='55000';end if;return new;
 end if;
 select sum(c.amount),case when count(distinct c.rate_percent)=1 then min(c.amount)end,count(distinct c.rate_percent),array_agg(c.staff_id order by c.staff_id),jsonb_agg(c.staff_name order by c.staff_id)
 into v_total,v_share,v_rates,v_ids,v_workers from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id;
 if new.commission_model<>'walk_in_frozen_workers'or new.order_id is distinct from v_s.order_id or new.branch_id<>v_s.branch_id or not((v_s.reward_issue_id is null and new.total=v_s.gross and new.discount=0 and new.reward_snapshot is null)or(v_s.reward_issue_id is not null and coalesce(private.offline_reward_invoice_terms_match(new.invoice_id,new.order_id,new.reward_snapshot,new.total,new.discount),false)))or new.sale_type<>'service' or new.commission_total is distinct from v_total or new.commission_share is distinct from v_share or v_ids is distinct from v_s.staff_ids or new.workers is distinct from v_workers or exists(select 1 from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id and(c.gross<>v_s.gross or c.assigned_count<>cardinality(v_s.staff_ids)))then raise exception 'Complete truthful frozen worker commission proof required'using errcode='55000';end if;
 if tg_op='INSERT'and v_s.creator_xid<>txid_current()then raise exception 'Invoice must be issued with new canonical proof'using errcode='55000';end if;
 if tg_op='UPDATE'then
  if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued walk-in finance and commission facts are immutable'using errcode='55000';end if;
  if new.status='void'and old.status<>'void'and not exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=v_s.order_id::text)then raise exception 'Use canonical unpaid cancellation'using errcode='55000';end if;
 end if;return new;
end$function$;
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
 perform 1 from public.business_invoices where invoice_id=p_invoice for update;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already refunded'using errcode='40001';end if;
 insert into private.cashier_full_refunds values(p_request,actor,payload,p_invoice,p_request,p_restock,trim(p_reason),txid_current());
 return private.record_shift_payment(p_request,p_shift,p_invoice,'refund','cash');
end$function$;
CREATE OR REPLACE FUNCTION private.invoice_snapshot(p_invoice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare invoice_row public.business_invoices;snapshot jsonb;coverage jsonb;
begin
 if exists(select 1 from private.cashier_invoice_postings where invoice_id=p_invoice)then
 return(select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',(select jsonb_agg((v-'commission_estimate'-'staff_ids')||jsonb_build_object('subtotal',v->'base_before_discount_exact','catalog_unit_price',v->'unit_price','unit_price',round((v->>'base_before_discount_exact')::numeric/(v->>'quantity')::numeric,5))order by v->>'line_id')from jsonb_array_elements(p.quote->'lines')v),
 'currency','EGP','discount',p.quote->'invoice_discount_exact','discount_summary_amount',round((p.quote->>'invoice_discount_exact')::numeric,2),'discount_precision',5,'legacy_discount_summary_rounded',true,'total',p.quote->'total','tax_amount',p.quote->'tax_amount_exact','tax_configuration','owner_reviewed_versioned','taxable_amount_exact',p.quote->'taxable_amount_exact','net_amount_exact',p.quote->'net_amount_exact','payable_rounding',p.quote->'payable_rounding','eta_accepted',false,'legally_verified_by_software',false)
 from private.cashier_invoice_postings p join public.business_branches b on b.branch_id=p.branch_id where p.invoice_id=p_invoice);
 end if;
 select * into invoice_row from public.business_invoices where invoice_id=p_invoice;
 if not found then return null;end if;
select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('name',x.item_name,'quantity',x.quantity,'unit_price',x.unit_price,'subtotal',x.subtotal) order by x.created_at,x.order_item_id) from public.business_order_items x where x.order_id=i.order_id),jsonb_build_array(jsonb_build_object('name',i.service_name,'quantity',1,'unit_price',i.total+i.discount,'subtotal',i.total+i.discount))),
 'currency','EGP','discount',i.discount,'total',i.total,'tax_amount',null,'tax_configuration','not_recorded_in_legacy_invoice',
 'delivery_fee',(select delivery_fee from public.business_order_fulfillments f where f.order_id=i.order_id))
 into snapshot
 from public.business_invoices i join public.business_branches b using(branch_id) where i.invoice_id=p_invoice;
 if invoice_row.reward_snapshot is null then return snapshot;end if;
 coverage:=private.reward_invoice_coverage(p_invoice);
 if invoice_row.total<>0 or not coalesce(coverage->>'state' in ('covered_by_reward','cancelled_reward'),false) then
  raise exception 'An issued reward document requires complete canonical coverage at creation' using errcode='42501';
 end if;
 return snapshot||jsonb_build_object('reward',invoice_row.reward_snapshot,'reward_coverage',coverage,
  'payment_status',case when coverage->>'state'='covered_by_reward' and invoice_row.status='active' then 'covered_by_reward' else 'cancelled' end,
  'payment_method','reward_coverage');
end;$function$;

-- Work lifecycle and guarded aggregation are appended before applying this migration.

create function private.guard_cashier_service_child()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
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
 if new.status='cancelled'and old.status<>'cancelled'then raise exception 'Bundle cancellation requires coordinated refund policy'using errcode='55000';end if;
 if exists(select 1 from private.cashier_service_commissions where order_id=w.order_id)and(new.assigned_staff_ids is distinct from old.assigned_staff_ids or new.assigned_workers is distinct from old.assigned_workers)then raise exception 'Started crew is frozen; explicit management stop adapter required'using errcode='55000';end if;
 if new.status is distinct from old.status then
 select exists(select 1 from private.service_work_ledger e where e.command_id is not null and e.actor_id=auth.uid()and e.creator_xid=txid_current()and e.expected_status=old.status and e.next_status=new.status and((tg_table_name='bookings'and e.booking_id=w.booking_id)or(tg_table_name='business_orders'and e.order_id=w.order_id)))into event_found;
 if not event_found then raise exception 'Use durable service work command'using errcode='55000';end if;
 end if;return new;end$$;
create trigger guard_cashier_service_child before update or delete on public.business_orders for each row execute function private.guard_cashier_service_child();
create trigger guard_cashier_service_child before update or delete on public.bookings for each row execute function private.guard_cashier_service_child();
create function private.cashier_service_progress()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
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
 select bool_and(o.status in('quality_check','completed','delivered')),bool_and(o.status in('completed','delivered')),bool_and(o.status='delivered')into all_quality,all_completed,all_delivered from private.cashier_service_worklines x join public.business_orders o using(order_id)where x.invoice_id=w.invoice_id;
 loop
 next_parent:=case when parent_status='received'then'in_progress'when parent_status='in_progress'and all_quality then'quality_check'when parent_status='quality_check'and all_completed then'completed'when parent_status='completed'and all_delivered then'delivered'else null end;
 exit when next_parent is null;
 insert into private.cashier_bundle_events(order_id,next_status,source_event,actor_id,creator_xid)values(p.order_id,next_parent,event,auth.uid(),txid_current());
 update public.business_orders set status=next_parent,updated_at=clock_timestamp()where order_id=p.order_id;parent_status:=next_parent;
 end loop;
 return new;end$$;
create trigger cashier_service_progress after update of status on public.business_orders for each row execute function private.cashier_service_progress();
revoke all on function private.guard_cashier_service_child(),private.cashier_service_progress()from public,anon,authenticated,service_role;
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
 if new.status is distinct from old.status and exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then raise exception 'Refunded order cannot advance or restore stock again'using errcode='55000';end if;
 if private.cashier_invoice_has_services(p.invoice_id)and new.status is distinct from old.status and not exists(select 1 from private.cashier_bundle_events where order_id=p.order_id and next_status=new.status and actor_id=auth.uid()and creator_xid=txid_current())then raise exception 'Bundle status follows actual component work only'using errcode='55000';end if;
 if new.status='cancelled'and old.status<>'cancelled'then raise exception 'Use canonical refund; legacy cancellation cannot restore posted stock'using errcode='55000';end if;
 return new;end$function$;
CREATE OR REPLACE FUNCTION private.guard_cashier_posted_lines()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare posting private.cashier_invoice_postings;begin
 select *into posting from private.cashier_invoice_postings where order_id=case when tg_op in('DELETE','UPDATE')then old.order_id else new.order_id end;
 if not found and tg_op='UPDATE'then select *into posting from private.cashier_invoice_postings where order_id=new.order_id;end if;
 if not found then select p.*into posting from private.cashier_invoice_postings p join private.cashier_service_worklines w on w.invoice_id=p.invoice_id where w.order_id=case when tg_op in('DELETE','UPDATE')then old.order_id else new.order_id end;end if;
 if not found and tg_op='UPDATE'then select p.*into posting from private.cashier_invoice_postings p join private.cashier_service_worklines w on w.invoice_id=p.invoice_id where w.order_id=new.order_id;end if;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='INSERT'and posting.creator_xid=txid_current()and not exists(select 1 from public.business_invoices where invoice_id=posting.invoice_id)then return new;end if;
 raise exception 'Issued invoice lines are immutable'using errcode='55000';end$function$;
CREATE OR REPLACE FUNCTION private.get_customer_booking_history()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.booking_date desc,h.booking_time desc,h.id) from (
    select b.id,b.branch_id,b.catalog_item_id,coalesce(b.display_number,b.id::text) booking_number,b.service_name,b.booking_date,b.booking_time,b.status,coalesce((select allocated_payable from private.cashier_service_worklines where booking_id=b.id),b.quoted_price)quoted_price,b.notes,b.vehicle_id,
      case when v.id is not null then jsonb_build_object('brand',v.brand,'model',v.model,'year',v.year,'plate_number',v.plate_number) end vehicle,
      i.invoice_id,i.invoice_number,i.document_token invoice_token,
      case when i.invoice_id is null then 'not_recorded' when i.status='void' then 'cancelled'
        when i.status='refunded' then 'refunded'
        when i.status='active' and i.total=0 and i.reward_coverage->>'state'='covered_by_reward' then 'covered_by_reward'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='cash') then 'paid'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='electronic') then 'verification_required'
        else 'unpaid' end payment_status,
      i.total invoice_total,i.discount invoice_discount,i.reward_coverage,case when i.reward_coverage->>'state' in ('covered_by_reward','cancelled_reward') and i.total=0 then 'reward_coverage' else case when i.payment_method='reward_coverage' then null else i.payment_method end end payment_method
    from public.bookings b
    left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
    left join lateral (
      select x.invoice_id,coalesce(x.display_number,x.invoice_id) invoice_number,x.document_token,x.status,x.payment_method,x.total,x.discount,case when x.total=0 then private.reward_invoice_coverage(x.invoice_id) else null end reward_coverage from public.business_orders o
      join public.business_invoices x on x.order_id=coalesce((select p.order_id from private.cashier_service_worklines w join private.cashier_invoice_postings p on p.invoice_id=w.invoice_id where w.order_id=o.order_id and w.booking_id=b.id and w.branch_id=b.branch_id and p.subject->>'id'=b.customer_id::text),o.order_id)and x.branch_id=b.branch_id
      where o.booking_id=b.id and o.customer_id=b.customer_id and o.branch_id=b.branch_id
      order by x.issued_at desc,x.invoice_id limit 1
    ) i on true
    where b.customer_id=auth.uid()
  ) h),'[]'::jsonb);
end;$function$;
CREATE OR REPLACE FUNCTION private.enqueue_loyalty_visit_source()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare oid uuid;bid uuid;iid text;sid uuid:=gen_random_uuid();
begin
 if tg_table_schema='private'and tg_table_name='loyalty_earning_snapshot_bindings'then
 if exists(select 1 from private.cashier_service_worklines where booking_id=new.booking_id)then return new;end if;
 elsif tg_table_name='bookings'then
 if exists(select 1 from private.cashier_service_worklines where booking_id=new.id)then return new;end if;
 elsif tg_table_name='business_orders'then
 if exists(select 1 from private.cashier_service_worklines where order_id=new.order_id)or exists(select 1 from private.cashier_invoice_postings where order_id=new.order_id and private.cashier_invoice_has_services(invoice_id))then return new;end if;
 elsif tg_table_name in('business_invoices','business_payment_events')then
 if private.cashier_invoice_has_services(new.invoice_id)then return new;end if;
 end if;
 if tg_table_schema='private' and tg_table_name='loyalty_earning_snapshot_bindings' then bid:=new.booking_id;sid:=new.booking_id;
 elsif tg_table_name='bookings' then bid:=new.id;if not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid) then return new;end if;
 elsif tg_table_name='business_orders' then if new.order_type<>'service' then return new;end if;oid:=new.order_id;bid:=new.booking_id;
 elsif tg_table_name='business_invoices' then oid:=new.order_id;iid:=new.invoice_id;select booking_id into bid from public.business_orders where order_id=oid;
 else sid:=new.payment_id;iid:=new.invoice_id;select order_id into oid from public.business_invoices where invoice_id=iid;select booking_id into bid from public.business_orders where order_id=oid;end if;
 if bid is null then
 if oid is not null and exists(select 1 from private.offline_service_visit_order_snapshots s where s.order_id=oid and s.earning_authorized)then
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,invoice_id)values(tg_table_name,sid,oid,iid)on conflict(source_kind,source_id)do nothing;end if;return new;end if;
 if not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid)then return new;end if;
 -- Distinct append-only events: never a mutable shared queue row per order.
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,booking_id,invoice_id) values(tg_table_name,sid,oid,bid,iid) on conflict(source_kind,source_id) do nothing;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION private.hr_execute(p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET "TimeZone" TO 'UTC'
AS $function$
declare uid uuid:=auth.uid();r text:=private.active_staff_role();s uuid;rid uuid;v jsonb;a private.hr_attendance;e private.hr_employment;
 f date;t date;mins numeric;sched numeric;base numeric;comm numeric;adjustments numeric;lines jsonb;pid uuid;existing private.hr_payroll;
begin
 if uid is null or r is null then raise exception 'Active staff access required' using errcode='42501';end if;
 s:=coalesce((p_data->>'staff_id')::uuid,uid);
 if r<>'owner' and s<>uid then raise exception 'Own HR records only' using errcode='42501';end if;
 if p_action='read' then
 return jsonb_build_object('staff',case when r='owner' then (select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'full_name',full_name)),'[]') from public.staff_profiles where is_active) else '[]'::jsonb end,
 'employment',(select to_jsonb(x) from private.hr_employment x where staff_id=s),
 'attendance',(select coalesce(jsonb_agg(to_jsonb(x) order by clock_in desc),'[]') from (select * from private.hr_attendance where staff_id=s order by clock_in desc limit 100)x),
 'leave',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_leave x where staff_id=s),
 'adjustments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s),
 'payroll',(select coalesce(jsonb_agg(to_jsonb(x) order by from_date desc),'[]') from private.hr_payroll x where staff_id=s));
 end if;
 rid:=(p_data->>'request_id')::uuid;if rid is null then raise exception 'Request identity required';end if;
 -- Serialize each staff workflow: avoids overlapping periods and duplicate open shifts.
 perform pg_advisory_xact_lock(hashtextextended('hr:'||s::text,0));
 if p_action in ('clock_in','clock_out','leave') and s<>uid then raise exception 'Attendance and leave must be submitted by employee' using errcode='42501';end if;
 if p_action='clock_in' then
 select to_jsonb(x) into v from private.hr_attendance x where request_id=rid and staff_id=s;if v is not null then return v;end if;
 if exists(select 1 from private.hr_leave where staff_id=s and status='approved' and current_date between from_date and to_date) then raise exception 'Approved leave covers today';end if;
 insert into private.hr_attendance(staff_id,request_id) values(s,rid) returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='clock_out' then
 select * into a from private.hr_attendance where staff_id=s and id=(p_data->>'id')::uuid for update;
 if a.id is null then raise exception 'Attendance record not found';end if;
 if a.clock_out is not null then return to_jsonb(a);end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and a.clock_in::date<=to_date and clock_timestamp()::date>=from_date) then raise exception 'Attendance overlaps approved payroll';end if;
 update private.hr_attendance set clock_out=clock_timestamp() where id=a.id returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='leave' then
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;
 if f is null or t is null or f<current_date then raise exception 'Future leave dates required';end if;
 insert into private.hr_leave(staff_id,from_date,to_date,reason,request_id) values(s,f,t,p_data->>'reason',rid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_leave x where request_id=rid and staff_id=s);
 end if;
 if r<>'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if not exists(select 1 from public.staff_profiles where user_id=s and is_active) then raise exception 'Active staff required';end if;
 if p_action='employment' then
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on,ends_on) values(s,(p_data->>'salary')::numeric,(p_data->>'commission_percent')::numeric,upper(p_data->>'currency'),(p_data->>'starts_on')::date,(p_data->>'ends_on')::date)
 on conflict(staff_id) do update set salary=excluded.salary,commission_percent=excluded.commission_percent,currency=excluded.currency,starts_on=excluded.starts_on,ends_on=excluded.ends_on,updated_at=now();
 return (select to_jsonb(x) from private.hr_employment x where staff_id=s);
 elsif p_action='decide_leave' then
 if p_data->>'status' not in ('approved','rejected') then raise exception 'Choose approved or rejected';end if;
 if p_data->>'status'='approved' and exists(select 1 from private.hr_leave target join private.hr_leave other on other.staff_id=target.staff_id and other.id<>target.id and other.status='approved' and other.from_date<=target.to_date and other.to_date>=target.from_date where target.id=(p_data->>'id')::uuid and target.staff_id=s) then raise exception 'Approved leave dates overlap';end if;
 update private.hr_leave set status=p_data->>'status',decided_by=uid where id=(p_data->>'id')::uuid and staff_id=s and status='pending' returning to_jsonb(hr_leave.*) into v;
 if v is null then raise exception 'Pending leave required';end if;return v;
 elsif p_action='adjustment' then
 select * into e from private.hr_employment where staff_id=s;
 if e.staff_id is null then raise exception 'Employment currency must be configured first';end if;
 f:=(p_data->>'on_date')::date;
 if exists(select 1 from private.hr_payroll where staff_id=s and f between from_date and to_date) then raise exception 'Approved payroll period is closed';end if;
 insert into private.hr_adjustment(staff_id,on_date,currency,kind,amount,reason,request_id,created_by) values(s,f,e.currency,p_data->>'kind',(p_data->>'amount')::numeric,p_data->>'reason',rid,uid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_adjustment x where request_id=rid and staff_id=s);
 elsif p_action='approve_payroll' then
 select * into existing from private.hr_payroll where request_id=rid;
 if existing.id is not null then if existing.staff_id<>s then raise exception 'Request belongs to another staff';end if;return to_jsonb(existing);end if;
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;sched:=(p_data->>'scheduled_minutes')::numeric;
 if f is null or t is null or t<f or t>=current_date or t-f>366 or sched is null or sched<=0 or sched::text in ('NaN','Infinity','-Infinity') then raise exception 'Closed dates and explicit scheduled minutes required';end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and from_date<=t and to_date>=f) then raise exception 'Payroll periods cannot overlap';end if;
 select * into e from private.hr_employment where staff_id=s;
 if e.currency is distinct from 'EGP' then raise exception 'Payroll requires EGP compensation; no exchange conversion is configured';end if;
 if e.staff_id is null or e.starts_on>f or coalesce(e.ends_on,t)<t then raise exception 'Employment must cover entire period';end if;
 if exists(select 1 from private.hr_attendance where staff_id=s and clock_in<(t+1)::timestamptz and (clock_out is null or clock_out>f::timestamptz) and (clock_out is null or clock_in<f::timestamptz or clock_out>(t+1)::timestamptz)) then raise exception 'Open or boundary-spanning attendance must be resolved before payroll';end if;
 select coalesce(sum(extract(epoch from(clock_out-clock_in))/60),0) into mins from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz;
 base:=round(e.salary*least(mins/sched,1),2);
 -- Freeze relevant assignments and invoice values while approving the financial snapshot.
 perform 1 from public.business_orders o join public.business_invoices i using(order_id) where s=any(o.assigned_staff_ids) and o.order_type='service' and i.status='active' and i.sale_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz for update of o,i;
 -- One invoice per order only. Duplicate invoice associations are rejected, never multiplied or silently chosen.
 if exists(select 1 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz and (select count(*) from public.business_invoices dup where dup.order_id=i.order_id and dup.status='active')>1) then raise exception 'Duplicate service invoices require reconciliation';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'order_id',i.order_id,'before_discount',i.total+i.discount,'rate_percent',case when i.commission_model='walk_in_frozen_workers'then(select wc.rate_percent from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s)else e.commission_percent end,'assigned_count',(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),'commission',case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end)),'[]'),coalesce(sum(case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end),0) into lines,comm
 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and o.status in ('completed','delivered') and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz;
 -- New work commissions are earned once at actual completion, never from mixed invoice gross.
 lines:=lines||coalesce((select jsonb_agg(jsonb_build_object('invoice_id',w.invoice_id,'order_id',c.order_id,'before_discount',c.base_before_discount_exact,'tax_excluded',true,'rate_percent',c.rate_percent,'assigned_count',c.assigned_count,'commission',c.amount,'earned_at',x.earned_at,'model','cashier_frozen_lines')order by x.earned_at,c.order_id)from private.cashier_service_earnings x join private.cashier_service_commissions c using(order_id,staff_id)join private.cashier_service_worklines w using(order_id)where c.staff_id=s and x.earned_at>=f::timestamptz and x.earned_at<(t+1)::timestamptz),'[]'::jsonb);
 comm:=comm+coalesce((select sum(c.amount)from private.cashier_service_earnings x join private.cashier_service_commissions c using(order_id,staff_id)where c.staff_id=s and x.earned_at>=f::timestamptz and x.earned_at<(t+1)::timestamptz),0);
 if exists(select 1 from private.hr_adjustment where staff_id=s and on_date between f and t and currency<>e.currency) then raise exception 'Adjustment and payroll currencies must match';end if;
 select coalesce(sum(case when kind='bonus' then amount else -amount end),0) into adjustments from private.hr_adjustment where staff_id=s and on_date between f and t;
 v:=jsonb_build_object('employment',to_jsonb(e),'actual_minutes',mins,'scheduled_minutes',sched,'base_earned',base,'commission',comm,'commission_lines',lines,'adjustments',adjustments,'net',base+comm+adjustments,'currency',e.currency,'attendance_ids',(select coalesce(jsonb_agg(id),'[]') from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz),'adjustment_lines',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s and on_date between f and t),'leave_policy','Leave approval does not create paid time; actual clocked minutes only','payment_status','not_transferred');
 insert into private.hr_payroll(staff_id,from_date,to_date,scheduled_minutes,snapshot,request_id,approved_by) values(s,f,t,sched,v,rid,uid) returning to_jsonb(hr_payroll.*) into v;return v;
 end if;
 raise exception 'Unknown HR action';
end $function$;
notify pgrst,'reload schema';
commit;
