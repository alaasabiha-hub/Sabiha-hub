-- SOURCE ONLY: root must load inside an explicit outer ROLLBACK on a QA clone.
-- No fixture creation, fake earning, backdate, clock override or actual test run.
create function pg_temp.assert_typed_reward_heterogeneous(p_invoice text,p_workers uuid[])returns void language plpgsql as $$
declare i public.business_invoices;v_rates integer;v_n integer;v_total numeric;
begin
 assert current_database()like'qa_typed_reward_%','Explicit isolated QA clone required';
 select *into strict i from public.business_invoices where invoice_id=p_invoice;
 assert i.total=0 and i.discount>0 and i.commission_model='walk_in_frozen_workers'and i.commission_share is null;
 assert private.reward_invoice_coverage(p_invoice)->>'state'='covered_by_reward';
 select count(*),count(distinct rate_percent),sum(amount)into v_n,v_rates,v_total from private.offline_walk_in_commissions where invoice_id=p_invoice;
 assert cardinality(p_workers)>=2 and v_n=cardinality(p_workers)and v_rates>=2;
 assert not exists(select 1 from private.offline_walk_in_commissions c where c.invoice_id=p_invoice and(not(c.staff_id=any(p_workers))or c.gross<>i.total+i.discount or c.assigned_count<>v_n or c.amount<>round(c.gross*c.rate_percent/100/c.assigned_count,2)));
 assert i.commission_total=v_total;
 assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice);
 assert i.document_snapshot->>'payment_status'='covered_by_reward'and i.document_snapshot#>>'{reward_coverage,owner_kind}'='offline_profile';
end$$;

-- Requires a GENUINE naturally prior-UTC-day completed reward invoice, existing
-- current owner/session, actual employment covering that day and explicit owner
-- scheduled minutes. The helper never edits HR, dates, invoices or attendance.
-- Actual approval is confined to caller's outer ROLLBACK; no transfer is made.
create function pg_temp.assert_closed_day_typed_reward_payroll(p_invoice text,p_worker uuid,p_scheduled_minutes numeric)returns void language plpgsql as $$
declare i public.business_invoices;c private.offline_walk_in_commissions;v_day date;v_result jsonb;v_line jsonb;v_request uuid:=gen_random_uuid();v_old_invoice jsonb;
begin
 assert current_database()like'qa_typed_reward_%','Explicit isolated QA clone required';
 select *into strict i from public.business_invoices where invoice_id=p_invoice;
 select *into strict c from private.offline_walk_in_commissions where invoice_id=p_invoice and staff_id=p_worker;
 v_day:=(i.issued_at at time zone'UTC')::date;
 assert v_day<(clock_timestamp()at time zone'UTC')::date,'Wait for a real closed day; never backdate';
 assert p_scheduled_minutes>0 and p_scheduled_minutes::text not in('NaN','Infinity');
 assert exists(select 1 from public.business_orders where order_id=i.order_id and status in('completed','delivered'));
 assert private.reward_invoice_coverage(p_invoice)->>'state'='covered_by_reward';
 assert not exists(select 1 from private.hr_payroll where staff_id=p_worker and from_date<=v_day and to_date>=v_day),'Do not replace an existing payroll';
 v_old_invoice:=to_jsonb(i);
 execute 'set local role authenticated';
 v_result:=public.hr_action('approve_payroll',jsonb_build_object('staff_id',p_worker,'request_id',v_request,'from_date',v_day,'to_date',v_day,'scheduled_minutes',p_scheduled_minutes));
 execute 'reset role';
 select line into strict v_line from jsonb_array_elements(v_result#>'{snapshot,commission_lines}')line where line->>'invoice_id'=p_invoice;
 assert(v_line->>'before_discount')::numeric=i.discount and(v_line->>'commission')::numeric=c.amount;
 assert(v_line->>'rate_percent')::numeric=c.rate_percent;
 assert v_old_invoice=(select to_jsonb(row)from public.business_invoices row where invoice_id=p_invoice);
 assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice);
end$$;
