begin;
-- Extend the existing owner-only evidence RPC with additional bounded, aggregate
-- metrics. No customer/staff identity, narrative, or AI-provider call is exposed.
create or replace function private.owner_business_insights(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
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
  select 1 ordinal,'billed_revenue' code,coalesce(sum(total),0)::numeric value,'EGP' unit,'business_invoices' source,count(*) n,'window' basis from public.business_invoices where branch_id=b and status='active' and issued_at>=lo and issued_at<hi
  union all select 2,'cash_net',coalesce(sum(case when e.event_type='sale' then e.amount when e.event_type='refund' then -e.amount else 0 end),0),'EGP','business_payment_events',count(*),'window' from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi
  union all select 3,'recorded_expenses',coalesce(sum(amount),0),'EGP','business_expenses',count(*),'window' from public.business_expenses where branch_id=b and expense_date between p_from and p_to
  union all select 4,'bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
  union all select 5,'completed_bookings',count(*)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to and status='completed'
  union all select 6,'distinct_booking_customers',count(distinct customer_id)::numeric,'count','bookings',count(*),'window' from public.bookings where branch_id=b and booking_date between p_from and p_to
  union all select 7,'active_products',count(*)::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
  union all select 8,'out_of_stock_products',stock_count::numeric,'count','business_catalog_items',count(*),'current_snapshot' from public.business_catalog_items where branch_id=b and item_type='product' and is_active
  union all select 9,'average_review_stars',round(avg(stars),2),'stars','employee_service_reviews',count(*),'window' from public.employee_service_reviews where branch_id=b and created_at>=lo and created_at<hi
  union all select 10,'card_terminal_net',coalesce(sum(case when e.event_type='sale' then e.amount when e.event_type='refund' then -e.amount else 0 end),0),'EGP','business_payment_events',count(*),'window' from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='card_terminal' and e.created_at>=lo and e.created_at<hi
  union all select 11,'loyalty_movements',count(*)::numeric,'count','business_loyalty_transactions',count(*),'window' from public.business_loyalty_transactions t join public.business_orders o on o.order_id=t.order_id where o.branch_id=b and t.created_at>=lo and t.created_at<hi
  union all select 12,'coupon_redemptions',count(*)::numeric,'count','business_coupon_redemptions',count(*),'window' from public.business_coupon_redemptions r join public.business_orders o on o.order_id=r.order_id where o.branch_id=b and r.created_at>=lo and r.created_at<hi
  union all select 13,'active_offers',count(*)::numeric,'count','business_offers',count(*),'current_snapshot' from public.business_offers where branch_id=b and is_active
  union all select 14,'complaints_received',count(*)::numeric,'count','customer_complaints',count(*),'window' from public.customer_complaints where branch_id=b and created_at>=lo and created_at<hi
  union all select 15,'documents_expiring_30d',count(*)::numeric,'count','business_documents',count(*),'current_snapshot' from public.business_documents where expires_at>=statement_timestamp() and expires_at<statement_timestamp()+interval '30 days'
  union all select 16,'pending_recruitment',count(*)::numeric,'count','private.recruitment_applications',count(*),'window' from private.recruitment_applications a join private.recruitment_jobs j on j.id=a.job_id where j.branch_id=b and a.status in('submitted','interview') and a.submitted_at>=lo and a.submitted_at<hi
  union all select 17,'quality_pass_rate',round(100.0*count(*) filter(where q.passed)/nullif(count(*),0),2),'percent','private.service_quality_checks',count(*),'window' from private.service_quality_checks q join public.business_orders o on o.order_id=q.order_id where o.branch_id=b and q.created_at>=lo and q.created_at<hi
  union all select 18,'received_purchase_costs',coalesce(sum(p.total_cost),0),'EGP','public.business_purchase_orders',count(*),'window' from public.business_purchase_orders p where p.branch_id=b and p.status='received' and p.received_at>=lo and p.received_at<hi
 ) x;
 return jsonb_build_object('branch_id',b,'scope','active_default_branch','period',jsonb_build_object('from',p_from,'to',p_to),'as_of',statement_timestamp(),'analysis_mode','evidence_rules','sandbox_excluded',true,'metrics',metrics,
  'insights',jsonb_build_array(
   jsonb_build_object('code','stock_check','source','business_catalog_items','count',stock_count,'basis','current_snapshot','message_ar',case when stock_count>0 then 'توجد منتجات نشطة برصيد مسجل صفر؛ تحقق من الجرد قبل قرار الشراء.' else 'لا توجد منتجات نشطة برصيد مسجل صفر؛ هذا ليس توقعاً للطلب.' end,'message_en',case when stock_count>0 then 'Active products have recorded zero stock; verify counts before purchasing.' else 'No active products have recorded zero stock; this is not a demand forecast.' end),
   jsonb_build_object('code','sample_check','source','business_invoices','count',invoice_count,'basis','window','message_ar',case when invoice_count<20 then 'عينة الفواتير أقل من 20؛ لا تستنتج اتجاهاً أو سببية من هذه الفترة وحدها.' else 'الأرقام وصفية للفترة المختارة؛ لا تثبت سبب تغير النتائج.' end,'message_en',case when invoice_count<20 then 'Fewer than 20 invoices; do not infer trends or causality from this window alone.' else 'These figures describe the selected window; they do not establish causes.' end)),
  'limitations',jsonb_build_array('incomplete_costs_no_actual_profit','gateway_fees_unavailable','stock_is_current_not_historical','workload_is_booking_count_not_employee_productivity','reviews_may_be_small_or_unrepresentative','no_marketing_attribution','no_forecast_or_causal_inference','documents_are_company_wide','loyalty_metrics_cover_order_linked_movements','quality_checks_are_not_employee_scores','purchases_are_received_records_not_recommendations'),
  'actual_profit',null,'marketing_attribution',null,'forecast',null);
end;$$;
revoke all on function private.owner_business_insights(date,date) from public,anon;
grant execute on function private.owner_business_insights(date,date) to authenticated;
create or replace function public.get_owner_business_insights(p_from date,p_to date) returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select private.owner_business_insights(p_from,p_to);$$;
revoke all on function public.get_owner_business_insights(date,date) from public,anon;
grant execute on function public.get_owner_business_insights(date,date) to authenticated;
notify pgrst,'reload schema';
commit;
