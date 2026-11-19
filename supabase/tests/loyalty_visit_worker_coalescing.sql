-- Queue-unit fixture ONLY. Reconciler spy exists inside this transaction and is
-- rolled back with every fixture row. This does not prove new visit eligibility.
begin;
select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));
do $$begin
 assert not exists(select 1 from private.loyalty_visit_outbox where processed_at is null),'Exclusive empty pending queue required; do not alter old events';
 assert exists(select 1 from public.business_orders where order_type='service'and booking_id is null),'Existing service order required for read-only reference fixture';
end$$;
create temp table qa_coalesce_mode(mode text not null,oid uuid not null);
insert into qa_coalesce_mode select 'normal',order_id from public.business_orders where order_type='service'and booking_id is null order by order_id limit 1;
create temp table qa_coalesce_calls(oid uuid);
create temp table qa_coalesce_ids(label text primary key,event_id uuid not null);
-- Existing production reconciler is restored by ROLLBACK, never altered outside TX.
create or replace function private.reconcile_loyalty_visit(p_order uuid)returns text language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare v_mode text;
begin
 insert into pg_temp.qa_coalesce_calls values(p_order);
 select mode into v_mode from pg_temp.qa_coalesce_mode;
 if v_mode='poison'then raise exception 'QA rollback probe'using errcode='PZ123';end if;
 if v_mode='disabled'then return 'scheduler_disabled';end if;
 if v_mode='late'then
  insert into private.loyalty_visit_outbox(source_kind,source_id,order_id)values('business_orders',gen_random_uuid(),p_order) returning event_id into p_order;
  insert into pg_temp.qa_coalesce_ids values('late',p_order);update pg_temp.qa_coalesce_mode set mode='normal';
 end if;
 return 'qa_reconciled';
end$$;
-- A single reconciler call covers captured same-order events; future rows untouched.
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();f uuid:=gen_random_uuid();v_oid uuid;r jsonb;
begin
 select oid into v_oid from pg_temp.qa_coalesce_mode;
 insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id,attempts,next_attempt_at)values(a,'business_orders',a,v_oid,0,clock_timestamp()),(b,'business_orders',b,v_oid,2,clock_timestamp()),(f,'business_orders',f,v_oid,0,clock_timestamp()+interval'1 hour');
 insert into pg_temp.qa_coalesce_ids values('future',f);
 r:=private.drain_loyalty_visit_event();assert r='{"processed":true,"result":"qa_reconciled"}'::jsonb;
 assert(select count(*)=1 from pg_temp.qa_coalesce_calls),'More than one reconcile invocation';
 assert(select count(*)=2 and bool_and(processed_at is not null)from private.loyalty_visit_outbox where event_id in(a,b));
 assert(select attempts=3 from private.loyalty_visit_outbox where event_id=b),'Per-row attempt history was replaced by anchor history';
 assert(select processed_at is null and attempts=0 from private.loyalty_visit_outbox where event_id=f);
 assert private.drain_loyalty_visit_event()='{"processed":false}'::jsonb;
end$$;
-- Event becoming visible after capture (here inserted by spy) must survive batch.
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();v_oid uuid;late_id uuid;n bigint;
begin
 select oid into v_oid from pg_temp.qa_coalesce_mode;select count(*)into n from pg_temp.qa_coalesce_calls;update pg_temp.qa_coalesce_mode set mode='late';
 insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id)values(a,'business_orders',a,v_oid),(b,'business_orders',b,v_oid);
 perform private.drain_loyalty_visit_event();select event_id into late_id from pg_temp.qa_coalesce_ids where label='late';
 assert(select processed_at is null and attempts=0 from private.loyalty_visit_outbox where event_id=late_id),'After-capture wake-up lost';
 assert(select count(*)=n+1 from pg_temp.qa_coalesce_calls);
 perform private.drain_loyalty_visit_event();assert(select processed_at is not null from private.loyalty_visit_outbox where event_id=late_id);
end$$;
-- Same scheduler-disabled shape and two-minute retry, every captured row retained.
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();v_oid uuid;r jsonb;
begin
 select oid into v_oid from pg_temp.qa_coalesce_mode;update pg_temp.qa_coalesce_mode set mode='disabled';
 insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id,attempts)values(a,'business_orders',a,v_oid,1),(b,'business_orders',b,v_oid,4);
 r:=private.drain_loyalty_visit_event();assert r='{"processed":false,"retry":true,"result":"scheduler_disabled"}'::jsonb;
 assert(select count(*)=2 and bool_and(processed_at is null and next_attempt_at>clock_timestamp()+interval'100 seconds'and result_code='scheduler_disabled')from private.loyalty_visit_outbox where event_id in(a,b));
 assert(select attempts=2 from private.loyalty_visit_outbox where event_id=a);assert(select attempts=5 from private.loyalty_visit_outbox where event_id=b);
end$$;
-- Reconcile partial writes roll back; outer captured locks remain held for retry.
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();v_oid uuid;r jsonb;n bigint;
begin
 select oid into v_oid from pg_temp.qa_coalesce_mode;update pg_temp.qa_coalesce_mode set mode='poison';select count(*)into n from pg_temp.qa_coalesce_calls;
 insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id,attempts)values(a,'business_orders',a,v_oid,0),(b,'business_orders',b,v_oid,2);
 r:=private.drain_loyalty_visit_event();assert r='{"processed":false,"retry":true,"error_code":"PZ123"}'::jsonb;
 assert(select count(*)=n from pg_temp.qa_coalesce_calls),'Failed reconciler side effect escaped subtransaction';
 assert(select count(*)=2 and bool_and(processed_at is null and last_error_code='PZ123')from private.loyalty_visit_outbox where event_id in(a,b));
 assert(select attempts=1 and next_attempt_at>clock_timestamp()+interval'100 seconds'from private.loyalty_visit_outbox where event_id=a);
 assert(select attempts=3 and next_attempt_at>clock_timestamp()+interval'450 seconds'from private.loyalty_visit_outbox where event_id=b);
end$$;
-- Unresolved booking reference and inconsistent invoice references stay individual.
do $$declare a uuid;b uuid;v_oid uuid;v_booking uuid:=gen_random_uuid();k text;
begin
 select oid into v_oid from pg_temp.qa_coalesce_mode;update pg_temp.qa_coalesce_mode set mode='normal';
 foreach k in array array['ambiguous_or_missing_booking','bad_invoice']loop
  a:=gen_random_uuid();b:=gen_random_uuid();
  if k='bad_invoice'then
   insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,order_id,invoice_id)values(a,'business_orders',a,v_oid,'QA-MISSING-INVOICE'),(b,'business_orders',b,v_oid,'QA-MISSING-INVOICE');
  else
   insert into private.loyalty_visit_outbox(event_id,source_kind,source_id,booking_id)values(a,'bookings',a,v_booking),(b,'bookings',b,v_booking);
  end if;
  assert(select private.coalescible_loyalty_order(q)is null from private.loyalty_visit_outbox q where event_id=a);
  perform private.drain_loyalty_visit_event();assert(select count(*)=1 from private.loyalty_visit_outbox where event_id in(a,b)and processed_at is not null),'Unsafe references were coalesced';
  perform private.drain_loyalty_visit_event();assert(select count(*)=2 from private.loyalty_visit_outbox where event_id in(a,b)and processed_at is not null);
 end loop;
end$$;
do $$begin
 assert exists(select 1 from pg_proc where oid='private.drain_loyalty_visit_event()'::regprocedure and proconfig @> array['lock_timeout=20s']);
 assert not has_function_privilege('authenticated','private.coalescible_loyalty_order(private.loyalty_visit_outbox)','execute');
 assert not has_function_privilege('authenticated','public.drain_loyalty_visit_event()','execute');
 assert not has_function_privilege('service_role','private.run_loyalty_visit_cron()','execute');
 raise notice 'PASS coalescing unit fixture: single reconcile, captured IDs, late wake, disabled retry, poison rollback, unresolved individual, unchanged grants';
end$$;
rollback;
