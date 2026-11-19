-- NEW targeted helpers only. Load on root's isolated QA clone, inside BEGIN /
-- ROLLBACK. Never install into primary/public schema; never backdate any row.
-- Each mutating assertion ALSO rolls back its own successful subtransaction.
create function pg_temp.typed_hr_clone_guard()returns void language plpgsql as $$begin
 assert left(current_database(),length('qa_typed_reward_'))='qa_typed_reward_','Explicit typed-reward QA clone required';
 assert current_user='postgres','Root clone test executor only';
 assert current_setting('transaction_isolation')='read committed','READ COMMITTED required';
 perform private.require_offline_channel_owner(); -- current real owner/session
end$$;

-- Execute ONLY the actual CURRENT hr_execute commission SELECT, not a rewritten
-- payroll function or copied competing calculator. Current-day observation is
-- readonly and explicitly not a payroll approval / closed-period snapshot.
create function pg_temp.typed_hr_actual_commission_projection(p_worker uuid,p_day date)returns jsonb
language plpgsql set search_path=pg_catalog set timezone='UTC'as $$
declare definition text;query text;start_at integer;end_at integer;employment private.hr_employment;lines jsonb;total numeric;begin
 perform pg_temp.typed_hr_clone_guard();
 select *into strict employment from private.hr_employment where staff_id=p_worker;
 definition:=pg_get_functiondef('private.hr_execute(text,jsonb)'::regprocedure);
 start_at:=position('select coalesce(jsonb_agg(jsonb_build_object(''invoice_id'',i.invoice_id'in definition);
 assert start_at>0,'Actual HR commission SELECT not found; review source, never guess';
 end_at:=position(';'in substring(definition from start_at));assert end_at>0;
 query:=substring(definition from start_at for end_at-1);
 assert query like'%walk_in_frozen_workers%'and query like'%wc.rate_percent%'and query like'%wc.amount%','Current typed frozen-commission branch required';
 assert position(' into lines,comm'in query)>0,'Actual HR SELECT result target changed';
 query:=replace(query,' into lines,comm','');
 query:=replace(query,'e.commission_percent','$1');
 query:=regexp_replace(query,'\ms\M','$2','g');
 query:=regexp_replace(query,'\mf\M','$3','g');
 query:=regexp_replace(query,'\mt\M','$4','g');
 assert position(';'in query)=0 and lower(left(query,6))='select','Readonly actual source fragment required';
 execute query into lines,total using employment.commission_percent,p_worker,p_day,p_day;
 return jsonb_build_object('lines',lines,'commission',total,'source_sha256',encode(extensions.digest(definition,'sha256'),'hex'),'observation_only',true);
end$$;

create function pg_temp.assert_typed_reward_payroll_rate_change(
 p_invoice text,p_workers uuid[],p_new_rates numeric[],p_scheduled_minutes numeric,p_require_closed_day boolean default false)
returns jsonb language plpgsql set search_path=pg_catalog set timezone='UTC'as $$
declare invoice public.business_invoices;employment private.hr_employment;frozen private.offline_walk_in_commissions;
 day_value date;today_value date:=(clock_timestamp()at time zone'UTC')::date;worker uuid;new_rate numeric;idx integer;
 before_invoice jsonb;before_order jsonb;before_frozen jsonb;before_employment jsonb;projection_before jsonb;projection_after jsonb;line_before jsonb;line_after jsonb;
 v_request uuid;payroll_request uuid;payroll_row jsonb;payroll_line jsonb;denied boolean;message text;state_code text;payload jsonb;
 proof jsonb;workers_proof jsonb:='[]'::jsonb;created_requests uuid[]:='{}'::uuid[];payroll_count bigint;request_count bigint;begin
 perform pg_temp.typed_hr_clone_guard();
 assert p_require_closed_day is not null;
 assert p_workers is not null and cardinality(p_workers)=2 and array_ndims(p_workers)=1 and array_lower(p_workers,1)=1 and array_position(p_workers,null)is null and(select count(distinct x)from unnest(p_workers)x)=2,'Exactly the two actual QA assigned workers required';
 assert p_new_rates is not null and cardinality(p_new_rates)=cardinality(p_workers)and array_ndims(p_new_rates)=1 and array_lower(p_new_rates,1)=1 and array_position(p_new_rates,null)is null;
 assert p_scheduled_minutes is not null and p_scheduled_minutes>0 and p_scheduled_minutes::text not in('NaN','Infinity','-Infinity'),'Explicit finite owner test period minutes required';
 select *into strict invoice from public.business_invoices where invoice_id=p_invoice;
 day_value:=(invoice.issued_at at time zone'UTC')::date;
 assert invoice.total=0 and invoice.discount>0 and invoice.status='active'and invoice.sale_type='service'and invoice.commission_model='walk_in_frozen_workers';
 assert private.reward_invoice_coverage(p_invoice)->>'state'='covered_by_reward';
 assert exists(select 1 from public.business_orders o where o.order_id=invoice.order_id and o.order_type='service'and o.status in('completed','delivered')and o.assigned_staff_ids@>p_workers and cardinality(o.assigned_staff_ids)=2);
 assert(select count(*)from private.offline_walk_in_commissions where invoice_id=p_invoice)=2;
 if p_require_closed_day then assert day_value<today_value,'A genuinely naturally prior-UTC-day typed receipt is required; do not backdate';
 else assert day_value=today_value,'This new boundary helper requires actual current-UTC-day typed receipt';end if;
 assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice),'Covered receipt must not fabricate a cash/payment event';
 before_invoice:=to_jsonb(invoice);
 select to_jsonb(o)into before_order from public.business_orders o where o.order_id=invoice.order_id;
 select jsonb_agg(to_jsonb(wc)order by wc.staff_id)into before_frozen from private.offline_walk_in_commissions wc where wc.invoice_id=p_invoice;
 select jsonb_agg(to_jsonb(e)order by e.staff_id)into before_employment from private.hr_employment e where e.staff_id=any(p_workers);
 assert jsonb_array_length(before_employment)=2,'Root must legitimately configure both QA employments first';
 select count(*)into payroll_count from private.hr_payroll;select count(*)into request_count from private.hr_requests;
 begin
 for idx in 1..cardinality(p_workers)loop
 worker:=p_workers[idx];new_rate:=p_new_rates[idx];
 select *into strict employment from private.hr_employment where staff_id=worker;
 select *into strict frozen from private.offline_walk_in_commissions where invoice_id=p_invoice and staff_id=worker;
 assert new_rate between 0 and 100 and new_rate::text not in('NaN','Infinity','-Infinity')and round(new_rate,4)=new_rate;
 assert new_rate<>employment.commission_percent and new_rate<>frozen.rate_percent,'Actual distinct configured rate change required';
 assert frozen.gross=invoice.total+invoice.discount and frozen.assigned_count=2 and frozen.amount=round(frozen.gross*frozen.rate_percent/100/2,2);
 assert round(frozen.gross*new_rate/100/2,2)<>frozen.amount,'Choose explicit test rate with a distinguishable amount; no test default rate';
 assert employment.currency='EGP'and employment.starts_on<=day_value and coalesce(employment.ends_on,day_value)>=day_value;
 projection_before:=pg_temp.typed_hr_actual_commission_projection(worker,day_value);
 select x into strict line_before from jsonb_array_elements(projection_before->'lines')x where x->>'invoice_id'=p_invoice;
 v_request:=gen_random_uuid();created_requests:=array_append(created_requests,v_request);
 payload:=jsonb_build_object('staff_id',worker,'request_id',v_request,'salary',employment.salary,'commission_percent',new_rate,'currency',employment.currency,'starts_on',employment.starts_on,'ends_on',employment.ends_on);
 execute 'set local role authenticated';payroll_row:=public.hr_action('employment',payload);execute 'reset role';
 -- Employment action returns its direct row, not {result:...}.
 assert(payroll_row->>'staff_id')::uuid=worker and(payroll_row->>'commission_percent')::numeric=new_rate;
 assert(payroll_row->>'salary')::numeric=employment.salary and payroll_row->>'currency'=employment.currency
 and(payroll_row->>'starts_on')::date=employment.starts_on and(payroll_row->>'ends_on')::date is not distinct from employment.ends_on;
 projection_after:=pg_temp.typed_hr_actual_commission_projection(worker,day_value);
 select x into strict line_after from jsonb_array_elements(projection_after->'lines')x where x->>'invoice_id'=p_invoice;
 assert line_after=line_before,'Actual current HR SELECT must retain this frozen typed commission after rate change';
 assert(line_after->>'before_discount')::numeric=invoice.discount and(line_after->>'rate_percent')::numeric=frozen.rate_percent and(line_after->>'commission')::numeric=frozen.amount and(line_after->>'assigned_count')::integer=2;
 if p_require_closed_day then
 assert not exists(select 1 from private.hr_payroll where staff_id=worker and from_date<=day_value and to_date>=day_value),'Never replace an existing approved period';
 payroll_request:=gen_random_uuid();created_requests:=array_append(created_requests,payroll_request);
 payload:=jsonb_build_object('staff_id',worker,'request_id',payroll_request,'from_date',day_value,'to_date',day_value,'scheduled_minutes',p_scheduled_minutes);
 execute 'set local role authenticated';payroll_row:=public.hr_action('approve_payroll',payload);execute 'reset role';
 -- Canonical hr_api delegates hr_execute: the ACTUAL response is payroll ROW.
 assert(payroll_row->>'staff_id')::uuid=worker and(payroll_row->>'request_id')::uuid=payroll_request and payroll_row?'snapshot';
 assert payroll_row#>>'{snapshot,payment_status}'='not_transferred'and payroll_row#>>'{snapshot,currency}'='EGP';
 assert(payroll_row#>>'{snapshot,employment,commission_percent}')::numeric=new_rate;
 select x into strict payroll_line from jsonb_array_elements(payroll_row#>'{snapshot,commission_lines}')x where x->>'invoice_id'=p_invoice;
 assert payroll_line=line_after;
 execute 'set local role authenticated';assert public.hr_action('approve_payroll',payload)=payroll_row;execute 'reset role';
 -- Same closed dates with a NEW nonce must be rejected, never duplicate payroll.
 denied:=false;begin
 execute 'set local role authenticated';perform public.hr_action('approve_payroll',payload||jsonb_build_object('request_id',gen_random_uuid()));
 exception when others then get stacked diagnostics message=MESSAGE_TEXT,state_code=RETURNED_SQLSTATE;denied:=state_code='P0001'and message='Payroll periods cannot overlap';end;
 execute 'reset role';assert denied,'Actual approved closed period rejects overlapping new request';
 -- Changing current rate again must not rewrite the approved payroll snapshot.
 v_request:=gen_random_uuid();created_requests:=array_append(created_requests,v_request);
 execute 'set local role authenticated';perform public.hr_action('employment',jsonb_build_object('staff_id',worker,'request_id',v_request,'salary',employment.salary,'commission_percent',employment.commission_percent,'currency',employment.currency,'starts_on',employment.starts_on,'ends_on',employment.ends_on));execute 'reset role';
 assert(select to_jsonb(p)from private.hr_payroll p where p.request_id=payroll_request)=payroll_row;
 else
 -- Real current day / a period ending today cannot be approved. Specific error
 -- required, so missing employment/permissions cannot masquerade as this pass.
 foreach payload in array array[
 jsonb_build_object('staff_id',worker,'request_id',gen_random_uuid(),'from_date',day_value,'to_date',day_value,'scheduled_minutes',p_scheduled_minutes),
 jsonb_build_object('staff_id',worker,'request_id',gen_random_uuid(),'from_date',day_value-1,'to_date',day_value,'scheduled_minutes',p_scheduled_minutes)]loop
 v_request:=(payload->>'request_id')::uuid;created_requests:=array_append(created_requests,v_request);
 denied:=false;begin execute 'set local role authenticated';perform public.hr_action('approve_payroll',payload);
 exception when others then get stacked diagnostics message=MESSAGE_TEXT,state_code=RETURNED_SQLSTATE;denied:=state_code='P0001'and message='Closed dates and explicit scheduled minutes required';end;execute 'reset role';
 assert denied,'Current UTC day must fail actual canonical closed-period guard';
 assert not exists(select 1 from private.hr_requests r where r.request_id=v_request),'Rejected approval must not record successful request';
 end loop;
 end if;
 workers_proof:=workers_proof||jsonb_build_array(jsonb_build_object('staff_id',worker,'frozen_rate',frozen.rate_percent,'new_configured_rate',new_rate,'frozen_commission',frozen.amount,'actual_hr_source_sha256',projection_after->>'source_sha256','actual_line_unchanged',true));
 end loop;
 assert before_invoice=(select to_jsonb(i)from public.business_invoices i where i.invoice_id=p_invoice);
 assert before_order=(select to_jsonb(o)from public.business_orders o where o.order_id=invoice.order_id);
 assert before_frozen=(select jsonb_agg(to_jsonb(wc)order by wc.staff_id)from private.offline_walk_in_commissions wc where wc.invoice_id=p_invoice);
 assert not exists(select 1 from public.business_payment_events where invoice_id=p_invoice);
 proof:=jsonb_build_object('invoice_id',p_invoice,'invoice_utc_day',day_value,'workers',workers_proof,'current_day_approval_denied',not p_require_closed_day,
 'natural_closed_day_approval_executed',p_require_closed_day,'closed_day_limitation',case when not p_require_closed_day then'naturally_prior_UTC_day_receipt_required_no_backdate'end,'payroll_transferred',false,'invoice_and_frozen_commissions_unchanged',true);
 raise exception 'Rollback successful clone-only targeted HR assertions'using errcode='P9H01';
 exception when sqlstate'P9H01'then null;end;
 -- Self-rollback is verified even if caller accidentally omitted outer rollback.
 assert before_employment=(select jsonb_agg(to_jsonb(e)order by e.staff_id)from private.hr_employment e where e.staff_id=any(p_workers));
 assert(select count(*)from private.hr_payroll)=payroll_count and(select count(*)from private.hr_requests)=request_count;
 assert not exists(select 1 from private.hr_requests r where r.request_id=any(created_requests));
 assert not exists(select 1 from private.hr_payroll p where p.request_id=any(created_requests));
 return proof||jsonb_build_object('self_rollback_verified',true);
end$$;
