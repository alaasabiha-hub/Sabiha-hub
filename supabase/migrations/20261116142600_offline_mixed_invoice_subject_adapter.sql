begin;
-- Typed provenance, never an Auth identity or permission to redeem loyalty.
create table private.cashier_offline_invoice_subjects(
 invoice_id text primary key references private.cashier_invoice_postings(invoice_id),
 profile_id uuid not null references private.offline_customer_profiles(profile_id),
 car_ref_id uuid not null references private.offline_customer_car_refs(car_ref_id),
 branch_id uuid not null references public.business_branches(branch_id),creator_xid bigint not null);
create table private.cashier_offline_work_subjects(
 order_id uuid primary key references private.cashier_service_worklines(order_id),
 booking_id uuid not null unique references public.bookings(id)deferrable initially deferred,
 invoice_id text not null references private.cashier_offline_invoice_subjects(invoice_id));
do $$declare t text;begin foreach t in array array['cashier_offline_invoice_subjects','cashier_offline_work_subjects']loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_typed_mixed_subject before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',t);
end loop;end$$;
create function private.guard_cashier_offline_identity()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare w private.cashier_offline_work_subjects;p private.cashier_invoice_postings;s private.cashier_offline_invoice_subjects;
begin
 if tg_table_name='bookings'then
 select *into w from private.cashier_offline_work_subjects where booking_id=case when tg_op='DELETE'then old.id else new.id end;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 select *into s from private.cashier_offline_invoice_subjects where invoice_id=w.invoice_id;
 if tg_op='DELETE'then raise exception 'Typed visit history retained'using errcode='55000';end if;
 if new.customer_id is not null or new.vehicle_id is not null or new.branch_id<>s.branch_id then raise exception 'Typed offline visit cannot become an Auth identity'using errcode='55000';end if;
 else
 select *into p from private.cashier_invoice_postings where order_id=case when tg_op='DELETE'then old.order_id else new.order_id end;
 if not found then select i.*into p from private.cashier_offline_work_subjects sw join private.cashier_invoice_postings i using(invoice_id)where sw.order_id=case when tg_op='DELETE'then old.order_id else new.order_id end;end if;
 select *into s from private.cashier_offline_invoice_subjects where invoice_id=p.invoice_id;
 if not found then if tg_op='DELETE'then return old;end if;return new;end if;
 if tg_op='DELETE'then raise exception 'Typed invoice work retained'using errcode='55000';end if;
 if new.customer_id is not null or new.branch_id<>s.branch_id then raise exception 'Typed offline order cannot become an Auth identity'using errcode='55000';end if;
 end if;return new;
end$$;
revoke all on function private.guard_cashier_offline_identity()from public,anon,authenticated,service_role;
create trigger guard_typed_mixed_booking before insert or update or delete on public.bookings for each row execute function private.guard_cashier_offline_identity();
create trigger guard_typed_mixed_order before insert or update or delete on public.business_orders for each row execute function private.guard_cashier_offline_identity();
CREATE OR REPLACE FUNCTION private.issue_cashier_mixed_invoice(p_request uuid, p_branch uuid, p_draft uuid, p_expected_draft_version integer, p_expected_binding_version integer, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;prior private.cashier_invoice_postings;
 payload jsonb;current_quote jsonb;subject jsonb;invoice text;work uuid;line jsonb;number text;stock record;service public.business_catalog_items;next_slot timestamptz;zone text;unit integer;child uuid;booking uuid;staff uuid[];names jsonb;unit_base numeric;unit_payable numeric;resource text;customer_ref uuid;vehicle_ref uuid;contact_phone text;begin
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
 if b.subject_kind='app_customer'then customer_ref:=b.subject_id;vehicle_ref:=b.car_id;
 elsif b.subject_kind='offline_profile'then
 perform 1 from private.offline_customer_profiles where profile_id=b.subject_id and created_branch_id=p_branch for share;
 if not found then raise exception 'Typed offline customer unavailable'using errcode='42501';end if;
 perform 1 from private.offline_customer_car_refs where profile_id=b.subject_id and car_ref_id=b.car_id for share;
 if not found then raise exception 'Owned offline car unavailable'using errcode='42501';end if;
 else raise exception 'Explicit supported customer source required'using errcode='22023';end if;
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
 if b.subject_kind='app_customer'then select phone into contact_phone from public.customers where id=b.subject_id;
 else select phone_e164 into contact_phone from private.offline_customer_contacts where profile_id=b.subject_id order by created_at desc,contact_id limit 1;end if;
 invoice:=gen_random_uuid()::text;work:=gen_random_uuid();
 insert into private.cashier_invoice_postings values(p_request,actor,payload,p_draft,invoice,work,p_branch,current_quote,subject,txid_current(),clock_timestamp());
 if b.subject_kind='offline_profile'then insert into private.cashier_offline_invoice_subjects values(invoice,b.subject_id,b.car_id,p_branch,txid_current());end if;
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,order_type,branch_id,created_by)
 values(work,invoice,customer_ref,subject->>'name',contact_phone,subject->'car'->>'plate_number','خدمات ومنتجات / Services and products','mixed',p_branch,actor::text);
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
 if b.subject_kind='offline_profile'then insert into private.cashier_offline_work_subjects values(child,booking,invoice);end if;
 insert into public.bookings(id,customer_id,branch_id,vehicle_id,catalog_item_id,service_name,booking_date,booking_time,status,assigned_staff_ids,assigned_workers,duration_minutes,resource_key)
 values(booking,customer_ref,p_branch,vehicle_ref,service.item_id,service.name,(next_slot at time zone zone)::date,(next_slot at time zone zone)::time,'confirmed',staff,names,service.duration_minutes,service.resource_key);
 insert into public.business_orders(order_id,order_number,customer_id,customer_name,customer_phone,plate_number,service_name,booking_id,order_type,branch_id,assigned_staff_ids,assigned_workers,created_by)
 values(child,'WORK-'||booking,customer_ref,subject->>'name',contact_phone,subject->'car'->>'plate_number',service.name,booking,'service',p_branch,staff,names,actor::text);
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
 if new.id<>old.id or new.customer_id is distinct from old.customer_id or new.vehicle_id is distinct from old.vehicle_id or new.branch_id<>old.branch_id or new.catalog_item_id is distinct from old.catalog_item_id or new.quoted_price is distinct from old.quoted_price then raise exception 'Billed service identity immutable'using errcode='55000';end if;
 else
 if(to_jsonb(new)-array['status','updated_at','assigned_staff_ids','assigned_workers'])is distinct from(to_jsonb(old)-array['status','updated_at','assigned_staff_ids','assigned_workers'])then raise exception 'Billed work identity immutable'using errcode='55000';end if;
 end if;
 if new.status='cancelled'and old.status<>'cancelled'and not private.cashier_current_cancellation_witness(case when tg_table_name='business_orders'then w.order_id end,case when tg_table_name='bookings'then w.booking_id end,old.status)then raise exception 'Use explicit management service cancellation'using errcode='55000';end if;
 if exists(select 1 from private.cashier_service_commissions where order_id=w.order_id)and(new.assigned_staff_ids is distinct from old.assigned_staff_ids or new.assigned_workers is distinct from old.assigned_workers)then raise exception 'Started crew is frozen; explicit management stop adapter required'using errcode='55000';end if;
 if new.status is distinct from old.status then
 select exists(select 1 from private.service_work_ledger e where e.command_id is not null and e.actor_id=auth.uid()and e.creator_xid=txid_current()and e.expected_status=old.status and e.next_status=new.status and((tg_table_name='bookings'and e.booking_id=w.booking_id)or(tg_table_name='business_orders'and e.order_id=w.order_id)))into event_found;
 if not event_found then raise exception 'Use durable service work command'using errcode='55000';end if;
 end if;return new;end$function$

;
commit;
