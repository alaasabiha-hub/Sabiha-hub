begin;
-- Correct the existing free evidence reader; no model/provider, finance mutation,
-- new client privilege, retrospective invoice edit or inferred profit.
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
 select 1 ordinal,'billed_revenue' code,coalesce(sum(total-private.cashier_invoice_refunded_amount(invoice_id)),0)::numeric value,'EGP' unit,'business_invoices' source,count(*) n,'window' basis from public.business_invoices where branch_id=b and status='active' and issued_at>=lo and issued_at<hi
 union all select 2,'cash_net',coalesce(sum(case when e.event_type='sale' then e.amount else -e.amount end),0),'EGP','business_payment_events',count(*),'window' from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi
 union all select 3,'recorded_expenses',coalesce(sum(amount),0),'EGP','business_expenses',count(*),'window' from public.business_expenses where branch_id=b and expense_date between p_from and p_to
 union all select 4,'bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
 union all select 5,'completed_bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to and status='completed'
 union all select 6,'distinct_booking_customers',count(distinct customer_id)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
 union all select 7,'active_products',count(*)::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
 union all select 8,'out_of_stock_products',stock_count::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
 union all select 9,'average_review_stars',round(avg(stars),2),'stars','employee_service_reviews',count(*),'window' from public.employee_service_reviews where branch_id=b and created_at>=lo and created_at<hi
 ) x;
 return jsonb_build_object('branch_id',b,'scope','active_default_branch','period',jsonb_build_object('from',p_from,'to',p_to),'as_of',statement_timestamp(),'analysis_mode','evidence_rules','billed_revenue_basis','active_invoice_issue_cohort_net_of_cashier_line_refunds','cashier_refund_source','business_payment_events','earnings_are_not_profit',true,'sandbox_excluded',true,'metrics',metrics,
 'insights',jsonb_build_array(jsonb_build_object('code','stock_check','source','business_catalog_items','count',stock_count,'basis','current_snapshot','message_ar',case when stock_count>0 then 'توجد منتجات نشطة برصيد مسجل صفر؛ تحقق من الجرد قبل قرار الشراء.' else 'لا توجد منتجات نشطة برصيد مسجل صفر؛ هذا ليس توقعاً للطلب.' end,'message_en',case when stock_count>0 then 'Active products have recorded zero stock; verify counts before purchasing.' else 'No active products have recorded zero stock; this is not a demand forecast.' end),
 jsonb_build_object('code','sample_check','source','business_invoices','count',invoice_count,'basis','window','message_ar',case when invoice_count<20 then 'عينة الفواتير أقل من 20؛ لا تستنتج اتجاهاً أو سببية من هذه الفترة وحدها.' else 'الأرقام وصفية للفترة المختارة؛ لا تثبت سبب تغير النتائج.' end,'message_en',case when invoice_count<20 then 'Fewer than 20 invoices; do not infer trends or causality from this window alone.' else 'These figures describe the selected window; they do not establish causes.' end)),
 'limitations',jsonb_build_array('incomplete_costs_no_actual_profit','cash_only_card_and_gateway_unavailable','stock_is_current_not_historical','workload_is_booking_count_not_employee_productivity','reviews_may_be_small_or_unrepresentative','no_marketing_attribution','no_forecast_or_causal_inference'),
 'billed_revenue_basis','active_invoice_issue_window_net_cashier_line_refunds','cashier_refund_source','business_payment_events','actual_profit',null,'marketing_attribution',null,'forecast',null);
end;$function$;
commit;
