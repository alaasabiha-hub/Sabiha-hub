begin;
-- Same outbox/reconciler/cron. Only already-visible due event IDs are coalesced.
-- Reference resolution is deliberately stricter than the individual legacy fallback.
create function private.coalescible_loyalty_order(p_event private.loyalty_visit_outbox)returns uuid
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_oid uuid;v_invoice_oid uuid;v_invoice_branch uuid;v_order public.business_orders;v_orders uuid[];
begin
 if p_event.source_kind not in('business_orders','business_invoices','business_payment_events','bookings','loyalty_earning_snapshot_bindings')then return null;end if;
 v_oid:=p_event.order_id;
 if p_event.invoice_id is not null then
  select order_id,branch_id into v_invoice_oid,v_invoice_branch from public.business_invoices where invoice_id=p_event.invoice_id;
  if v_invoice_oid is null or(v_oid is not null and v_oid<>v_invoice_oid)then return null;end if;
  v_oid:=v_invoice_oid;
 end if;
 if p_event.booking_id is not null then
  select array_agg(order_id)into v_orders from public.business_orders where booking_id=p_event.booking_id and order_type='service';
  if coalesce(cardinality(v_orders),0)<>1 or(v_oid is not null and v_oid<>v_orders[1])then return null;end if;
  v_oid:=v_orders[1];
 end if;
 select * into v_order from public.business_orders where order_id=v_oid and order_type='service';
 if not found then return null;end if;
 if p_event.booking_id is not null and p_event.booking_id is distinct from v_order.booking_id then return null;end if;
 if p_event.invoice_id is not null and v_invoice_branch is distinct from v_order.branch_id then return null;end if;
 if v_order.booking_id is not null and(not exists(select 1 from public.bookings where id=v_order.booking_id and branch_id=v_order.branch_id)or(select count(*)from public.business_orders where booking_id=v_order.booking_id and order_type='service')<>1)then return null;end if;
 if p_event.source_kind='business_payment_events'and not exists(select 1 from public.business_payment_events where payment_id=p_event.source_id and invoice_id=p_event.invoice_id)then
  -- The verified invoice above supplies the payment's canonical order link.
  return null;
 end if;
 if p_event.source_kind='loyalty_earning_snapshot_bindings'and(p_event.source_id is distinct from p_event.booking_id or not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=p_event.booking_id))then return null;end if;
 return v_oid;
end$$;
revoke all on function private.coalescible_loyalty_order(private.loyalty_visit_outbox)from public,anon,authenticated,service_role;

create or replace function private.drain_loyalty_visit_event()returns jsonb language plpgsql security definer
set search_path=pg_catalog set lock_timeout='20s' as $$
declare job private.loyalty_visit_outbox;oid uuid;orders uuid[];result text;v_safe_oid uuid;v_captured uuid[];v_due timestamptz;
begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Visit drain requires READ COMMITTED';end if;
 select * into job from private.loyalty_visit_outbox where processed_at is null and next_attempt_at<=clock_timestamp()order by next_attempt_at,created_at,event_id limit 1 for update skip locked;
 if job.event_id is null then return jsonb_build_object('processed',false);end if;
 v_captured:=array[job.event_id];
 begin
 v_safe_oid:=private.coalescible_loyalty_order(job);v_due:=clock_timestamp();
 if v_safe_oid is not null then
  -- ALL event locks precede canonical/order locks AND the exception subtransaction.
  -- No later UPDATE may discover more rows by order ID. SKIP LOCKED prevents
  -- event->canonical vs canonical->another worker's event lock inversion.
  select array_prepend(job.event_id,coalesce(array_agg(c.event_id),'{}'::uuid[]))into v_captured from(
   select q.event_id from private.loyalty_visit_outbox q
   where q.event_id<>job.event_id and q.processed_at is null and q.next_attempt_at<=v_due
    and(q.order_id=v_safe_oid or(q.order_id is null and(q.invoice_id in(select invoice_id from public.business_invoices where order_id=v_safe_oid)or q.booking_id in(select booking_id from public.business_orders where order_id=v_safe_oid))))
    and private.coalescible_loyalty_order(job)=v_safe_oid and private.coalescible_loyalty_order(q)=v_safe_oid
   order by q.next_attempt_at,q.created_at,q.event_id limit 99 for update of q skip locked
  )c;
 end if;
 exception when others then
  -- Failed capture rolls back any candidate locks; only the outer locked anchor
  -- is ours now. Never update the transient candidate list on this path.
  update private.loyalty_visit_outbox set attempts=attempts+1,last_error_code=sqlstate,next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,120*power(2,least(attempts,5)))::integer)where event_id=job.event_id;
  return jsonb_build_object('processed',false,'retry',true,'error_code',sqlstate);
 end;
 begin
  -- Preserve individual unresolved/ambiguous-event handling and response codes.
  -- Freeze the batch's resolved order; never re-resolve it to a different
  -- order after capture while acknowledging the original order's events.
  oid:=v_safe_oid;
  if oid is null then
  oid:=job.order_id;
  if oid is null and job.invoice_id is not null then select order_id into oid from public.business_invoices where invoice_id=job.invoice_id;end if;
  if oid is null and job.booking_id is not null then
   select array_agg(order_id)into orders from public.business_orders where booking_id=job.booking_id and order_type='service';
   if cardinality(orders)=1 then oid:=orders[1];end if;
  end if;
  end if;
  if oid is null then result:='canonical_order_not_resolved';else result:=private.reconcile_loyalty_visit(oid);end if;
  if result='scheduler_disabled'then
   update private.loyalty_visit_outbox set attempts=attempts+1,result_code=result,next_attempt_at=clock_timestamp()+interval'2 minutes'where event_id=any(v_captured);
   return jsonb_build_object('processed',false,'retry',true,'result',result);
  end if;
  update private.loyalty_visit_outbox set processed_at=clock_timestamp(),result_code=result,attempts=attempts+1,last_error_code=null where event_id=any(v_captured);
  return jsonb_build_object('processed',true,'result',result);
 exception when others then
  -- Outer row locks survive this rollback; retry only our captured IDs. Each
  -- event retains its own attempts/backoff, not the anchor's failure history.
  update private.loyalty_visit_outbox set attempts=attempts+1,last_error_code=sqlstate,next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,120*power(2,least(attempts,5)))::integer)where event_id=any(v_captured);
  return jsonb_build_object('processed',false,'retry',true,'error_code',sqlstate);
 end;
end$$;
revoke all on function private.drain_loyalty_visit_event()from public,anon,authenticated;
grant execute on function private.drain_loyalty_visit_event()to service_role;
-- Public wrapper, cron entry/advisory mutex, runtime gates and schedule untouched.
commit;
