begin;
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
 select coalesce(jsonb_agg(jsonb_build_object('item_id',c.item_id,'name',c.name,'item_type',c.item_type,'category',c.category,'price',c.price,'stock_quantity',c.stock_quantity,'duration_minutes',c.duration_minutes,'is_active',c.is_active,'branch_id',c.branch_id) order by c.name),'[]') into catalog from public.business_catalog_items c where c.branch_id=any(bs) and (r in ('owner','manager') or c.is_public and c.is_active);
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'service_name',b.service_name,'booking_date',b.booking_date,'booking_time',b.booking_time,'status',b.status,'branch_id',b.branch_id,'assigned_staff_ids',b.assigned_staff_ids) order by b.booking_date desc),'[]') into bookings from public.bookings b where b.branch_id=any(bs) and (b.booking_date+b.booking_time)>=p_from_local and (b.booking_date+b.booking_time)<p_to_local and (r in ('owner','manager') or uid=any(b.assigned_staff_ids));
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'full_name',c.full_name,'phone',c.phone)),'[]') into customers from public.customers c where r in ('owner','manager') and exists(select 1 from public.bookings b where b.customer_id=c.id and b.branch_id=any(bs));
 select coalesce(jsonb_agg(jsonb_build_object('shift_id',s.shift_id,'cashier_id',s.cashier_id,'branch_id',s.branch_id,'status',s.status,'opened_at',s.opened_at,'expected_cash',s.expected_cash,'actual_cash',s.actual_cash,'difference',s.difference)),'[]') into shifts from public.business_cashier_shifts s where s.branch_id=any(bs) and financial and (r in ('owner','manager') or s.cashier_id=uid) and s.opened_at<hi and coalesce(s.closed_at,hi)>=lo and (p_employee is null or s.cashier_id=p_employee);
 if financial then
 select coalesce(jsonb_agg(to_jsonb(q) order by q.issued_at desc),'[]') into inv from (
 select i.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,i.branch_id,i.service_name,i.sale_type,i.total,i.discount,i.status,i.payment_method,i.issued_at,case when r in ('owner','manager') then i.commission_total end commission_total,
 case when jsonb_typeof(i.document_snapshot->'tax_amount')='number' then (i.document_snapshot->>'tax_amount')::numeric end tax,
 case when jsonb_typeof(i.document_snapshot->'delivery_fee')='number' then (i.document_snapshot->>'delivery_fee')::numeric end fee,
 (select coalesce(sum(e.amount),0) from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale') collected
 from public.business_invoices i left join public.business_orders o on o.order_id=i.order_id
 where i.branch_id=any(bs) and i.issued_at>=lo and i.issued_at<hi
 and (r in ('owner','manager') or exists(select 1 from public.business_payment_events e join public.business_cashier_shifts s using(shift_id) where e.invoice_id=i.invoice_id and s.cashier_id=uid))
 and (p_employee is null or p_employee=any(o.assigned_staff_ids) or exists(select 1 from public.bookings b where b.id::text=i.document_snapshot->>'booking_id' and p_employee=any(b.assigned_staff_ids) and b.branch_id=any(bs)) or exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.actor_id=p_employee))
 and (p_service is null or i.service_name=p_service) and (p_method is null or exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.method=p_method and e.event_type='sale'))
 and (coalesce(p_search,'')='' or strpos(lower(i.invoice_id||' '||coalesce(i.display_number,'')||' '||i.service_name||' '||coalesce(o.customer_phone,'')),lower(p_search))>0)) q;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at),'[]') into pay from (
 select e.payment_id,e.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,e.event_type,e.method,e.amount,e.created_at,e.actor_id,extract(hour from e.created_at at time zone 'Africa/Cairo')::int cairo_hour from public.business_payment_events e join public.business_cashier_shifts s using(shift_id) join public.business_invoices i using(invoice_id) left join public.business_orders o on o.order_id=i.order_id
 where s.branch_id=any(bs) and e.created_at>=lo and e.created_at<hi and (r in ('owner','manager') or s.cashier_id=uid)
 and (p_employee is null or e.actor_id=p_employee or p_employee=any(o.assigned_staff_ids) or exists(select 1 from public.bookings b where b.id::text=i.document_snapshot->>'booking_id' and p_employee=any(b.assigned_staff_ids) and b.branch_id=any(bs))) and (p_service is null or i.service_name=p_service) and (p_method is null or e.method=p_method)
 and (coalesce(p_search,'')='' or strpos(lower(i.invoice_id||' '||coalesce(i.display_number,'')||' '||i.service_name||' '||coalesce(o.customer_phone,'')),lower(p_search))>0)) q;
 select jsonb_build_object('invoice_count',count(*),'net_billed',coalesce(sum(total),0),'billed_before_discount',coalesce(sum(total+discount),0),'discounts',coalesce(sum(discount),0),'average_invoice',coalesce(avg(total),0),'commissions',case when r in ('owner','manager') then coalesce(sum(commission_total),0) end,
 'taxes',case when count(*) filter(where tax is null)=0 then coalesce(sum(tax),0) end,'fees',case when count(*) filter(where fee is null)=0 then coalesce(sum(fee),0) end,
 'net_sales_ex_tax',case when count(*) filter(where tax is null or fee is null)=0 then coalesce(sum(total-tax-fee),0) end,
 'uncollected_recorded',coalesce(sum(greatest(total-collected,0)),0),'actual_profit',null,'liabilities',null,'net_to_account_for',null)
 into summary from jsonb_to_recordset(inv) as x(total numeric,discount numeric,tax numeric,fee numeric,collected numeric,status text,commission_total numeric) where status='active';
 select coalesce(jsonb_agg(to_jsonb(q) order by q.hour),'[]') into hourly from (select hour,coalesce(sum(x.total) filter(where x.status='active'),0) net_billed,coalesce(sum(x.total) filter(where x.status='refunded'),0) refunded_invoice_value from generate_series(0,23) hour left join jsonb_to_recordset(inv) x(issued_at timestamptz,total numeric,status text) on extract(hour from x.issued_at at time zone 'Africa/Cairo')=hour group by hour) q;
 select coalesce(jsonb_agg(to_jsonb(q)),'[]') into mix from(select service_name,sale_type,count(*) invoices,sum(total) total from jsonb_to_recordset(inv) x(service_name text,sale_type text,total numeric,status text) where status='active' group by service_name,sale_type) q;
 summary:=summary||jsonb_build_object('hourly',hourly,'product_mix',mix,'cash_activity',(select jsonb_build_object('transaction_count',count(*),'collections',coalesce(sum(amount) filter(where event_type='sale'),0),'refunds',coalesce(sum(amount) filter(where event_type='refund'),0)) from jsonb_to_recordset(pay) x(amount numeric,event_type text)),
 'refunded_invoice_value',(select coalesce(sum(total),0) from jsonb_to_recordset(inv) x(total numeric,status text) where status='refunded'));
 end if;
 extra:='{}';
 if r='owner' then extra:=jsonb_build_object('expenses',(select coalesce(jsonb_agg(jsonb_build_object('category',category,'amount',amount,'expense_date',expense_date)),'[]') from public.business_expenses where branch_id=any(bs) and expense_date>=p_from_local::date and expense_date<p_to_local::date),
 'worker_advances',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'advance_balance',advance_balance,'is_active',is_active)),'[]') from public.business_workers),
 'offers',(select coalesce(jsonb_agg(jsonb_build_object('name',name,'offer_type',offer_type,'is_active',is_active)),'[]') from public.business_offers where branch_id=any(bs)));end if;
 return jsonb_build_object('role',r,'financial',financial,'branches',branches,'staff',staff,'catalog',catalog,'bookings',bookings,'customers',customers,'shifts',shifts,'invoices',coalesce(inv,'[]'),'payments',coalesce(pay,'[]'),'report',summary,'extra',extra,'from_local',p_from_local,'to_local',p_to_local,'branch_id',p_branch,'time_zone','Africa/Cairo','currency','EGP','as_of',statement_timestamp(),'today_cairo',(statement_timestamp() at time zone 'Africa/Cairo')::date);
end;$function$;
CREATE OR REPLACE FUNCTION private.get_customer_booking_history()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.booking_date desc,h.booking_time desc,h.id) from (
    select b.id,b.branch_id,b.catalog_item_id,coalesce(b.display_number,b.id::text) booking_number,b.service_name,b.booking_date,b.booking_time,b.status,b.quoted_price,b.notes,b.vehicle_id,
      case when v.id is not null then jsonb_build_object('brand',v.brand,'model',v.model,'year',v.year,'plate_number',v.plate_number) end vehicle,
      i.invoice_id,i.invoice_number,i.document_token invoice_token,
      case when i.invoice_id is null then 'not_recorded' when i.status='void' then 'cancelled'
        when i.status='refunded' then 'refunded'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='cash') then 'paid'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='electronic') then 'verification_required'
        else 'unpaid' end payment_status,
      i.payment_method
    from public.bookings b
    left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
    left join lateral (
      select x.invoice_id,coalesce(x.display_number,x.invoice_id) invoice_number,x.document_token,x.status,x.payment_method from public.business_orders o
      join public.business_invoices x on x.order_id=o.order_id and x.branch_id=b.branch_id
      where o.booking_id=b.id and o.customer_id=b.customer_id and o.branch_id=b.branch_id
      order by x.issued_at desc,x.invoice_id limit 1
    ) i on true
    where b.customer_id=auth.uid()
  ) h),'[]'::jsonb);
end;$function$;
notify pgrst,'reload schema';
commit;
