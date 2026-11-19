-- Do not infer all-method totals or shares without verified card coverage.
begin;
create or replace function private.get_ai_payment_analytics(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare lo timestamptz;hi timestamptz;b uuid;cash_in numeric;cash_out numeric;n bigint;series jsonb;services jsonb;cohorts jsonb;billed numeric;expenses numeric;begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Invalid analytics period';end if;
 lo:=p_from::timestamp at time zone 'Africa/Cairo';hi:=(p_to+1)::timestamp at time zone 'Africa/Cairo';
 select branch_id into b from public.business_branches where is_default and is_active;
 select coalesce(sum(e.amount) filter(where e.event_type='sale'),0),coalesce(sum(e.amount) filter(where e.event_type='refund'),0),count(*) filter(where e.event_type='sale')
 into cash_in,cash_out,n from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi;
 select coalesce(sum(total),0) into billed from public.business_invoices where branch_id=b and status='active' and issued_at>=lo and issued_at<hi;
 select coalesce(sum(amount),0) into expenses from public.business_expenses where branch_id=b and expense_date between p_from and p_to;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.period,x.date),'[]') into series from(
 select period,(date_trunc(period,e.created_at at time zone 'Africa/Cairo'))::date date,
 coalesce(sum(e.amount) filter(where event_type='sale'),0) cash_collections,coalesce(sum(e.amount) filter(where event_type='refund'),0) cash_refunds,
 sum(case when event_type='sale' then e.amount else -e.amount end) cash_net,count(*) transactions
 from public.business_payment_events e join public.business_invoices i using(invoice_id) cross join(values('day'),('week'),('month')) periods(period)
 where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi group by period,date_trunc(period,e.created_at at time zone 'Africa/Cairo'))x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into services from(
 select i.service_name,count(distinct i.invoice_id) invoices,sum(case when e.event_type='sale' then e.amount else -e.amount end) cash_net,null::numeric actual_profit
 from public.business_payment_events e join public.business_invoices i using(invoice_id) where i.branch_id=b and e.method='cash' and e.created_at>=lo and e.created_at<hi group by i.service_name)x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into cohorts from(
 select i.payment_policy_snapshot->'versions'->'card'->>'version_id' version_id,count(*) bookings,
 count(*) filter(where bk.status='completed') completed,round(100.0*count(*) filter(where bk.status='completed')/nullif(count(*),0),2) conversion_percent
 from public.business_invoices i join public.business_orders o using(order_id) join public.bookings bk on bk.id=o.booking_id
 where i.branch_id=b and i.issued_at>=lo and i.issued_at<hi group by i.payment_policy_snapshot->'versions'->'card'->>'version_id')x;
 return jsonb_build_object('period',jsonb_build_object('from',p_from,'to',p_to),'summary',jsonb_build_object('cash_collections',cash_in,'cash_refunds',cash_out,'cash_net',cash_in-cash_out,'cash_count',n,
 'card_collections',null,'card_count',null,'card_data_available',false,'gateway_fees_actual',null,'net_collections',null,'revenue_billed',billed,'actual_profit',null,'expenses_recorded',expenses,'cash_share_percent',null),
 'series',series,'services',services,'policy_cohorts',cohorts,'sufficient_data',n>=20,'analysis_mode','evidence_rules','sandbox_excluded',true,
 'recommendations',jsonb_build_array(jsonb_build_object('code','reconcile_gateway','message_ar','أضف تسويات وعمولات موثقة قبل مقارنة تكلفة البطاقات بالكاش.','message_en','Import verified gateway settlements and fees before comparing card and cash costs.'),
 jsonb_build_object('code','profit_data_missing','message_ar','الإيرادات وصافي التحصيل ليسا ربحًا؛ تكاليف الخدمات والضرائب والرواتب الكاملة غير مكتملة.','message_en','Revenue and net collections are not profit; complete service costs, taxes and payroll are required.')),
 'alerts',case when n<20 then jsonb_build_array(jsonb_build_object('code','insufficient_sample','message_ar','البيانات غير كافية لاستنتاج أثر سببي لسياسة الدفع أو اقتراح زيادة سعر.','message_en','Insufficient data for causal policy effects or a price-increase recommendation.')) else '[]'::jsonb end);
end;$$;
commit;
