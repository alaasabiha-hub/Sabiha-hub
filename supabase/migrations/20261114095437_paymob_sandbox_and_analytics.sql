begin;
create table private.paymob_intents(
 intent_id uuid primary key,invoice_id text not null references public.business_invoices(invoice_id),created_by uuid not null references auth.users(id),
 amount_cents bigint not null check(amount_cents>0),currency text not null default 'EGP' check(currency='EGP'),mode text not null default 'sandbox' check(mode='sandbox'),
 status text not null default 'creating' check(status in ('creating','pending','sandbox_succeeded','failed','uncertain','refund_reported','void_reported')),
 provider_order text unique,provider_intention text unique,checkout_url text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create unique index one_pending_sandbox_invoice on private.paymob_intents(invoice_id) where status in ('creating','pending','uncertain','sandbox_succeeded','refund_reported');
create table private.paymob_callbacks(event_id uuid primary key default gen_random_uuid(),intent_id uuid not null references private.paymob_intents(intent_id),provider_transaction text not null,
 signed_digest text not null check(length(signed_digest)=128),status text not null,created_at timestamptz not null default now(),unique(provider_transaction,signed_digest));
create table private.gateway_reconciliations(reconciliation_id uuid primary key default gen_random_uuid(),intent_id uuid not null references private.paymob_intents(intent_id),source_reference text not null,
 gateway_fee_actual numeric check(gateway_fee_actual>=0),refunded_actual numeric check(refunded_actual>=0),settled_actual numeric check(settled_actual>=0),recorded_at timestamptz not null default now(),unique(intent_id,source_reference));
alter table private.paymob_intents enable row level security;
alter table private.paymob_callbacks enable row level security;
alter table private.gateway_reconciliations enable row level security;
revoke all on private.paymob_intents,private.paymob_callbacks,private.gateway_reconciliations from public,anon,authenticated,service_role;
create function private.reserve_paymob_sandbox(p_request uuid,p_invoice text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare i public.business_invoices%rowtype;t private.paymob_intents%rowtype;o public.business_orders%rowtype;c public.customers%rowtype;begin
 if auth.uid() is null or not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 if p_request is null then raise exception 'Stable request required';end if;
 perform pg_advisory_xact_lock(hashtextextended('paymob-invoice:'||p_invoice,0));
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if i.status<>'active' or i.total<=0 or i.total<>round(i.total,2) or exists(select 1 from public.business_payment_events where invoice_id=p_invoice and event_type='sale') then raise exception 'Invoice is not payable';end if;
 select * into t from private.paymob_intents where intent_id=p_request;
 if found and (t.invoice_id<>p_invoice or t.created_by<>auth.uid()) then raise exception 'Payment request mismatch';end if;
 if t.intent_id is null then select * into t from private.paymob_intents where invoice_id=p_invoice and status in ('creating','pending','uncertain','sandbox_succeeded','refund_reported') order by created_at desc limit 1;end if;
 if t.intent_id is not null then return jsonb_build_object('intent_id',t.intent_id,'amount_cents',t.amount_cents,'currency',t.currency,'claimed',false,'status',t.status,'checkout_url',t.checkout_url);end if;
 insert into private.paymob_intents(intent_id,invoice_id,created_by,amount_cents) values(p_request,p_invoice,auth.uid(),(i.total*100)::bigint) returning * into t;
 select * into o from public.business_orders where order_id=i.order_id;
 select * into c from public.customers where id=o.customer_id;
 return jsonb_build_object('intent_id',t.intent_id,'amount_cents',t.amount_cents,'currency',t.currency,'claimed',true,'status',t.status,'customer',jsonb_build_object('full_name',c.full_name,'email',c.email,'phone',c.phone));
end;$$;
create function private.attach_paymob_sandbox(p_intent uuid,p_order text,p_provider_intent text,p_checkout_url text) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare t private.paymob_intents%rowtype;begin
 if nullif(trim(p_order),'') is null or nullif(trim(p_provider_intent),'') is null or p_checkout_url is null or p_checkout_url !~ '^https://accept\.paymob\.com/unifiedcheckout/\?' then raise exception 'Invalid sandbox attachment';end if;
 select * into strict t from private.paymob_intents where intent_id=p_intent for update;
 if t.status='pending' and t.provider_order=p_order and t.provider_intention=p_provider_intent and t.checkout_url=p_checkout_url then return;end if;
 if t.status<>'creating' then raise exception 'Sandbox attachment already resolved';end if;
 update private.paymob_intents set provider_order=p_order,provider_intention=p_provider_intent,checkout_url=p_checkout_url,status='pending',updated_at=clock_timestamp() where intent_id=p_intent;
end;$$;
create function private.fail_paymob_sandbox(p_intent uuid,p_uncertain boolean) returns void language plpgsql security definer set search_path=pg_catalog as $$begin
 update private.paymob_intents set status=case when p_uncertain then 'uncertain' else 'failed' end,updated_at=clock_timestamp() where intent_id=p_intent and status='creating';end;$$;
create function private.accept_paymob_sandbox_callback(p_order text,p_transaction text,p_amount bigint,p_currency text,p_status text,p_digest text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare t private.paymob_intents%rowtype;begin
 if p_status is null or p_amount is null or p_amount<=0 or p_digest is null or nullif(trim(p_order),'') is null or p_status not in ('pending','sandbox_succeeded','failed','refund_reported','void_reported') or nullif(trim(p_transaction),'') is null or p_digest !~ '^[0-9a-f]{128}$' then raise exception 'Invalid verified callback';end if;
 select * into strict t from private.paymob_intents where provider_order=p_order for update;
 if t.amount_cents<>p_amount or p_currency is distinct from t.currency then raise exception 'Gateway amount or currency mismatch';end if;
 if exists(select 1 from private.paymob_callbacks where provider_transaction=p_transaction and intent_id<>t.intent_id) then raise exception 'Gateway transaction reused for a different invoice';end if;
 insert into private.paymob_callbacks(intent_id,provider_transaction,signed_digest,status) values(t.intent_id,p_transaction,p_digest,p_status) on conflict(provider_transaction,signed_digest) do nothing;
 if t.status not in ('sandbox_succeeded','refund_reported','void_reported') or (t.status='sandbox_succeeded' and p_status in ('refund_reported','void_reported')) then update private.paymob_intents set status=p_status,updated_at=clock_timestamp() where intent_id=t.intent_id;end if;
 return jsonb_build_object('intent_id',t.intent_id,'sandbox_only',true,'status',(select status from private.paymob_intents where intent_id=t.intent_id),'real_collection_recorded',false);
end;$$;
create function private.get_paymob_sandbox_status(p_invoice text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$begin
 if not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 return coalesce((select jsonb_build_object('status',status,'sandbox_only',true,'live_enabled',false) from private.paymob_intents where invoice_id=p_invoice order by created_at desc limit 1),jsonb_build_object('status','not_started','sandbox_only',true,'live_enabled',false));end;$$;
create function public.reserve_paymob_sandbox(p_request uuid,p_invoice text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.reserve_paymob_sandbox(p_request,p_invoice);$$;
create function public.get_paymob_sandbox_status(p_invoice text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_paymob_sandbox_status(p_invoice);$$;
create function public.attach_paymob_sandbox(p_intent uuid,p_order text,p_provider_intent text,p_checkout_url text) returns void language sql security invoker set search_path=pg_catalog as $$select private.attach_paymob_sandbox(p_intent,p_order,p_provider_intent,p_checkout_url);$$;
create function public.fail_paymob_sandbox(p_intent uuid,p_uncertain boolean) returns void language sql security invoker set search_path=pg_catalog as $$select private.fail_paymob_sandbox(p_intent,p_uncertain);$$;
create function public.accept_paymob_sandbox_callback(p_order text,p_transaction text,p_amount bigint,p_currency text,p_status text,p_digest text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.accept_paymob_sandbox_callback(p_order,p_transaction,p_amount,p_currency,p_status,p_digest);$$;
revoke all on function private.reserve_paymob_sandbox(uuid,text),public.reserve_paymob_sandbox(uuid,text),private.get_paymob_sandbox_status(text),public.get_paymob_sandbox_status(text) from public,anon;
grant execute on function private.reserve_paymob_sandbox(uuid,text),public.reserve_paymob_sandbox(uuid,text),private.get_paymob_sandbox_status(text),public.get_paymob_sandbox_status(text) to authenticated;
revoke all on function private.attach_paymob_sandbox(uuid,text,text,text),public.attach_paymob_sandbox(uuid,text,text,text),private.fail_paymob_sandbox(uuid,boolean),public.fail_paymob_sandbox(uuid,boolean),private.accept_paymob_sandbox_callback(text,text,bigint,text,text,text),public.accept_paymob_sandbox_callback(text,text,bigint,text,text,text) from public,anon,authenticated;
grant execute on function private.attach_paymob_sandbox(uuid,text,text,text),public.attach_paymob_sandbox(uuid,text,text,text),private.fail_paymob_sandbox(uuid,boolean),public.fail_paymob_sandbox(uuid,boolean),private.accept_paymob_sandbox_callback(text,text,bigint,text,text,text),public.accept_paymob_sandbox_callback(text,text,bigint,text,text,text) to service_role;

create function private.get_ai_payment_analytics(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
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
create function public.get_ai_payment_analytics(p_from date,p_to date) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_ai_payment_analytics(p_from,p_to);$$;
revoke all on function private.get_ai_payment_analytics(date,date),public.get_ai_payment_analytics(date,date) from public,anon;
grant execute on function private.get_ai_payment_analytics(date,date),public.get_ai_payment_analytics(date,date) to authenticated;
notify pgrst,'reload schema';
commit;
