begin;
-- LOCAL-tested additive fix; no runtime activation, queue deletion or metadata reset.
create or replace function private.reconcile_offline_service_visit(p_order uuid)returns text language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare e private.canonical_loyalty_visits;r public.business_payment_events;facts jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Visit reconciliation requires READ COMMITTED'using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('canonical-visit:'||p_order::text,0));
 perform 1 from public.business_invoices i where i.order_id=p_order order by i.invoice_id for update of i;
 select * into e from private.canonical_loyalty_visits where order_id=p_order and kind='earn';
 if e.id is not null then
 if e.source_channel<>'offline_walk_in'then raise exception 'Typed source mismatch'using errcode='55000';end if;
 select p.*into r from public.business_payment_events p join public.business_cashier_shifts s on s.shift_id=p.shift_id where p.invoice_id=e.invoice_id and p.event_type='refund'and p.method='cash'and p.amount=(e.facts->>'sale_amount')::numeric and s.branch_id=e.branch_id;
 if r.payment_id is not null then
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,offline_profile_id,order_id,booking_id,invoice_id,sale_payment_id,refund_payment_id,activation_id,offline_activation_id,policy_version_id,reverses_earning,facts,source_channel,offline_order_snapshot_id)
 values('refund',-1,e.branch_id,null,e.offline_profile_id,p_order,null,e.invoice_id,e.sale_payment_id,r.payment_id,null,e.offline_activation_id,e.policy_version_id,e.id,jsonb_build_object('original_earning',e.id,'refund_payment_id',r.payment_id,'refund_amount',r.amount,'unit','service_visits'),'offline_walk_in',e.offline_order_snapshot_id)
 on conflict(reverses_earning)where kind='refund'do nothing;return 'refunded';end if;
 return 'already_earned';end if;
 -- A trusted full cash reversal is terminal even while future earning is paused.
 -- This check runs AFTER the existing order mutex/invoice locks, and creates no credit.
 if exists(select 1 from private.offline_walk_in_subjects subject
 join private.offline_service_visit_order_snapshots snapshot on snapshot.order_id=subject.order_id and snapshot.offline_profile_id=subject.profile_id and snapshot.car_ref_id=subject.car_ref_id and snapshot.branch_id=subject.branch_id and snapshot.catalog_item_id=subject.service_id and snapshot.earning_authorized
 join public.business_invoices invoice on invoice.invoice_id=subject.invoice_id and invoice.order_id=subject.order_id and invoice.branch_id=subject.branch_id and invoice.sale_type='service'and invoice.total=subject.gross and invoice.total>0
 join public.business_payment_events sale on sale.invoice_id=invoice.invoice_id and sale.event_type='sale'and sale.method='cash'and sale.amount=invoice.total
 join public.business_cashier_shifts sale_shift on sale_shift.shift_id=sale.shift_id and sale_shift.branch_id=subject.branch_id
 join public.business_payment_events refund on refund.invoice_id=invoice.invoice_id and refund.event_type='refund'and refund.method='cash'and refund.amount=sale.amount
 join public.business_cashier_shifts refund_shift on refund_shift.shift_id=refund.shift_id and refund_shift.branch_id=subject.branch_id
 where subject.order_id=p_order)then return 'fully_refunded_before_earning';end if;
 facts:=private.evaluate_offline_service_visit(p_order);
 if not coalesce((facts->>'eligible')::boolean,false)then return facts->>'reason';end if;
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,offline_profile_id,order_id,booking_id,invoice_id,sale_payment_id,activation_id,offline_activation_id,policy_version_id,facts,source_channel,offline_order_snapshot_id)
 values('earn',1,(facts->>'branch_id')::uuid,null,(facts->>'offline_profile_id')::uuid,p_order,null,facts->>'invoice_id',(facts->>'sale_payment_id')::uuid,null,(facts->>'offline_activation_id')::uuid,(facts->>'policy_version_id')::uuid,facts,'offline_walk_in',p_order)
 on conflict(order_id)where kind='earn'do nothing;
 return 'earned';
end$$;
commit;
