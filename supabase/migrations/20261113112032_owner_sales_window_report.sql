-- Read-only owner reporting. Local preparation only; no historical amounts are rewritten.
-- Reuse invoices_branch_idx (branch_id, issued_at desc).
create index payments_created_idx on public.business_payment_events(created_at);
create function private.owner_sales_window(p_from_local timestamp,p_to_local timestamp,p_branch uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_start timestamptz;v_end timestamptz;v_result jsonb;v_hourly jsonb;v_cash jsonb;v_boundary timestamp;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then
  raise exception 'Active owner access required' using errcode='42501';end if;
 if p_from_local is null or p_to_local is null or not isfinite(p_from_local) or not isfinite(p_to_local)
 or p_to_local<=p_from_local or p_to_local-p_from_local>interval '366 days' then raise exception 'Choose a valid window of at most 366 days';end if;
 if p_branch is not null and not exists(select 1 from public.business_branches where branch_id=p_branch) then raise exception 'Unknown branch';end if;
 -- Cairo wall-clock inputs must have exactly one UTC interpretation, including DST changes.
 foreach v_boundary in array array[p_from_local,p_to_local] loop
  if (v_boundary at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'<>v_boundary
   or ((v_boundary at time zone 'Africa/Cairo')+interval '1 hour') at time zone 'Africa/Cairo'=v_boundary
   or ((v_boundary at time zone 'Africa/Cairo')-interval '1 hour') at time zone 'Africa/Cairo'=v_boundary then
   raise exception 'Ambiguous or nonexistent Cairo time; choose another boundary';end if;
 end loop;
 v_start:=p_from_local at time zone 'Africa/Cairo';v_end:=p_to_local at time zone 'Africa/Cairo';
 with cohort as (select i.*,case when jsonb_typeof(document_snapshot->'tax_amount')='number' then (document_snapshot->>'tax_amount')::numeric end tax,
 case when jsonb_typeof(document_snapshot->'delivery_fee')='number' then (document_snapshot->>'delivery_fee')::numeric end fee,
 coalesce((select sum(p.amount) from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale'),0) collected
 from public.business_invoices i where issued_at>=v_start and issued_at<v_end and (p_branch is null or branch_id=p_branch)),
 active as (select * from cohort where status='active')
 select jsonb_build_object('invoice_count',count(*),'net_billed',coalesce(sum(total),0),'billed_before_discount',coalesce(sum(total+discount),0),
 'discounts',coalesce(sum(discount),0),'average_invoice',coalesce(avg(total),0),'commissions',coalesce(sum(commission_total),0),
 'uncollected_recorded',coalesce(sum(greatest(total-collected,0)),0),'invoices_without_payment',count(*) filter(where collected=0),
 'tax_missing_count',count(*) filter(where tax is null),'fees_missing_count',count(*) filter(where fee is null),
 'taxes',case when count(*) filter(where tax is null)=0 then coalesce(sum(tax),0) end,
 'fees',case when count(*) filter(where fee is null)=0 then coalesce(sum(fee),0) end,
 'gross_sales_ex_tax',case when count(*) filter(where tax is null or fee is null)=0 then coalesce(sum(total+discount-tax-fee),0) end,
 'net_sales_ex_tax',case when count(*) filter(where tax is null or fee is null)=0 then coalesce(sum(total-tax-fee),0) end,
 'actual_profit',null,'profit_status','incomplete_cost_and_payroll_snapshots',
 'refunded_invoice_value',(select coalesce(sum(total),0) from cohort where status='refunded'),
 'void_invoice_count',(select count(*) from cohort where status='void')) into v_result from active;
 select jsonb_agg(to_jsonb(h) order by h.hour) into v_hourly from (
 select hour,coalesce(sum(i.total) filter(where i.status='active'),0) net_billed,
 coalesce(sum(i.total) filter(where i.status='refunded'),0) refunded_invoice_value
 from generate_series(0,23) hour left join public.business_invoices i on extract(hour from i.issued_at at time zone 'Africa/Cairo')=hour
 and i.issued_at>=v_start and i.issued_at<v_end and (p_branch is null or i.branch_id=p_branch) group by hour) h;
 select jsonb_build_object('transaction_count',count(*),'collections',coalesce(sum(p.amount) filter(where p.event_type='sale'),0),
 'refunds',coalesce(sum(p.amount) filter(where p.event_type='refund'),0)) into v_cash
 from public.business_payment_events p join public.business_cashier_shifts s using(shift_id)
 where p.created_at>=v_start and p.created_at<v_end and (p_branch is null or s.branch_id=p_branch);
 return v_result||jsonb_build_object('from_utc',v_start,'to_utc',v_end,'from_local',p_from_local,'to_local',p_to_local,
 'time_zone','Africa/Cairo','currency','EGP','branch_id',p_branch,'as_of',statement_timestamp(),
 'cohort_basis','issued_at_current_invoice_status','hourly',v_hourly,'cash_activity',v_cash);
end;$$;
revoke all on function private.owner_sales_window(timestamp,timestamp,uuid) from public,anon;
grant execute on function private.owner_sales_window(timestamp,timestamp,uuid) to authenticated;
create function public.get_owner_sales_window(p_from_local timestamp,p_to_local timestamp,p_branch uuid default null)
returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select private.owner_sales_window(p_from_local,p_to_local,p_branch);$$;
revoke all on function public.get_owner_sales_window(timestamp,timestamp,uuid) from public,anon;
grant execute on function public.get_owner_sales_window(timestamp,timestamp,uuid) to authenticated;
