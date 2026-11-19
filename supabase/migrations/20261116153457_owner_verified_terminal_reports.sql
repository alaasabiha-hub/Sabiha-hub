begin;
create function private.verified_terminal_analytics(p_branch uuid,p_from date,p_to date)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare result jsonb;
begin
 if private.active_staff_role()is distinct from'owner'then raise exception 'Active owner required'using errcode='42501';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'Bounded reporting period required'using errcode='22023';end if;
 with events as(
 select e.*from public.business_payment_events e join public.business_invoices i using(invoice_id)join public.business_cashier_shifts sh on sh.shift_id=e.shift_id and sh.branch_id=i.branch_id
 where i.branch_id=p_branch and e.method='card_terminal'and e.created_at>=p_from::timestamp at time zone'Africa/Cairo'and e.created_at<(p_to+1)::timestamp at time zone'Africa/Cairo'
 and((e.event_type='sale'and exists(select 1 from private.card_terminal_confirmations c where c.payment_id=e.payment_id and c.invoice_id=e.invoice_id and c.shift_id=e.shift_id and c.branch_id=i.branch_id and c.amount=e.amount))
 or(e.event_type='refund'and exists(select 1 from private.card_terminal_refund_receipts r where r.payment_id=e.payment_id and r.invoice_id=e.invoice_id and r.shift_id=e.shift_id and r.branch_id=i.branch_id and r.amount=e.amount)))
 ),summary as(select coalesce(sum(amount)filter(where event_type='sale'),0)collections,coalesce(sum(amount)filter(where event_type='refund'),0)refunds,count(*)filter(where event_type='sale')sales,count(*)filter(where event_type='refund')refunds_count from events),series as(
 select period,date_trunc(period,created_at at time zone'Africa/Cairo')::date period_date,
 coalesce(sum(amount)filter(where event_type='sale'),0)terminal_collections,coalesce(sum(amount)filter(where event_type='refund'),0)terminal_refunds,
 coalesce(sum(case when event_type='sale'then amount else -amount end),0)terminal_net,count(*)transactions
 from events cross join(values('day'),('week'),('month'))p(period)group by period,date_trunc(period,created_at at time zone'Africa/Cairo'))
 select jsonb_build_object('summary',jsonb_build_object('terminal_collections',collections,'terminal_refunds',refunds,'terminal_net',collections-refunds,'terminal_count',sales,'terminal_refund_count',refunds_count,'terminal_fees_actual',null,'terminal_settlements_complete',false),
 'terminal_series',coalesce((select jsonb_agg(jsonb_build_object('period',period,'date',period_date,'terminal_collections',terminal_collections,'terminal_refunds',terminal_refunds,'terminal_net',terminal_net,'transactions',transactions)order by period,period_date)from series),'[]'::jsonb),
 'terminal_report_scope','verified_internal_ledger_only','terminal_bank_settlement_verified',false)into result from summary;
 return result;
end$$;
revoke all on function private.verified_terminal_analytics(uuid,date,date)from public,anon,authenticated,service_role;
alter function private.get_ai_payment_analytics(date,date)rename to get_ai_payment_analytics_before_terminal;
revoke all on function private.get_ai_payment_analytics_before_terminal(date,date)from public,anon,authenticated,service_role;
create function private.get_ai_payment_analytics(p_from date,p_to date)returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare original jsonb;terminal jsonb;b uuid;summary jsonb;
begin
 original:=private.get_ai_payment_analytics_before_terminal(p_from,p_to);
 select branch_id into b from public.business_branches where is_default and is_active;
 terminal:=private.verified_terminal_analytics(b,p_from,p_to);
 summary:=(original->'summary')||(terminal->'summary');
 summary:=summary||jsonb_build_object('known_cash_terminal_net',(summary->>'cash_net')::numeric+(summary->>'terminal_net')::numeric);
 return original||jsonb_build_object('summary',summary,'terminal_series',terminal->'terminal_series','terminal_report_scope',terminal->'terminal_report_scope','terminal_bank_settlement_verified',false);
end$$;
create or replace function public.get_ai_payment_analytics(p_from date,p_to date)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_ai_payment_analytics(p_from,p_to)$$;
revoke all on function private.get_ai_payment_analytics(date,date),public.get_ai_payment_analytics(date,date)from public,anon,authenticated,service_role;
grant execute on function private.get_ai_payment_analytics(date,date),public.get_ai_payment_analytics(date,date)to authenticated;
commit;
