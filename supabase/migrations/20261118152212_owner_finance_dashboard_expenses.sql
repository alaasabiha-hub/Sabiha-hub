begin;

-- QA-first finance additions. Historical business_expenses rows remain untouched.
-- New expense writes are only possible through audited, idempotent owner RPCs.
create table private.owner_expense_records (
  expense_id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  branch_id uuid not null references public.business_branches(branch_id),
  category text not null check (category in (
    'rent','electricity','water','salary','commission','washing_supplies',
    'maintenance','internet_telecom','marketing','other'
  )),
  custom_category text,
  amount numeric(14,2) not null check (amount > 0 and amount < 'NaN'::numeric),
  expense_date date not null,
  due_date date,
  status text not null default 'unpaid' check (status in ('unpaid','paid','void')),
  payment_method text check (payment_method in ('cash','card_terminal','bank_transfer','other')),
  paid_at timestamptz,
  external_reference text,
  note text not null default '' check (length(note) <= 1000),
  attachment_path text,
  recurrence_rule text not null default 'none' check (recurrence_rule in ('none','daily','weekly','monthly','yearly')),
  recurrence_until date,
  recurrence_group uuid,
  revision integer not null default 1 check (revision > 0),
  created_by uuid not null references auth.users(id),
  updated_by uuid not null references auth.users(id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((category='other' and length(trim(coalesce(custom_category,''))) between 2 and 80)
      or (category<>'other' and custom_category is null)),
  check ((status='paid' and paid_at is not null and payment_method is not null)
      or (status<>'paid' and paid_at is null)),
  check ((recurrence_rule='none' and recurrence_until is null and recurrence_group is null)
      or (recurrence_rule<>'none' and recurrence_until >= expense_date and recurrence_group is not null))
);
create unique index owner_expense_reference_unique
  on private.owner_expense_records(branch_id, lower(external_reference))
  where external_reference is not null and length(trim(external_reference))>0 and status<>'void';
create unique index owner_expense_series_day_unique
  on private.owner_expense_records(recurrence_group, expense_date)
  where recurrence_group is not null;
create index owner_expense_branch_date_idx
  on private.owner_expense_records(branch_id, expense_date desc) where status<>'void';

create table private.owner_expense_audit (
  audit_id bigint generated always as identity primary key,
  expense_id uuid not null references private.owner_expense_records(expense_id),
  request_id uuid not null,
  actor_id uuid not null references auth.users(id),
  action text not null check (action in ('created','edited','paid','voided','recurrence_materialized')),
  before_data jsonb,
  after_data jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
create table private.owner_expense_requests (
  request_id uuid primary key,
  actor_id uuid not null references auth.users(id),
  action text not null,
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
do $$ begin
  alter table private.owner_expense_records enable row level security;
  alter table private.owner_expense_audit enable row level security;
  alter table private.owner_expense_requests enable row level security;
end $$;
revoke all on private.owner_expense_records, private.owner_expense_audit,
  private.owner_expense_requests from public, anon, authenticated, service_role;

create function private.can_manage_finance_branch(p_branch uuid, p_write boolean default false)
returns boolean language sql stable security definer set search_path=pg_catalog as $$
  select case
    when (select private.active_staff_role())='owner' then exists(
      select 1 from public.business_branches b where b.branch_id=p_branch and b.is_active
    )
    when (select private.active_staff_role())='manager' then exists(
      select 1 from public.staff_profiles s
      join public.staff_branch_access a on a.user_id=s.user_id
      join public.business_branches b on b.branch_id=a.branch_id
      where s.user_id=(select auth.uid()) and s.is_active and a.branch_id=p_branch and b.is_active
        and s.permissions->>'financial_reports'='true'
        and (not p_write or s.permissions->>'manage_expenses'='true')
    )
    else false end
$$;
revoke all on function private.can_manage_finance_branch(uuid,boolean) from public,anon;
grant execute on function private.can_manage_finance_branch(uuid,boolean) to authenticated;

create function private.owner_finance_dashboard(p_branch uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare
  actor uuid:=auth.uid(); zone_name text; lo timestamptz; hi timestamptz;
  payment_data jsonb; booking_data jsonb; invoice_status_data jsonb; expense_data jsonb;
  commission_data jsonb; daily_data jsonb; tax_complete boolean; revenue_ex_tax numeric;
  invoice_count integer; billed numeric; discounts numeric; paid numeric; refunded numeric;
  pending numeric; visit_count integer; payroll_data jsonb;
begin
  if actor is null or p_branch is null or p_from is null or p_to is null
     or p_to<p_from or p_to-p_from>366
     or not coalesce(private.can_manage_finance_branch(p_branch,false),false) then
    raise exception 'Finance report access or date range is invalid' using errcode='42501';
  end if;
  select time_zone into zone_name from public.business_branches where branch_id=p_branch and is_active;
  if zone_name is null then raise exception 'Active branch required' using errcode='42501'; end if;
  lo:=p_from::timestamp at time zone zone_name;
  hi:=(p_to+1)::timestamp at time zone zone_name;

  select count(*) filter(where i.status='active'),
         coalesce(sum(i.total-private.cashier_invoice_refunded_amount(i.invoice_id)-private.cashier_invoice_unpaid_credit(i.invoice_id)) filter(where i.status='active'),0),
         coalesce(sum(i.discount) filter(where i.status='active'),0),
         bool_and(case when cp.invoice_id is not null then cp.quote ? 'tax_amount_exact'
           else jsonb_typeof(i.document_snapshot->'tax_amount')='number' end),
         case when bool_and(case when cp.invoice_id is not null then cp.quote ? 'tax_amount_exact'
           else jsonb_typeof(i.document_snapshot->'tax_amount')='number' end)
           then coalesce(sum(i.total-coalesce(case when cp.invoice_id is not null
             then (cp.quote->>'tax_amount_exact')::numeric
             else (i.document_snapshot->>'tax_amount')::numeric end,0)
             -coalesce(case when cp.invoice_id is null and jsonb_typeof(i.document_snapshot->'delivery_fee')='number'
               then (i.document_snapshot->>'delivery_fee')::numeric else 0 end,0)
             -private.cashier_invoice_refunded_amount(i.invoice_id)
             +private.cashier_invoice_refunded_tax(i.invoice_id)
             -private.cashier_invoice_unpaid_credit(i.invoice_id)
             +private.cashier_invoice_unpaid_credit_tax(i.invoice_id)) filter(where i.status='active'),0) end,
         coalesce(sum(private.cashier_invoice_refunded_amount(i.invoice_id)) filter(where i.status in ('active','refunded')),0)
    into invoice_count,billed,discounts,tax_complete,revenue_ex_tax,refunded
    from public.business_invoices i
    left join private.cashier_invoice_postings cp on cp.invoice_id=i.invoice_id
   where i.branch_id=p_branch and i.issued_at>=lo and i.issued_at<hi and i.status<>'void';

  select coalesce(jsonb_object_agg(status,cnt),'{}'::jsonb) into invoice_status_data from (
    select status,count(*) cnt from public.business_invoices
     where branch_id=p_branch and issued_at>=lo and issued_at<hi group by status
  ) invoice_states;

  select coalesce(sum(e.sales),0),coalesce(sum(e.refunds),0),
         coalesce(jsonb_agg(jsonb_build_object('method',e.method,'collected',e.sales,'refunded',e.refunds,
           'net',e.sales-e.refunds,'transactions',e.transactions) order by e.method),'[]'::jsonb)
    into paid,refunded,payment_data
    from (select method,sum(amount) filter(where event_type='sale') sales,
                 sum(amount) filter(where event_type='refund') refunds,count(*) transactions
            from public.business_payment_events e join public.business_cashier_shifts s using(shift_id)
           where s.branch_id=p_branch and e.created_at>=lo and e.created_at<hi group by method) e;
  -- Missing payment events remain pending; a booking/invoice is never counted as cash collected.
  select coalesce(sum(greatest(i.total-private.cashier_invoice_refunded_amount(i.invoice_id)
       -private.cashier_invoice_unpaid_credit(i.invoice_id)
       -coalesce((select sum(e.amount) from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale'),0),0))
       filter(where i.status='active'),0) into pending
    from public.business_invoices i where i.branch_id=p_branch and i.issued_at>=lo and i.issued_at<hi;

  select jsonb_build_object(
    'incurred_total',coalesce((select sum(amount) from public.business_expenses where branch_id=p_branch and expense_date between p_from and p_to),0)
      +coalesce((select sum(amount) from private.owner_expense_records where branch_id=p_branch and expense_date between p_from and p_to and status<>'void'),0),
    'legacy_payment_status_unknown',coalesce((select sum(amount) from public.business_expenses where branch_id=p_branch and expense_date between p_from and p_to),0),
    'managed_paid',coalesce((select sum(amount) from private.owner_expense_records where branch_id=p_branch and expense_date between p_from and p_to and status='paid'),0),
    'managed_unpaid',coalesce((select sum(amount) from private.owner_expense_records where branch_id=p_branch and expense_date between p_from and p_to and status='unpaid'),0),
    'by_category',coalesce((select jsonb_agg(jsonb_build_object('category',category,'amount',amount) order by category)
      from (select category,sum(amount) amount from (
        select category,amount from public.business_expenses where branch_id=p_branch and expense_date between p_from and p_to
        union all select case when category='other' then custom_category else category end,amount
          from private.owner_expense_records where branch_id=p_branch and expense_date between p_from and p_to and status<>'void'
      ) expense_sources group by category) grouped_categories),'[]'::jsonb)
  ) into expense_data;
  select case when exists(select 1 from private.hr_payroll p
      where p.from_date<p_from and p.to_date>=p_from
         or p.from_date<=p_to and p.to_date>p_to)
    then jsonb_build_object('period_complete',false,'snapshot_count',0,'base_earned',null,'commission_earned',null,
      'bonuses',null,'advances',null,'deductions',null,'net_snapshot',null,'paid_amount',null)
    else jsonb_build_object('period_complete',true,'snapshot_count',count(p.id),
      'base_earned',coalesce(sum((p.snapshot->>'base_earned')::numeric),0),
      'commission_earned',coalesce(sum((p.snapshot->>'commission')::numeric),0),
      'bonuses',coalesce(sum((select sum((a.value->>'amount')::numeric) from jsonb_array_elements(coalesce(p.snapshot->'adjustment_lines','[]'::jsonb)) a(value) where a.value->>'kind'='bonus')),0),
      'advances',coalesce(sum((select sum((a.value->>'amount')::numeric) from jsonb_array_elements(coalesce(p.snapshot->'adjustment_lines','[]'::jsonb)) a(value) where a.value->>'kind'='advance')),0),
      'deductions',coalesce(sum((select sum((a.value->>'amount')::numeric) from jsonb_array_elements(coalesce(p.snapshot->'adjustment_lines','[]'::jsonb)) a(value) where a.value->>'kind'='deduction')),0),
      'net_snapshot',coalesce(sum((p.snapshot->>'net')::numeric),0),'paid_amount',null) end
    into payroll_data from private.hr_payroll p
   where p.from_date>=p_from and p.to_date<=p_to
     and exists(select 1 from public.staff_profiles s where s.user_id=p.staff_id and s.is_active
       and (s.role='owner' or exists(select 1 from public.staff_branch_access a
          where a.user_id=s.user_id and a.branch_id=p_branch)));
  select coalesce(jsonb_agg(to_jsonb(q) order by q.full_name),'[]'::jsonb) into commission_data from (
    select s.user_id staff_id,s.full_name,
      coalesce(sum(c.amount),0) commission_earned,
      count(distinct coalesce(w.booking_id,w.order_id)) cars_serviced,
      count(distinct w.order_id) completed_services,
      null::numeric commission_paid,null::numeric commission_remaining,
      'payout_ledger_unavailable' payment_basis
    from private.cashier_service_earnings e
    join private.cashier_service_commissions c using(order_id,staff_id)
    join private.cashier_service_worklines w using(order_id)
    join public.staff_profiles s on s.user_id=c.staff_id
    where w.branch_id=p_branch and e.earned_at>=lo and e.earned_at<hi and s.is_active
    group by s.user_id,s.full_name
  ) q;
  select count(distinct coalesce(span.booking_id,span.walk_in_order_id)) into visit_count
    from private.service_resource_spans span
    join private.service_resource_events event on event.event_id=span.end_event_id and event.action='complete'
   where span.branch_id=p_branch and span.ended_at>=lo and span.ended_at<hi;
  select coalesce(jsonb_object_agg(status,cnt),'{}'::jsonb) into booking_data from (
    select status,count(*) cnt from public.bookings where branch_id=p_branch
     and (booking_date+booking_time)>=p_from::timestamp and (booking_date+booking_time)<p_to+1
    group by status
  ) b;
  select coalesce(jsonb_agg(jsonb_build_object('date',d::date,
    'billed',coalesce(inv.amount,0),'collected',coalesce(pay.amount,0),'cars',coalesce(visits.amount,0)) order by d),'[]'::jsonb)
    into daily_data
    from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d
    left join lateral (
      select sum(i.total-private.cashier_invoice_refunded_amount(i.invoice_id)
        -private.cashier_invoice_unpaid_credit(i.invoice_id)) amount
      from public.business_invoices i where i.branch_id=p_branch and i.status='active'
        and i.issued_at>=d::date::timestamp at time zone zone_name
        and i.issued_at<(d::date+1)::timestamp at time zone zone_name
    ) inv on true
    left join lateral (
      select sum(case when e.event_type='sale' then e.amount else -e.amount end) amount
      from public.business_payment_events e join public.business_cashier_shifts s using(shift_id)
      where s.branch_id=p_branch and e.created_at>=d::date::timestamp at time zone zone_name
        and e.created_at<(d::date+1)::timestamp at time zone zone_name
    ) pay on true
    left join lateral (
      select count(distinct coalesce(span.booking_id,span.walk_in_order_id)) amount
      from private.service_resource_spans span
      join private.service_resource_events event on event.event_id=span.end_event_id and event.action='complete'
      where span.branch_id=p_branch and span.ended_at>=d::date::timestamp at time zone zone_name
        and span.ended_at<(d::date+1)::timestamp at time zone zone_name
    ) visits on true;
  return jsonb_build_object(
    'branch_id',p_branch,'branches',(select coalesce(jsonb_agg(jsonb_build_object('branch_id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en) order by b.is_default desc,b.name_en),'[]'::jsonb) from public.business_branches b where b.is_active and private.can_manage_finance_branch(b.branch_id,false)),
    'time_zone',zone_name,'from',p_from,'to',p_to,'currency','EGP','as_of',statement_timestamp(),
    'sales',jsonb_build_object('active_invoice_count',invoice_count,'invoices_by_status',invoice_status_data,'billed_net_after_refunds',billed,
      'discounts',discounts,'refunds',refunded,'revenue_ex_vat',case when tax_complete then revenue_ex_tax end,
      'tax_complete',coalesce(tax_complete,false),'average_invoice',case when invoice_count>0 then billed/invoice_count end,
      'actual_profit',null,'profit_status','cost_coverage_incomplete'),
    'collections',jsonb_build_object('paid_net',coalesce(paid,0),'pending_invoice_balance',coalesce(pending,0),
      'methods',coalesce(payment_data,'[]'::jsonb),'payment_event_basis','cashier payment event timestamp'),
    'operations',jsonb_build_object('verified_cars_serviced',visit_count,'bookings_by_status',booking_data),
    'commissions',commission_data,
    'payroll',coalesce(payroll_data,'{}'::jsonb)||jsonb_build_object(
      'payment_basis','no payroll payout ledger; approved snapshots are not proof of payment',
      'commission_overlap_warning','Payroll snapshot commission is shown separately from daily earned service commission and must not be added to it.'),
    'expenses',expense_data,
    'daily',daily_data,
    'pnl',jsonb_build_object('revenue_ex_vat',case when tax_complete then revenue_ex_tax end,
      'inventory_cogs',null,'gross_profit',null,'payroll_cost',null,'operating_expenses',null,'net_profit',null,
      'status','cost_and_period_allocation_incomplete',
      'reason','No complete service-cost and inventory-consumption valuation basis is recorded; approved payroll and paid cash are not inferred.'),
    'limitations',jsonb_build_array('inventory_cost_of_goods_not_allocated_to_sold_units','service_material_cost_not_recorded','commission_payout_ledger_unavailable','legacy_expense_payment_status_unknown','monthly_recurring_accrual_not_configured')
  );
end $$;
revoke all on function private.owner_finance_dashboard(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function private.owner_finance_dashboard(uuid,date,date) to authenticated;
create function public.get_owner_finance_dashboard(p_branch uuid,p_from date,p_to date)
returns jsonb language sql stable security invoker set search_path=pg_catalog as
$$ select private.owner_finance_dashboard(p_branch,p_from,p_to) $$;
revoke all on function public.get_owner_finance_dashboard(uuid,date,date) from public,anon;
grant execute on function public.get_owner_finance_dashboard(uuid,date,date) to authenticated;

create function private.owner_expense_context(p_branch uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare selected uuid:=p_branch; actor uuid:=auth.uid(); rows jsonb; branch_rows jsonb;
begin
 if actor is null or p_from is null or p_to<p_from or p_to-p_from>366 then raise exception 'Valid expense window required' using errcode='22023';end if;
 if selected is null then select branch_id into selected from public.business_branches where is_default and is_active;end if;
 if not coalesce(private.can_manage_finance_branch(selected,false),false) then raise exception 'Finance access required' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('expense_id',expense_id,'branch_id',branch_id,'category',category,
   'custom_category',custom_category,'amount',amount,'expense_date',expense_date,'due_date',due_date,'status',status,
   'payment_method',payment_method,'paid_at',paid_at,'external_reference',external_reference,'note',note,
   'attachment_path',attachment_path,'recurrence_rule',recurrence_rule,'recurrence_until',recurrence_until,'revision',revision)
   order by expense_date desc,created_at desc),'[]'::jsonb)
 into rows from private.owner_expense_records where branch_id=selected and expense_date between p_from and p_to;
 select coalesce(jsonb_agg(jsonb_build_object('branch_id',branch_id,'name_ar',name_ar,'name_en',name_en)
   order by is_default desc,name_en),'[]'::jsonb)
 into branch_rows from public.business_branches b where b.is_active and private.can_manage_finance_branch(b.branch_id,false);
 select coalesce(rows,'[]'::jsonb)||coalesce((select jsonb_agg(jsonb_build_object('expense_id',expense_id,'branch_id',branch_id,
   'category',category,'amount',amount,'expense_date',expense_date,'due_date',expense_date,'status','unknown',
   'payment_method',null,'note',note,'revision',0,'legacy',true)
   order by expense_date desc) from public.business_expenses where branch_id=selected and expense_date between p_from and p_to),'[]'::jsonb)
   into rows;
 return jsonb_build_object('branch_id',selected,'expenses',rows,'branches',branch_rows,
   'can_manage_expenses',private.can_manage_finance_branch(selected,true),'storage_bucket','owner-expense-receipts');
end $$;
revoke all on function private.owner_expense_context(uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function private.owner_expense_context(uuid,date,date) to authenticated;
create function public.get_owner_expense_context(p_branch uuid,p_from date,p_to date)
returns jsonb language sql stable security invoker set search_path=pg_catalog as
$$ select private.owner_expense_context(p_branch,p_from,p_to) $$;
revoke all on function public.get_owner_expense_context(uuid,date,date) from public,anon;
grant execute on function public.get_owner_expense_context(uuid,date,date) to authenticated;

create function private.owner_save_expense(p_request uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); branch uuid; expense_id uuid; prior private.owner_expense_records%rowtype;
  before_value jsonb; result jsonb; recurrence text; start_date date; until_date date; occurrence date;
  group_id uuid; occurrence_id uuid; amount_value numeric; status_value text; attachment text;
begin
 if actor is null or p_request is null or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Valid expense request required' using errcode='22023';end if;
 branch:=(p_data->>'branch_id')::uuid;
 if not coalesce(private.can_manage_finance_branch(branch,true),false) then raise exception 'Expense write access required' using errcode='42501';end if;
 if jsonb_typeof(p_data->'amount') is distinct from 'number' then raise exception 'Amount required' using errcode='22023';end if;
 amount_value:=(p_data->>'amount')::numeric;
 if amount_value<=0 or amount_value>=1000000000000 or amount_value<>round(amount_value,2) then raise exception 'Amount must be positive EGP with two decimals' using errcode='22023';end if;
 if length(trim(coalesce(p_data->>'note','')))>1000 or length(trim(coalesce(p_data->>'external_reference','')))>120 then raise exception 'Expense text exceeds allowed length' using errcode='22023';end if;
 if p_data->>'category' not in ('rent','electricity','water','salary','commission','washing_supplies','maintenance','internet_telecom','marketing','other') then raise exception 'Unknown expense category' using errcode='22023';end if;
 if p_data->>'category'='other' and length(trim(coalesce(p_data->>'custom_category','')))<2 then raise exception 'Custom category required' using errcode='22023';end if;
 start_date:=(p_data->>'expense_date')::date; recurrence:=coalesce(p_data->>'recurrence_rule','none'); until_date:=nullif(p_data->>'recurrence_until','')::date;
 if start_date is null or recurrence not in ('none','daily','weekly','monthly','yearly') then raise exception 'Valid date and recurrence required' using errcode='22023';end if;
 if recurrence='none' then until_date:=null;elsif until_date is null or until_date<start_date or until_date>start_date+interval '2 years' then raise exception 'Recurring expense horizon must be within two years' using errcode='22023';end if;
 attachment:=nullif(trim(coalesce(p_data->>'attachment_path','')),'');
 if attachment is not null and (split_part(attachment,'/',1)<>branch::text or not exists(
   select 1 from storage.objects o where o.bucket_id='owner-expense-receipts' and o.name=attachment
     and (o.metadata->>'mimetype') in ('application/pdf','image/jpeg','image/png')
     and (o.metadata->>'size')::bigint between 1 and 5242880)) then raise exception 'Receipt must be an authorized uploaded PDF or image up to 5 MB' using errcode='22023';end if;
 -- idempotent retry of an identical request only
  select q.result into result from private.owner_expense_requests q where q.request_id=p_request;
 if found then
   if (select actor_id from private.owner_expense_requests where request_id=p_request)<>actor
      or (select payload from private.owner_expense_requests where request_id=p_request)<>p_data then raise exception 'Expense request identity mismatch' using errcode='22023';end if;
   return result;
 end if;
 if exists(select 1 from private.branch_daily_closures where branch_id=branch and business_date=start_date) then raise exception 'Approved business day is immutable; record an owner correction instead' using errcode='55000';end if;
 expense_id:=nullif(p_data->>'expense_id','')::uuid;
 if expense_id is not null then
   select * into prior from private.owner_expense_records where owner_expense_records.expense_id=owner_save_expense.expense_id for update;
   if not found or prior.branch_id<>branch or prior.status<>'unpaid' then raise exception 'Only unpaid expenses can be edited' using errcode='55000';end if;
   if prior.revision<>(p_data->>'expected_revision')::integer then raise exception 'Expense changed; refresh before editing' using errcode='40001';end if;
   if exists(select 1 from private.branch_daily_closures where branch_id=branch and business_date=prior.expense_date) then raise exception 'Approved business day is immutable; record an owner correction instead' using errcode='55000';end if;
   before_value:=to_jsonb(prior);
   update private.owner_expense_records set category=p_data->>'category',custom_category=nullif(p_data->>'custom_category',''),amount=amount_value,
      expense_date=start_date,due_date=nullif(p_data->>'due_date','')::date,
      external_reference=nullif(trim(coalesce(p_data->>'external_reference','')),''),note=trim(coalesce(p_data->>'note','')),
      attachment_path=attachment,updated_by=actor,updated_at=clock_timestamp(),revision=revision+1
     where owner_expense_records.expense_id=expense_id returning to_jsonb(owner_expense_records.*) into result;
   insert into private.owner_expense_audit(expense_id,request_id,actor_id,action,before_data,after_data)
     values(expense_id,p_request,actor,'edited',before_value,result);
 else
   recurrence:=coalesce(p_data->>'recurrence_rule','none');group_id:=case when recurrence='none' then null else gen_random_uuid() end;
   status_value:='unpaid';
   occurrence:=start_date; occurrence_id:=gen_random_uuid();
   insert into private.owner_expense_records(expense_id,request_id,branch_id,category,custom_category,amount,expense_date,due_date,status,
     external_reference,note,attachment_path,recurrence_rule,recurrence_until,recurrence_group,created_by,updated_by)
   values(occurrence_id,p_request,branch,p_data->>'category',nullif(p_data->>'custom_category',''),amount_value,start_date,
     nullif(p_data->>'due_date','')::date,status_value,nullif(trim(coalesce(p_data->>'external_reference','')),''),
     trim(coalesce(p_data->>'note','')),attachment,recurrence,until_date,group_id,actor,actor)
   returning to_jsonb(owner_expense_records.*) into result;
   insert into private.owner_expense_audit(expense_id,request_id,actor_id,action,after_data)
     values(occurrence_id,p_request,actor,'created',result);
   if recurrence<>'none' then
     for occurrence in
       select d::date from generate_series(start_date::timestamp,until_date::timestamp,
         case recurrence when 'daily' then interval '1 day' when 'weekly' then interval '1 week' when 'monthly' then interval '1 month' else interval '1 year' end) d
       where d::date>start_date order by d
     loop
       if exists(select 1 from private.branch_daily_closures where branch_id=branch and business_date=occurrence) then continue;end if;
       insert into private.owner_expense_records(request_id,branch_id,category,custom_category,amount,expense_date,due_date,status,
         note,recurrence_rule,recurrence_until,recurrence_group,created_by,updated_by)
       values(gen_random_uuid(),branch,p_data->>'category',nullif(p_data->>'custom_category',''),amount_value,occurrence,
         coalesce(nullif(p_data->>'due_date','')::date,occurrence), 'unpaid',trim(coalesce(p_data->>'note','')),
         recurrence,until_date,group_id,actor,actor) on conflict(recurrence_group,expense_date) where recurrence_group is not null do nothing;
     end loop;
   end if;
 end if;
 insert into private.owner_expense_requests(request_id,actor_id,action,payload,result)
   values(p_request,actor,case when expense_id is null then 'create' else 'edit' end,p_data,result);
 return result;
end $$;
revoke all on function private.owner_save_expense(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function private.owner_save_expense(uuid,jsonb) to authenticated;
create function public.save_owner_expense(p_request uuid,p_data jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog as
$$ select private.owner_save_expense(p_request,p_data) $$;
revoke all on function public.save_owner_expense(uuid,jsonb) from public,anon;
grant execute on function public.save_owner_expense(uuid,jsonb) to authenticated;

create function private.owner_set_expense_status(p_request uuid,p_expense uuid,p_status text,p_method text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid(); item private.owner_expense_records%rowtype; result jsonb; old jsonb;
begin
 if actor is null or p_request is null or p_status not in ('paid','void') then raise exception 'Invalid expense status command' using errcode='22023';end if;
 select * into item from private.owner_expense_records where expense_id=p_expense for update;
 if not found or not coalesce(private.can_manage_finance_branch(item.branch_id,true),false) then raise exception 'Expense management access required' using errcode='42501';end if;
 if exists(select 1 from private.branch_daily_closures where branch_id=item.branch_id and business_date=item.expense_date) then raise exception 'Approved business day is immutable; record an owner correction instead' using errcode='55000';end if;
  select q.result into result from private.owner_expense_requests q where q.request_id=p_request;
 if found then
   if (select actor_id from private.owner_expense_requests where request_id=p_request)<>actor
      or (select action from private.owner_expense_requests where request_id=p_request)<>'status'
      or (select payload from private.owner_expense_requests where request_id=p_request)<>jsonb_build_object('expense_id',p_expense,'status',p_status,'method',p_method)
     then raise exception 'Expense status request identity mismatch' using errcode='22023';end if;
   return result;
 end if;
 if p_status='paid' and p_method not in ('cash','card_terminal','bank_transfer','other') then raise exception 'Select a payment method' using errcode='22023';end if;
 if item.status<>'unpaid' then raise exception 'Only unpaid expenses can change status; paid/void rows require an audited reversal record' using errcode='55000';end if;
 old:=to_jsonb(item);
 update private.owner_expense_records set status=p_status,payment_method=case when p_status='paid' then p_method end,
    paid_at=case when p_status='paid' then clock_timestamp() end,updated_by=actor,updated_at=clock_timestamp(),revision=revision+1
  where expense_id=p_expense returning to_jsonb(owner_expense_records.*) into result;
 insert into private.owner_expense_audit(expense_id,request_id,actor_id,action,before_data,after_data)
   values(p_expense,p_request,actor,case when p_status='paid' then 'paid' else 'voided' end,old,result);
 insert into private.owner_expense_requests(request_id,actor_id,action,payload,result)
   values(p_request,actor,'status',jsonb_build_object('expense_id',p_expense,'status',p_status,'method',p_method),result);
 return result;
end $$;
revoke all on function private.owner_set_expense_status(uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function private.owner_set_expense_status(uuid,uuid,text,text) to authenticated;
create function public.set_owner_expense_status(p_request uuid,p_expense uuid,p_status text,p_method text default null)
returns jsonb language sql security invoker set search_path=pg_catalog as
$$ select private.owner_set_expense_status(p_request,p_expense,p_status,p_method) $$;
revoke all on function public.set_owner_expense_status(uuid,uuid,text,text) from public,anon;
grant execute on function public.set_owner_expense_status(uuid,uuid,text,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('owner-expense-receipts','owner-expense-receipts',false,5242880,array['application/pdf','image/jpeg','image/png'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['application/pdf','image/jpeg','image/png'];
create function private.can_access_owner_expense_receipt(p_name text,p_write boolean default false)
returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare branch uuid; begin
  begin branch:=split_part(p_name,'/',1)::uuid; exception when others then return false; end;
  if split_part(p_name,'/',2)<>'expenses' or split_part(p_name,'/',3)='' or split_part(p_name,'/',4)='' then return false;end if;
  return coalesce(private.can_manage_finance_branch(branch,p_write),false);
end $$;
revoke all on function private.can_access_owner_expense_receipt(text,boolean) from public,anon;
grant execute on function private.can_access_owner_expense_receipt(text,boolean) to authenticated;
create policy owner_expense_receipt_read on storage.objects for select to authenticated
  using(bucket_id='owner-expense-receipts' and private.can_access_owner_expense_receipt(name,false));
create policy owner_expense_receipt_insert on storage.objects for insert to authenticated
  with check(bucket_id='owner-expense-receipts' and private.can_access_owner_expense_receipt(name,true));
create policy owner_expense_receipt_no_overwrite on storage.objects as restrictive for update to authenticated
  using(bucket_id<>'owner-expense-receipts') with check(bucket_id<>'owner-expense-receipts');
create policy owner_expense_receipt_no_delete on storage.objects as restrictive for delete to authenticated
  using(bucket_id<>'owner-expense-receipts');

notify pgrst,'reload schema';
commit;
