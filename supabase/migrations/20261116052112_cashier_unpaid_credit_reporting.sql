begin;
-- Additive report correction only. Original documents, cash events and earned commissions stay immutable.
CREATE OR REPLACE FUNCTION private.admin_console_data(p_from_local timestamp without time zone, p_to_local timestamp without time zone, p_branch uuid, p_employee uuid, p_service text, p_method text, p_search text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare r text:=private.active_staff_role(); uid uuid:=auth.uid(); bs uuid[]; lo timestamptz; hi timestamptz; boundary timestamp;
 inv jsonb; pay jsonb; summary jsonb; hourly jsonb; mix jsonb; branches jsonb; staff jsonb; catalog jsonb; bookings jsonb; shifts jsonb; customers jsonb; extra jsonb; financial boolean;
begin
 if uid is null or r is null or r not in ('owner','manager','employee') then raise exception 'Active staff access required' using errcode='42501';end if;
 if p_from_local is null or p_to_local is null or not isfinite(p_from_local) or not isfinite(p_to_local) or p_to_local<=p_from_local or p_to_local-p_from_local>interval '366 days' then raise exception 'Invalid report window';end if;
 foreach boundary in array array[p_from_local,p_to_local] loop
  if (boundary at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'<>boundary or ((boundary at time zone 'Africa/Cairo')+interval '1 hour') at time zone 'Africa/Cairo'=boundary or ((boundary at time zone 'Africa/Cairo')-interval '1 hour') at time zone 'Africa/Cairo'=boundary then raise exception 'Ambiguous Cairo boundary';end if;
 end loop;
 if p_method is not null and p_method not in ('cash','electronic') then raise exception 'Unknown payment method';end if;
 if length(coalesce(p_search,''))>120 then raise exception 'Search too long';end if;
 select array_agg(branch_id) into bs from public.business_branches b where (r='owner' or exists(select 1 from public.staff_branch_access a where a.user_id=uid and a.branch_id=b.branch_id));
 if p_branch is not null and not coalesce(p_branch=any(bs),false) then raise exception 'Branch access denied' using errcode='42501';end if;
 if p_branch is not null then bs:=array[p_branch];end if;
 financial:=r in ('owner','manager') or exists(select 1 from public.staff_profiles where user_id=uid and is_active and permissions->>'cashier'='true');
 if r='employee' and p_employee is not null and p_employee<>uid then raise exception 'Employee scope denied' using errcode='42501';end if;
 lo:=p_from_local at time zone 'Africa/Cairo'; hi:=p_to_local at time zone 'Africa/Cairo';
 select coalesce(jsonb_agg(jsonb_build_object('branch_id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en,'is_active',b.is_active,'address_ar',b.address_ar,'currency',b.currency,'time_zone',b.time_zone) order by b.name_en),'[]') into branches from public.business_branches b where b.branch_id=any(bs);
 select coalesce(jsonb_agg(jsonb_build_object('user_id',s.user_id,'full_name',s.full_name,'role',s.role,'is_active',s.is_active)),'[]') into staff from public.staff_profiles s where (r='owner' or s.user_id=uid or r='manager' and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=any(bs)));
 select coalesce(jsonb_agg(jsonb_build_object('item_id',c.item_id,'name',c.name,'name_en',c.name_en,'item_type',c.item_type,'category',c.category,'price',c.price,'stock_quantity',c.stock_quantity,'duration_minutes',c.duration_minutes,'is_active',c.is_active,'branch_id',c.branch_id) order by c.name),'[]') into catalog from public.business_catalog_items c where c.branch_id=any(bs) and (r in ('owner','manager') or c.is_public and c.is_active);
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'service_name',b.service_name,'booking_date',b.booking_date,'booking_time',b.booking_time,'status',b.status,'branch_id',b.branch_id,'assigned_staff_ids',b.assigned_staff_ids) order by b.booking_date desc),'[]') into bookings from public.bookings b where b.branch_id=any(bs) and (b.booking_date+b.booking_time)>=p_from_local and (b.booking_date+b.booking_time)<p_to_local and (r in ('owner','manager') or uid=any(b.assigned_staff_ids));
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'full_name',c.full_name,'phone',c.phone)),'[]') into customers from public.customers c where r in ('owner','manager') and exists(select 1 from public.bookings b where b.customer_id=c.id and b.branch_id=any(bs));
 select coalesce(jsonb_agg(jsonb_build_object('shift_id',s.shift_id,'cashier_id',s.cashier_id,'branch_id',s.branch_id,'status',s.status,'opened_at',s.opened_at,'expected_cash',s.expected_cash,'actual_cash',s.actual_cash,'difference',s.difference)),'[]') into shifts from public.business_cashier_shifts s where s.branch_id=any(bs) and financial and (r in ('owner','manager') or s.cashier_id=uid) and s.opened_at<hi and coalesce(s.closed_at,hi)>=lo and (p_employee is null or s.cashier_id=p_employee);
 if financial then
 select coalesce(jsonb_agg(to_jsonb(q) order by q.issued_at desc),'[]') into inv from (
 select i.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,i.branch_id,i.service_name,i.sale_type,i.total,case when cp.invoice_id is not null then(cp.quote->>'invoice_discount_exact')::numeric+(cp.quote->>'item_discount_exact')::numeric else i.discount end discount,i.status,i.payment_method,i.issued_at,case when r in ('owner','manager') then case when i.commission_model='cashier_frozen_lines' then private.cashier_invoice_earned_commission(i.invoice_id)else i.commission_total end end commission_total,
 case when r in ('owner','manager')then i.commission_model end commission_model,
 cp.invoice_id is not null reviewed_cashier_invoice,
 case when cp.invoice_id is not null then(cp.quote->>'subtotal_before_discount_exact')::numeric end gross_sales_ex_tax,
 case when cp.invoice_id is not null then(select sum((value->>'base_before_discount_exact')::numeric+(value->>'original_tax_exact')::numeric)from jsonb_array_elements(cp.quote->'lines'))else i.total+i.discount end billed_before_discount,
 case when cp.invoice_id is not null then(select sum((value->>'original_tax_exact')::numeric)from jsonb_array_elements(cp.quote->'lines'))-(cp.quote->>'tax_amount_exact')::numeric end discount_tax_effect,
 case when cp.invoice_id is not null then(cp.quote->>'payable_rounding')::numeric end payable_rounding,
 private.cashier_invoice_refunded_amount(i.invoice_id)cashier_refunded_amount,
 private.cashier_invoice_refunded_tax(i.invoice_id)cashier_refunded_tax,
 private.cashier_invoice_unpaid_credit(i.invoice_id)unpaid_credit_amount,private.cashier_invoice_unpaid_credit_tax(i.invoice_id)unpaid_credit_tax,
 case when jsonb_typeof(i.document_snapshot->'tax_amount')='number' then (i.document_snapshot->>'tax_amount')::numeric end tax,
 case when cp.invoice_id is not null then 0 when jsonb_typeof(i.document_snapshot->'delivery_fee')='number'then(i.document_snapshot->>'delivery_fee')::numeric end fee,
 (select coalesce(sum(e.amount),0) from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale') collected
 from public.business_invoices i left join public.business_orders o on o.order_id=i.order_id left join private.cashier_invoice_postings cp on cp.invoice_id=i.invoice_id
 where i.branch_id=any(bs) and i.issued_at>=lo and i.issued_at<hi
 and (r in ('owner','manager') or exists(select 1 from public.business_payment_events e join public.business_cashier_shifts s using(shift_id) where e.invoice_id=i.invoice_id and s.cashier_id=uid))
 and (p_employee is null or private.cashier_invoice_has_staff(i.invoice_id,p_employee) or p_employee=any(o.assigned_staff_ids) or exists(select 1 from public.bookings b where b.id::text=i.document_snapshot->>'booking_id' and p_employee=any(b.assigned_staff_ids) and b.branch_id=any(bs)) or exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.actor_id=p_employee))
 and (p_service is null or i.service_name=p_service or private.cashier_invoice_matches_service(i.invoice_id,p_service)) and (p_method is null or exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.method=p_method and e.event_type='sale'))
 and (coalesce(p_search,'')='' or strpos(lower(i.invoice_id||' '||coalesce(i.display_number,'')||' '||i.service_name||' '||coalesce(o.customer_phone,'')),lower(p_search))>0)) q;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at),'[]') into pay from (
 select e.payment_id,e.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,e.event_type,e.method,e.amount,e.created_at,e.actor_id,extract(hour from e.created_at at time zone 'Africa/Cairo')::int cairo_hour from public.business_payment_events e join public.business_cashier_shifts s using(shift_id) join public.business_invoices i using(invoice_id) left join public.business_orders o on o.order_id=i.order_id
 where s.branch_id=any(bs) and e.created_at>=lo and e.created_at<hi and (r in ('owner','manager') or s.cashier_id=uid)
 and (p_employee is null or e.actor_id=p_employee or private.cashier_invoice_has_staff(i.invoice_id,p_employee) or p_employee=any(o.assigned_staff_ids) or exists(select 1 from public.bookings b where b.id::text=i.document_snapshot->>'booking_id' and p_employee=any(b.assigned_staff_ids) and b.branch_id=any(bs))) and (p_service is null or i.service_name=p_service or private.cashier_invoice_matches_service(i.invoice_id,p_service)) and (p_method is null or e.method=p_method)
 and (coalesce(p_search,'')='' or strpos(lower(i.invoice_id||' '||coalesce(i.display_number,'')||' '||i.service_name||' '||coalesce(o.customer_phone,'')),lower(p_search))>0)) q;
 select jsonb_build_object('invoice_count',count(*),'net_billed',coalesce(sum(total-cashier_refunded_amount-unpaid_credit_amount),0),'billed_before_discount',coalesce(sum(billed_before_discount),0),'gross_sales_ex_tax',case when count(*)filter(where gross_sales_ex_tax is null)=0 then coalesce(sum(gross_sales_ex_tax),0)end,'discounts',coalesce(sum(discount),0),'average_invoice',coalesce(avg(total-cashier_refunded_amount-unpaid_credit_amount),0),'commissions',case when r in ('owner','manager') then coalesce(sum(commission_total),0) end,
 'taxes',case when count(*) filter(where tax is null)=0 then coalesce(sum(tax-cashier_refunded_tax-unpaid_credit_tax),0) end,'fees',case when count(*) filter(where fee is null)=0 then coalesce(sum(fee),0) end,
 'net_sales_ex_tax',case when count(*) filter(where tax is null or fee is null)=0 then coalesce(sum(total-cashier_refunded_amount-unpaid_credit_amount-tax+cashier_refunded_tax+unpaid_credit_tax-fee),0) end,
 'uncollected_recorded',coalesce(sum(greatest(total-unpaid_credit_amount-collected,0)),0),'actual_profit',null,'liabilities',null,'net_to_account_for',null)
 into summary from jsonb_to_recordset(inv) as x(total numeric,discount numeric,tax numeric,fee numeric,collected numeric,status text,commission_total numeric,billed_before_discount numeric,gross_sales_ex_tax numeric,cashier_refunded_amount numeric,cashier_refunded_tax numeric,unpaid_credit_amount numeric,unpaid_credit_tax numeric) where status='active';
 select coalesce(jsonb_agg(to_jsonb(q) order by q.hour),'[]') into hourly from (select hour,coalesce(sum(x.total-coalesce(x.cashier_refunded_amount,0)-coalesce(x.unpaid_credit_amount,0)) filter(where x.status='active'),0) net_billed,coalesce(sum(x.total) filter(where x.status='refunded'),0) refunded_invoice_value from generate_series(0,23) hour left join jsonb_to_recordset(inv) x(issued_at timestamptz,total numeric,status text,cashier_refunded_amount numeric,unpaid_credit_amount numeric) on extract(hour from x.issued_at at time zone 'Africa/Cairo')=hour group by hour) q;
 select coalesce(jsonb_agg(to_jsonb(q)),'[]') into mix from(select service_name,sale_type,count(*) invoices,sum(total-cashier_refunded_amount-unpaid_credit_amount)total from jsonb_to_recordset(inv) x(service_name text,sale_type text,total numeric,status text,cashier_refunded_amount numeric,unpaid_credit_amount numeric) where status='active' group by service_name,sale_type) q;
 summary:=summary||jsonb_build_object('hourly',hourly,'product_mix',mix,'cash_activity',(select jsonb_build_object('transaction_count',count(*),'collections',coalesce(sum(amount) filter(where event_type='sale'),0),'refunds',coalesce(sum(amount) filter(where event_type='refund'),0)) from jsonb_to_recordset(pay) x(amount numeric,event_type text)),
 'refunded_invoice_value',(select coalesce(sum(total),0) from jsonb_to_recordset(inv) x(total numeric,status text) where status='refunded'));

 summary:=summary||jsonb_build_object(
 'commissions',case when r in('owner','manager')then(select coalesce(sum(commission_total)filter(where status='active'or commission_model='cashier_frozen_lines'),0)from jsonb_to_recordset(inv)x(commission_total numeric,status text,commission_model text))end,
 'commission_basis','legacy_recorded_and_completed_cashier_work_on_selected_invoices',
 'cashier_commissions_earned_in_period',case when r='owner'then private.cashier_period_earned_commission(lo,hi,bs,p_employee,p_service)end,
 'earned_period_staff_scope',case when p_employee is null then'all_staff'else'selected_staff'end,
 'discount_tax_effect_recorded',(select coalesce(sum(discount_tax_effect),0)from jsonb_to_recordset(inv)x(discount_tax_effect numeric,status text)where status='active'),
 'discount_tax_effect_complete',(select count(*)filter(where discount_tax_effect is null)=0 from jsonb_to_recordset(inv)x(discount_tax_effect numeric,status text)where status='active'),
 'cashier_payable_rounding',(select coalesce(sum(payable_rounding),0)from jsonb_to_recordset(inv)x(payable_rounding numeric,status text)where status='active'),
 'cashier_refunds_on_active_invoices',(select coalesce(sum(cashier_refunded_amount),0)from jsonb_to_recordset(inv)x(cashier_refunded_amount numeric,status text)where status='active'),
 'contains_reviewed_cashier',(select coalesce(bool_or(reviewed_cashier_invoice),false)from jsonb_to_recordset(inv)x(reviewed_cashier_invoice boolean)),
 'contains_mixed_invoices',(select exists(select 1 from jsonb_to_recordset(inv)x(sale_type text)where sale_type='mixed')),
 'filter_scope','matching_invoices',
 'filter_notice_required',(p_employee is not null or p_service is not null)and(select exists(select 1 from jsonb_to_recordset(inv)x(sale_type text)where sale_type='mixed')),
 'product_mix_basis','invoice_container',
 'actual_profit',null,'profit_status','insufficient_cost_coverage',
 'unpaid_service_credits',(select coalesce(sum(unpaid_credit_amount),0)from jsonb_to_recordset(inv)x(unpaid_credit_amount numeric,status text)where status='active'),'unpaid_credit_tax',(select coalesce(sum(unpaid_credit_tax),0)from jsonb_to_recordset(inv)x(unpaid_credit_tax numeric,status text)where status='active'),'unpaid_credits_are_not_cash_refunds',true,'cashier_refund_tax_is_internal_allocation_not_eta_acceptance',true);
 end if;
 extra:='{}';
 if r='owner' then extra:=jsonb_build_object('expenses',(select coalesce(jsonb_agg(jsonb_build_object('category',category,'amount',amount,'expense_date',expense_date)),'[]') from public.business_expenses where branch_id=any(bs) and expense_date>=p_from_local::date and expense_date<p_to_local::date),
 'worker_advances',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'advance_balance',advance_balance,'is_active',is_active)),'[]') from public.business_workers),
 'offers',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'offer_type',offer_type,'is_active',is_active)),'[]') from public.business_offers where branch_id=any(bs)));end if;
 return jsonb_build_object('role',r,'financial',financial,'branches',branches,'staff',staff,'catalog',catalog,'bookings',bookings,'customers',customers,'shifts',shifts,'invoices',coalesce(inv,'[]'),'payments',coalesce(pay,'[]'),'report',summary,'extra',extra,'from_local',p_from_local,'to_local',p_to_local,'branch_id',p_branch,'time_zone','Africa/Cairo','currency','EGP','as_of',statement_timestamp(),'today_cairo',(statement_timestamp() at time zone 'Africa/Cairo')::date);
end;$function$;
CREATE OR REPLACE FUNCTION private.branch_owner_report(p_from date, p_to date, p_zone text, p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_start timestamptz; v_end timestamptz; v_sales numeric; v_refunds numeric;
 v_commission numeric; v_expenses numeric; v_count bigint; v_daily jsonb; v_payments jsonb;v_cashier_count bigint;v_cashier_period numeric;v_activity jsonb;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then
   raise exception 'Active owner access required' using errcode='42501';
 end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Choose a date range of up to 367 days'; end if;
 if not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Unknown report time zone'; end if;
 v_start:=p_from::timestamp at time zone p_zone;
 v_end:=(p_to+1)::timestamp at time zone p_zone;
 select coalesce(sum(total-private.cashier_invoice_refunded_amount(invoice_id)-private.cashier_invoice_unpaid_credit(invoice_id))filter(where status='active'),0),
 coalesce(sum(case when exists(select 1 from private.cashier_invoice_postings p where p.invoice_id=business_invoices.invoice_id)then private.cashier_invoice_refunded_amount(invoice_id)when status='refunded'then total else 0 end),0),
 coalesce(sum(case when commission_model='cashier_frozen_lines'then private.cashier_invoice_earned_commission(invoice_id)when status='active'then commission_total else 0 end),0),count(*)filter(where status='active')
 into v_sales,v_refunds,v_commission,v_count from public.business_invoices where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end;
 select coalesce(sum(amount),0) into v_expenses from public.business_expenses where (p_branch is null or branch_id=p_branch) and expense_date between p_from and p_to;
 select coalesce(jsonb_agg(to_jsonb(d) order by d.day),'[]') into v_daily from (
   select (issued_at at time zone p_zone)::date as day, sum(total-private.cashier_invoice_refunded_amount(invoice_id)-private.cashier_invoice_unpaid_credit(invoice_id)) as sales,count(*) as invoices
   from public.business_invoices where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end and status='active' group by 1) d;
 select coalesce(jsonb_agg(to_jsonb(p)),'[]') into v_payments from (
   select coalesce(payment_method,'unspecified') as method,sum(total-private.cashier_invoice_refunded_amount(invoice_id)-private.cashier_invoice_unpaid_credit(invoice_id)) as total from public.business_invoices
   where (p_branch is null or branch_id=p_branch) and issued_at>=v_start and issued_at<v_end and status='active' group by 1) p;

 select count(*)into v_cashier_count from private.cashier_invoice_postings p join public.business_invoices i using(invoice_id)
 where(p_branch is null or i.branch_id=p_branch)and i.issued_at>=v_start and i.issued_at<v_end;
 v_cashier_period:=private.cashier_period_earned_commission(v_start,v_end,case when p_branch is null then null else array[p_branch]end,null,null);
 select jsonb_build_object('collections',coalesce(sum(e.amount)filter(where e.event_type='sale'),0),'refunds',coalesce(sum(e.amount)filter(where e.event_type='refund'),0),'net_collections',coalesce(sum(case when e.event_type='sale'then e.amount else-e.amount end),0),'date_basis','payment_event_time')into v_activity
 from public.business_payment_events e join public.business_invoices i using(invoice_id)
 where(p_branch is null or i.branch_id=p_branch)and e.created_at>=v_start and e.created_at<v_end;
 return jsonb_build_object('from',p_from,'to',p_to,'time_zone',p_zone,'sales',v_sales,'refunded_total',v_refunds,
   'commissions',v_commission,'expenses',v_expenses,'net_before_tax',case when v_cashier_count=0 and v_cashier_period=0 then v_sales-v_commission-v_expenses end,
 'actual_profit',null,'profit_status',case when v_cashier_count>0 or v_cashier_period>0 then'insufficient_cost_coverage'else'legacy_recorded_balance_only'end,
 'cashier_commissions_earned_in_period',v_cashier_period,'commission_basis','legacy_recorded_and_completed_cashier_work_on_invoice_cohort',
 'cash_activity',v_activity,'payment_breakdown_basis','active_invoice_intended_method_not_settlement',
   'invoice_count',v_count,'daily',v_daily,'payments',v_payments);
end; $function$;
CREATE OR REPLACE FUNCTION private.owner_business_insights(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare b uuid;lo timestamptz;hi timestamptz;metrics jsonb;stock_count bigint;invoice_count bigint;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Invalid evidence period' using errcode='22023';end if;
 select branch_id into b from public.business_branches where is_default and is_active;
 if b is null then raise exception 'Active default branch required';end if;
 lo:=p_from::timestamp at time zone 'Africa/Cairo';hi:=(p_to+1)::timestamp at time zone 'Africa/Cairo';
 select count(*) into invoice_count from public.business_invoices where branch_id=b and status='active' and issued_at>=lo and issued_at<hi;
 select count(*) into stock_count from public.business_catalog_items where branch_id=b and item_type='product' and is_active and stock_quantity=0;
 select jsonb_agg(jsonb_build_object('code',code,'value',value,'unit',unit,'source',source,'count',n,'basis',basis) order by ordinal) into metrics from (
 select 1 ordinal,'billed_revenue' code,coalesce(sum(total-private.cashier_invoice_refunded_amount(invoice_id)-private.cashier_invoice_unpaid_credit(invoice_id)),0)::numeric value,'EGP' unit,'business_invoices' source,count(*) n,'window' basis from public.business_invoices where branch_id=b and status='active' and issued_at>=lo and issued_at<hi
 union all select 2,'cash_net',coalesce(sum(case when e.event_type='sale' then e.amount else -e.amount end),0),'EGP','business_payment_events',count(*),'window' from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi
 union all select 3,'recorded_expenses',coalesce(sum(amount),0),'EGP','business_expenses',count(*),'window' from public.business_expenses where branch_id=b and expense_date between p_from and p_to
 union all select 4,'bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
 union all select 5,'completed_bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to and status='completed'
 union all select 6,'distinct_booking_customers',count(distinct customer_id)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
 union all select 7,'active_products',count(*)::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
 union all select 8,'out_of_stock_products',stock_count::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
 union all select 9,'average_review_stars',round(avg(stars),2),'stars','employee_service_reviews',count(*),'window' from public.employee_service_reviews where branch_id=b and created_at>=lo and created_at<hi
 ) x;
 return jsonb_build_object('branch_id',b,'scope','active_default_branch','period',jsonb_build_object('from',p_from,'to',p_to),'as_of',statement_timestamp(),'analysis_mode','evidence_rules','billed_revenue_basis','active_invoice_issue_cohort_net_of_cashier_line_refunds','cashier_refund_source','business_payment_events','unpaid_credits_included',true,'unpaid_credits_are_not_cash_refunds',true,'earnings_are_not_profit',true,'sandbox_excluded',true,'metrics',metrics,
 'insights',jsonb_build_array(jsonb_build_object('code','stock_check','source','business_catalog_items','count',stock_count,'basis','current_snapshot','message_ar',case when stock_count>0 then 'توجد منتجات نشطة برصيد مسجل صفر؛ تحقق من الجرد قبل قرار الشراء.' else 'لا توجد منتجات نشطة برصيد مسجل صفر؛ هذا ليس توقعاً للطلب.' end,'message_en',case when stock_count>0 then 'Active products have recorded zero stock; verify counts before purchasing.' else 'No active products have recorded zero stock; this is not a demand forecast.' end),
 jsonb_build_object('code','sample_check','source','business_invoices','count',invoice_count,'basis','window','message_ar',case when invoice_count<20 then 'عينة الفواتير أقل من 20؛ لا تستنتج اتجاهاً أو سببية من هذه الفترة وحدها.' else 'الأرقام وصفية للفترة المختارة؛ لا تثبت سبب تغير النتائج.' end,'message_en',case when invoice_count<20 then 'Fewer than 20 invoices; do not infer trends or causality from this window alone.' else 'These figures describe the selected window; they do not establish causes.' end)),
 'limitations',jsonb_build_array('incomplete_costs_no_actual_profit','cash_only_card_and_gateway_unavailable','stock_is_current_not_historical','workload_is_booking_count_not_employee_productivity','reviews_may_be_small_or_unrepresentative','no_marketing_attribution','no_forecast_or_causal_inference'),
 'billed_revenue_basis','active_invoice_issue_window_net_cashier_line_refunds','cashier_refund_source','business_payment_events','actual_profit',null,'marketing_attribution',null,'forecast',null);
end;$function$;
commit;
