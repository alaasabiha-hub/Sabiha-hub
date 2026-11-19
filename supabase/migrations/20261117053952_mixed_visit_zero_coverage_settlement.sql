begin;
-- A genuine zero-payable service reward is settled by coverage authority,
-- NEVER a zero/positive cash sale, terminal event, or invented gateway result.
create table private.mixed_visit_zero_coverages(group_id uuid primary key references private.mixed_visit_groups(request_id),invoice_id text not null unique references public.business_invoices(invoice_id),consent_id uuid not null unique references private.mixed_visit_verbal_consents(request_id),actor_id uuid not null references public.staff_profiles(user_id),creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
alter table private.mixed_visit_zero_coverages enable row level security;
revoke all on private.mixed_visit_zero_coverages from public,anon,authenticated,service_role;
create trigger immutable_zero_visit_coverage before update or delete on private.mixed_visit_zero_coverages for each row execute function private.immutable_loyalty_policy();
create function private.mixed_visit_zero_coverage_valid(p_invoice text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$
 select exists(select 1 from private.mixed_visit_zero_coverages z join private.mixed_visit_invoice_bindings b using(invoice_id,group_id)join private.mixed_visit_groups g on g.request_id=z.group_id join private.cashier_invoice_postings p using(invoice_id)join public.business_invoices i using(invoice_id)where z.invoice_id=p_invoice and i.total=0 and(g.quote->>'total')::numeric=0 and(p.quote->>'total')::numeric=0 and p.quote->>'visit_reward_group_id'=g.request_id::text and z.actor_id=g.actor_id and z.actor_id=p.actor_id)
$$;
create function private.mixed_visit_zero_remaining_units(p_invoice text)returns bigint language sql stable security invoker set search_path=pg_catalog as $$
 select count(*)from private.mixed_visit_zero_coverages z join private.mixed_visit_components c using(group_id)where z.invoice_id=p_invoice and not exists(select 1 from private.mixed_visit_returned_units u where u.group_id=c.group_id and u.unit_number=c.unit_number)
$$;
create function private.guard_zero_visit_coverage()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare a private.mixed_visit_issue_authorizations;g private.mixed_visit_groups;p private.cashier_invoice_postings;begin
 select *into a from private.mixed_visit_issue_authorizations where group_id=new.group_id and consent_id=new.consent_id and actor_id=new.actor_id and creator_xid=txid_current();
 select x.*into p from private.cashier_invoice_postings x join private.mixed_visit_invoice_bindings b using(invoice_id)where b.group_id=new.group_id and x.invoice_id=new.invoice_id;
 select *into g from private.mixed_visit_groups where request_id=new.group_id;
 if a.request_id is null or p.request_id is distinct from a.request_id or new.actor_id is distinct from auth.uid()or new.creator_xid<>txid_current()or p.creator_xid<>txid_current()or g.expires_at<=clock_timestamp()or(p.quote->>'total')::numeric<>0 or(g.quote->>'total')::numeric<>0 or not exists(select 1 from public.business_invoices where invoice_id=new.invoice_id and total=0 and status='active')or jsonb_array_length(g.quote->'lines')<>1 or g.covered_units<>(g.quote#>>'{lines,0,quantity}')::integer or g.quote#>>'{lines,0,item_type}'is distinct from'service'or(g.quote->>'visit_discount_exact')::numeric<=0 or(select count(*)from private.cashier_service_worklines where invoice_id=new.invoice_id and allocated_payable=0)<>g.covered_units or exists(select 1 from public.business_payment_events where invoice_id=new.invoice_id)then raise exception 'Actual same-transaction fully covered service invoice required'using errcode='55000';end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);return new;
end$$;
create trigger require_actual_zero_visit_coverage before insert on private.mixed_visit_zero_coverages for each row execute function private.guard_zero_visit_coverage();
create function private.guard_zero_visit_money()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if private.mixed_visit_zero_coverage_valid(new.invoice_id)then raise exception 'Visit coverage has no monetary collection or refund'using errcode='55000';end if;return new;end$$;
create trigger a_reject_money_for_zero_visit_coverage before insert on public.business_payment_events for each row execute function private.guard_zero_visit_money();
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
 current_quote:=private.apply_mixed_points_issuing_quote(p_request,current_quote);
 current_quote:=private.apply_mixed_visit_issuing_quote(p_request,current_quote);
 if not exists(select 1 from jsonb_array_elements(current_quote->'lines')where value->>'item_type'='service')then raise exception 'Use the existing product issuing endpoint'using errcode='22023';end if;
 if p_start is null or not isfinite(p_start)or p_start<=clock_timestamp()or current_quote->>'staff_configuration_complete'<>'true'then raise exception 'Future service start and configured service workers required'using errcode='22023';end if;
 if(select sum((v->>'quantity')::numeric*c.duration_minutes)from jsonb_array_elements(current_quote->'lines')v join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid where c.item_type='service')>1440 then raise exception 'One-visit work must fit a business day; plan separate visits'using errcode='22023';end if;
 if exists(select 1 from public.business_catalog_items c where c.item_id in(select(value->>'item_id')::uuid from jsonb_array_elements(current_quote->'lines'))and c.item_type='product'and c.stock_quantity is null)then raise exception 'Tracked product stock required'using errcode='55000';end if;
 if(current_quote->>'total')::numeric<0 or((current_quote->>'total')::numeric=0 and not exists(select 1 from private.mixed_visit_issue_authorizations a where a.request_id=p_request and a.actor_id=actor and a.creator_xid=txid_current()and a.group_id::text=current_quote->>'visit_reward_group_id'))then raise exception 'Positive payable invoice required; use the separately authorized reward route'using errcode='55000';end if;
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
CREATE OR REPLACE FUNCTION private.issue_mixed_visit_invoice(p_request uuid, p_branch uuid, p_group uuid, p_consent uuid, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare g private.mixed_visit_groups;i private.cashier_loyalty_draft_intents;a private.mixed_visit_issue_authorizations;result jsonb;begin
 select *into g from private.mixed_visit_groups where request_id=p_group and branch_id=p_branch and actor_id=auth.uid();if not found then raise exception 'Own actual visit group required'using errcode='42501';end if;
 perform private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 if p_request is null or p_consent is null then raise exception 'Exact issuance request and assent required'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-visit-issue:'||p_request,0));
 select *into strict i from private.cashier_loyalty_draft_intents where request_id=g.intent_id;
 select *into a from private.mixed_visit_issue_authorizations where request_id=p_request;
 if found then
 if a.actor_id<>auth.uid()or a.group_id<>p_group or a.consent_id<>p_consent then raise exception 'Immutable visit invoice request'using errcode='22023';end if;
 return private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start)||jsonb_build_object('zero_visit_coverage',private.mixed_visit_zero_coverage_valid((select invoice_id from private.mixed_visit_invoice_bindings where group_id=p_group)),'collection_required',(g.quote->>'total')::numeric>0,'payment_status_at_issuance',case when(g.quote->>'total')::numeric=0 then'covered_by_reward'else'unpaid'end,'payment_requires_cashier_confirmation',(g.quote->>'total')::numeric>0,'visit_balance_reserved',true,'visit_collection_committed',false);end if;
 if(private.get_cashier_loyalty_draft_intent(p_branch,i.request_id))->>'state'is distinct from'current'or not exists(select 1 from private.mixed_visit_verbal_consents c where c.request_id=p_consent and c.group_id=p_group and c.actor_id=auth.uid())then raise exception 'Own current sealed draft and exact consent required'using errcode='42501';end if;
 perform private.lock_mixed_visit_backing(p_group);
 if not private.mixed_visit_verbal_current(p_consent)then raise exception 'Current independently verified verbal approval required'using errcode='42501';end if;
 insert into private.mixed_visit_issue_authorizations values(p_request,p_group,p_consent,auth.uid(),txid_current());
 result:=private.issue_cashier_mixed_invoice(p_request,p_branch,i.draft_id,i.draft_version,i.binding_version,p_start);
 -- Scheduling/capacity waits must not allow an expired session or quote through.
 perform private.owner_mixed_visit_actor(p_branch,g.rules_version_id);
 if g.expires_at<=clock_timestamp()then raise exception 'Visit quote expired before issuance completed'using errcode='40001';end if;
 if(g.quote->>'total')::numeric=0 then
 insert into private.mixed_visit_zero_coverages values(p_group,result->>'invoice_id',p_consent,auth.uid(),txid_current(),clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'mixed_visit_zero_covered','business_invoices',result->>'invoice_id',p_branch,jsonb_build_object('group_id',p_group,'consent_id',p_consent,'amount_due',0,'payment_event_created',false));
 end if;
 return result||jsonb_build_object('zero_visit_coverage',(g.quote->>'total')::numeric=0,'collection_required',(g.quote->>'total')::numeric>0,'payment_status_at_issuance',case when(g.quote->>'total')::numeric=0 then'covered_by_reward'else'unpaid'end,'payment_requires_cashier_confirmation',(g.quote->>'total')::numeric>0,'visit_balance_reserved',true,'visit_collection_committed',false);
end$function$;
CREATE OR REPLACE FUNCTION private.preview_cashier_refund_lines(p_invoice text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare p private.cashier_invoice_postings;actor uuid;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]'::jsonb;previous_quantity integer;quantity integer;amount numeric:=0;paid numeric;refunded numeric;version jsonb;begin
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice;if not found then raise exception 'Cashier invoice unavailable'using errcode='42501';end if;
 actor:=private.cashier_cart_actor(p.branch_id);

 if private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'refunds'='true')then raise exception 'Refund permission required'using errcode='42501';end if;
 if jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'Distinct original lines required'using errcode='22023';end if;
 if exists(select 1 from private.cashier_full_refunds where invoice_id=p_invoice)then raise exception 'Invoice already fully refunded'using errcode='40001';end if;
 select pe.amount into paid from public.business_payment_events pe where pe.invoice_id=p_invoice and pe.event_type='sale'and pe.method in('cash','card_terminal');if not found then if private.mixed_visit_zero_coverage_valid(p_invoice)then paid:=0;else raise exception 'Confirmed collection or actual zero visit coverage required'using errcode='55000';end if;end if;
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
 actor uuid;payload jsonb;entry jsonb;original jsonb;slice jsonb;prepared jsonb:='[]'::jsonb;previous_quantity integer;quantity integer;amount numeric:=0;prior_refund numeric;number bigint;result jsonb;stock record;covered_zero boolean;collected_limit numeric;
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
 covered_zero:=private.mixed_visit_zero_coverage_valid(p_invoice);if i.status='void'or(not covered_zero and(sale.payment_id is null or sale.method not in('cash','card_terminal')))then raise exception 'Confirmed cash payment required; electronic refunds require the gateway adapter'using errcode='55000';end if;
 collected_limit:=case when covered_zero then 0 else sale.amount end;
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
 if prior_refund+amount>collected_limit then raise exception 'Refund exceeds original collected amount'using errcode='22023';end if;
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
 if prior_refund+amount=collected_limit and i.status='active'and(not covered_zero or not exists(select 1 from private.cashier_service_worklines w where w.invoice_id=p_invoice and not exists(select 1 from private.cashier_partial_refund_lines f where f.invoice_id=p_invoice and f.line_id=w.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[w.unit_number])else w.unit_number>(f.snapshot->>'previous_quantity')::integer and w.unit_number<=(f.snapshot->>'cumulative_quantity')::integer end))and not exists(select 1 from private.cashier_unpaid_service_credits c where c.order_id=w.order_id)))then update public.business_invoices set status='refunded'where invoice_id=p_invoice;end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data,reason)values(actor::text,actor,'cashier_partial_refund','business_invoices',p_invoice,p.branch_id,jsonb_build_object('refund_id',p_request,'amount',amount,'lines',prepared,'earned_commissions_retained',true),trim(p_reason));
 return result;
end$function$;
CREATE OR REPLACE FUNCTION private.restore_mixed_visit_units(p_invoice text, p_source uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare g private.mixed_visit_groups;part record;rule text;returned integer;begin
 select x.*into g from private.mixed_visit_groups x join private.mixed_visit_invoice_bindings b on b.group_id=x.request_id where b.invoice_id=p_invoice;if not found then return;end if;
 perform private.owner_mixed_visit_actor(g.branch_id,g.rules_version_id);
 perform pg_advisory_xact_lock(hashtextextended('reward-offline-profile:'||g.profile_id,0));
 if p_kind='credit'then
 if not exists(select 1 from private.cashier_unpaid_service_credits where request_id=p_source and invoice_id=p_invoice and creator_xid=txid_current())then raise exception 'Actual canonical unpaid cancellation required'using errcode='55000';end if;
 elsif p_kind='refund'then
 if(not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)and not private.mixed_visit_zero_coverage_valid(p_invoice))or not exists(select 1 from private.cashier_partial_refunds f where f.request_id=p_source and f.invoice_id=p_invoice and(f.amount=0 or exists(select 1 from public.business_payment_events e where e.invoice_id=p_invoice and e.refund_part_id=f.request_id and e.event_type='refund'and e.amount=f.amount)))then raise exception 'Actual settled canonical partial refund required'using errcode='55000';end if;
 elsif p_kind='full'then
 if(not exists(select 1 from private.mixed_visit_collection_commits where group_id=g.request_id)and not private.mixed_visit_zero_coverage_valid(p_invoice))or not exists(select 1 from public.business_payment_events where invoice_id=p_invoice and payment_id=p_source and event_type='refund'and refund_part_id is null)then raise exception 'Actual canonical full refund required'using errcode='55000';end if;
 else raise exception 'Canonical return source required'using errcode='22023';end if;
 -- Frozen original policy per allocated component, never the latest owner terms.
 for part in select c.*,q.terms_snapshot from private.mixed_visit_components c join private.service_reward_quotes q on q.quote_id=c.quote_id where c.group_id=g.request_id and(p_kind='full'or p_kind='credit'and exists(select 1 from private.cashier_unpaid_service_credits k where k.request_id=p_source and k.invoice_id=p_invoice and k.line_id=g.line_id and k.unit_number=c.unit_number)or p_kind='refund'and exists(select 1 from private.cashier_partial_refund_lines f where f.request_id=p_source and f.invoice_id=p_invoice and f.line_id=g.line_id and(case when f.snapshot?'unit_numbers'then f.snapshot->'unit_numbers'@>to_jsonb(array[c.unit_number])else c.unit_number>(f.snapshot->>'previous_quantity')::integer and c.unit_number<=(f.snapshot->>'cumulative_quantity')::integer end)))order by c.unit_number loop
 rule:=part.terms_snapshot#>>'{rules,cancellation}';
 if rule is null or rule not in('restore_visits','forfeit_visits')then raise exception 'Explicit original cancellation policy required'using errcode='55000';end if;
 insert into private.mixed_visit_returned_units(group_id,unit_number,source_id,source_kind,restore,frozen_rule,actor_id,creator_xid)values(g.request_id,part.unit_number,p_source,p_kind,rule='restore_visits',rule,auth.uid(),txid_current())on conflict(group_id,unit_number)do nothing;
 get diagnostics returned=row_count;
 if returned=1 then
 if rule='restore_visits'then perform private.release_offline_reward_reservation(part.reservation_id,'Canonical mixed visit unit return: '||p_kind||':'||p_source);end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'mixed_visit_unit_returned','business_invoices',p_invoice,g.branch_id,jsonb_build_object('group_id',g.request_id,'unit_number',part.unit_number,'source_id',p_source,'source_kind',p_kind,'frozen_rule',rule,'original_expiry_preserved',true));
 end if;
 end loop;
end$function$;
alter function private.invoice_document_data(uuid,boolean)rename to invoice_document_data_before_zero_visits;
revoke all on function private.invoice_document_data_before_zero_visits(uuid,boolean)from public,anon,authenticated,service_role;
create function private.invoice_document_data(p_token uuid,p_allow_revoked boolean)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare doc jsonb;g private.mixed_visit_groups;remaining bigint;begin
 doc:=private.invoice_document_data_before_zero_visits(p_token,p_allow_revoked);
 if not private.mixed_visit_zero_coverage_valid(doc->>'invoice_id')then return doc;end if;
 select x.*into strict g from private.mixed_visit_groups x join private.mixed_visit_zero_coverages z on z.group_id=x.request_id where z.invoice_id=doc->>'invoice_id';remaining:=private.mixed_visit_zero_remaining_units(doc->>'invoice_id');
 return doc||jsonb_build_object('payment_status',case when remaining=0 then'cancelled_reward'else'covered_by_reward'end,'payment_method','reward_coverage','net_collected',0,'refund_amount',0,'remaining_refundable',0,'amount_outstanding',0,
 'reward_coverage',jsonb_build_object('state',case when remaining=0 then'cancelled_reward'else'covered_by_reward'end,'source_channel','mixed_visit_invoice','unit','service_visits','amount_due',0,'required_visits',g.required_visits,'covered_units',g.covered_units,'remaining_covered_units',remaining,'payment_event_created',false));
end$$;
revoke all on function private.mixed_visit_zero_coverage_valid(text),private.mixed_visit_zero_remaining_units(text),private.guard_zero_visit_coverage(),private.guard_zero_visit_money(),private.invoice_document_data(uuid,boolean)from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION private.get_cashier_checkout_state(p_branch uuid, p_draft uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;d private.cashier_reviewed_drafts;p private.cashier_invoice_postings;i public.business_invoices;sale public.business_payment_events;
 b public.business_branches;shifts jsonb;invoice jsonb;work jsonb;refundable jsonb:='[]'::jsonb;history jsonb;line jsonb;previous_quantity integer;remaining integer;ready integer;refunded numeric:=0;can_refund boolean;begin
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
 if private.mixed_visit_zero_coverage_valid(p.invoice_id)then invoice:=invoice||jsonb_build_object('payment_status',case when private.mixed_visit_zero_remaining_units(p.invoice_id)=0 then'cancelled_reward'else'covered_by_reward'end,'payment_method','reward_coverage','net_collected',0,'cash_confirmed',false,'collection_required',false);end if;
 select coalesce(jsonb_agg(jsonb_build_object('refund_id',request_id,'number',result->>'refund_number','amount',amount,'payment_event_recorded',amount>0)order by created_at,request_id),'[]')into history from private.cashier_partial_refunds where invoice_id=p.invoice_id;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',o.order_id,'booking_id',w.booking_id,'reference',bk.display_number,'name',o.service_name,'name_en',coalesce(nullif((select quoted_line.value->>'name_en'from jsonb_array_elements(p.quote->'lines')as quoted_line(value)where quoted_line.value->>'line_id'=w.line_id),''),o.service_name),'status',o.status,'can_open',private.active_staff_role()in('owner','manager')or actor=any(o.assigned_staff_ids),'can_cancel',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.method='cash'and sale.amount=private.cashier_invoice_payable(i.invoice_id) and (select coalesce(sum(r.quantity),0)from private.cashier_partial_refund_lines r where r.invoice_id=w.invoice_id and r.line_id=w.line_id)<w.unit_number,'can_cancel_unpaid',private.active_staff_role()in('owner','manager')and o.status in('received','in_progress','quality_check')and i.status='active'and sale.payment_id is null and not exists(select 1 from private.paymob_intents where invoice_id=i.invoice_id),'unpaid_credit_preview_amount',(private.cashier_refund_slice_core(p.quote,w.line_id,w.unit_number-1,1)->>'amount')::numeric,'physical_clearance_required',o.status in('in_progress','quality_check')or exists(select 1 from private.service_resource_spans sp where sp.booking_id=w.booking_id and sp.ended_at is null))order by w.line_id,w.unit_number),'[]')into work from private.cashier_service_worklines w join public.business_orders o using(order_id)join public.bookings bk on bk.id=w.booking_id where w.invoice_id=p.invoice_id;
 if can_refund and(sale.method in('cash','card_terminal')or private.mixed_visit_zero_coverage_valid(p.invoice_id))and not exists(select 1 from private.cashier_full_refunds where invoice_id=p.invoice_id)then
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
