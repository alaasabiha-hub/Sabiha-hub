begin;
-- Final amounts are created before issuance. Existing invoice rows are never rewritten.
alter table public.business_invoices add column reward_snapshot jsonb;
create table private.service_booking_attempts(
 request_id uuid not null,customer_id uuid not null references public.customers(id),mode text not null check(mode in('normal','reward','tombstone')),payload jsonb,
 state text not null check(state in('open','succeeded','closed')),result jsonb,acknowledged_at timestamptz,created_at timestamptz not null default clock_timestamp(),resolved_at timestamptz,
 primary key(customer_id,request_id),check((mode='tombstone' and state='closed' and payload is null)or(mode in('normal','reward')and payload is not null)));
alter table private.service_booking_attempts enable row level security;
revoke all on private.service_booking_attempts from public,anon,authenticated,service_role;
create index service_booking_attempt_customer on private.service_booking_attempts(customer_id,created_at desc);
create function private.reward_invoice_coverage(p_invoice text) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;i public.business_invoices;n bigint;
begin
 select * into d from private.service_reward_redemptions where invoice_id=p_invoice;if d.redemption_id is null then return null;end if;
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;select * into i from public.business_invoices where invoice_id=p_invoice;
 if i.invoice_id is null or i.order_id is distinct from d.order_id or i.branch_id is distinct from d.branch_id or i.total<>0 or i.discount is distinct from q.gross_amount or i.reward_snapshot is distinct from d.coverage_snapshot then return null;end if;
 if q.quote_id is null or d.customer_id<>q.customer_id or d.branch_id<>q.branch_id or d.rules_version_id<>q.rules_version_id or d.policy_version_id<>q.policy_version_id or d.source_channel<>q.source_channel or not coalesce((d.consent->>'accept_terms')::boolean,false) then return null;end if;
 select count(distinct c.earning_id) into n from private.reward_credit_claims c where c.redemption_id=d.redemption_id and c.quote_id=q.quote_id and c.kind='reward' and c.customer_id=d.customer_id and c.earning_id=any(q.earning_ids) and(d.state='restored' or c.released_at is null);
 if n<>q.threshold_visits or not exists(select 1 from public.business_orders where order_id=d.order_id and customer_id=d.customer_id and branch_id=d.branch_id and(booking_id is not distinct from d.booking_id)) or exists(select 1 from public.business_payment_events where invoice_id=p_invoice) or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id and redemption_id=d.redemption_id) then return null;end if;
 if d.state='covered' and i.status<>'active' then return null;end if;
 if d.state in('restored','forfeited') and(i.status<>'void' or not exists(select 1 from public.business_orders where order_id=d.order_id and status='cancelled') or(d.source_channel='booking' and not exists(select 1 from public.bookings where id=d.booking_id and status='cancelled')))then return null;end if;
 return jsonb_build_object('state',case when d.state='covered' and i.status='active' then 'covered_by_reward' else 'cancelled_reward' end,'quote_id',q.quote_id,'rules_version_id',q.rules_version_id,'policy_version_id',q.policy_version_id,'threshold_visits',q.threshold_visits,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','rules',q.terms_snapshot->'rules','redemption_status',d.state,'source_channel',d.source_channel);
end $$;
revoke all on function private.reward_invoice_coverage(text) from public,anon,authenticated,service_role;
create function private.guard_reward_invoice() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;q private.service_reward_quotes;n bigint;
begin
 if tg_op='UPDATE' then
 if new.reward_snapshot is distinct from old.reward_snapshot then raise exception 'Issued reward snapshot cannot be added or changed';end if;
 if old.reward_snapshot is not null and(new.total is distinct from old.total or new.discount is distinct from old.discount or new.order_id is distinct from old.order_id or new.branch_id is distinct from old.branch_id) then raise exception 'Issued reward financial amounts/identity are immutable';end if;return new;end if;
 if new.reward_snapshot is null then return new;end if;
 select * into d from private.service_reward_redemptions where invoice_id=new.invoice_id and creator_xid=txid_current() and state='covered';
 select * into q from private.service_reward_quotes where quote_id=d.quote_id;
 select count(*) into n from private.reward_credit_claims where redemption_id=d.redemption_id and kind='reward' and released_at is null and customer_id=d.customer_id and earning_id=any(q.earning_ids);
 if d.redemption_id is null or q.quote_id is null or n<>q.threshold_visits or new.reward_snapshot is distinct from d.coverage_snapshot or new.total<>0 or new.discount is distinct from q.gross_amount or new.order_id is distinct from d.order_id or new.branch_id is distinct from d.branch_id or not coalesce((d.consent->>'accept_terms')::boolean,false) then raise exception 'Server-created consented reward coverage and actual allocated visits required' using errcode='42501';end if;
 return new;
end $$;
revoke all on function private.guard_reward_invoice() from public,anon,authenticated,service_role;
create trigger guard_new_reward_invoice before insert or update on public.business_invoices for each row execute function private.guard_reward_invoice();
create function private.check_reward_coverage_commit() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;c jsonb;
begin
 select * into d from private.service_reward_redemptions where redemption_id=new.redemption_id;
 c:=private.reward_invoice_coverage(d.invoice_id);
 if c is null or d.result is null or not exists(select 1 from private.reward_ledger_events where event_key='cover:'||d.redemption_id) then raise exception 'Reward checkout coverage is incomplete; transaction rejected';end if;
 if d.state='restored' and exists(select 1 from private.reward_credit_claims where redemption_id=d.redemption_id and kind='reward' and released_at is null) then raise exception 'Restored reward retains active claims';end if;
 if d.state<>'restored' and (select count(*) from private.reward_credit_claims where redemption_id=d.redemption_id and kind='reward' and released_at is null)<>(select threshold_visits from private.service_reward_quotes where quote_id=d.quote_id) then raise exception 'Issued reward allocation count changed';end if;
 return new;
end $$;
revoke all on function private.check_reward_coverage_commit() from public,anon,authenticated,service_role;
create constraint trigger reward_coverage_commit_check after insert or update on private.service_reward_redemptions deferrable initially deferred for each row execute function private.check_reward_coverage_commit();
create function private.assert_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb,p_require boolean) returns boolean language plpgsql security definer set search_path=pg_catalog as $$
declare a private.service_booking_attempts;
begin
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':service-booking:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||auth.uid()::text,0));
 select * into a from private.service_booking_attempts where request_id=p_request and customer_id=auth.uid();
 if a.request_id is null then if p_require then raise exception 'Prepare the exact booking attempt first' using errcode='55000';end if;return false;end if;
 if a.customer_id<>auth.uid() then raise exception 'Booking attempt access denied' using errcode='42501';end if;
 if a.state='closed' then raise exception 'Booking request permanently closed; use a new request identity' using errcode='55000';end if;
 if a.mode<>p_mode or a.payload<>p_payload then raise exception 'Booking request mode/payload mismatch' using errcode='22023';end if;return true;
end $$;
revoke all on function private.assert_service_booking_attempt(uuid,text,jsonb,boolean) from public,anon,authenticated,service_role;
create function private.finish_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb,p_result jsonb) returns void language plpgsql security definer set search_path=pg_catalog as $$begin
 insert into private.service_booking_attempts(request_id,customer_id,mode,payload,state,result,acknowledged_at,resolved_at) values(p_request,auth.uid(),p_mode,p_payload,'succeeded',p_result,clock_timestamp(),clock_timestamp()) on conflict(customer_id,request_id)do update set state='succeeded',result=excluded.result,resolved_at=coalesce(service_booking_attempts.resolved_at,clock_timestamp());
end $$;
revoke all on function private.finish_service_booking_attempt(uuid,text,jsonb,jsonb) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION private.create_customer_service_booking(p_request uuid, p_service uuid, p_branch uuid, p_vehicle uuid, p_date date, p_time time without time zone, p_expected_price numeric, p_notes text DEFAULT NULL::text, p_reward_quote uuid DEFAULT NULL::uuid, p_adopt_existing boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  actor uuid := auth.uid();
  service public.business_catalog_items%rowtype;
  car public.vehicles%rowtype;
  customer public.customers%rowtype;
  visit public.bookings%rowtype;
  work public.business_orders%rowtype;
  receipt public.business_invoices%rowtype;
  note text := nullif(trim(p_notes),'');
  bid uuid := gen_random_uuid();
  oid uuid := gen_random_uuid();
  iid text;
  q private.service_reward_quotes;d private.service_reward_redemptions;a private.service_booking_attempts;
  payload jsonb;result_data jsonb;snapshot jsonb;rid uuid:=gen_random_uuid();
begin
  if actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_request is null or p_service is null or p_branch is null or p_vehicle is null
    or p_date is null or p_time is null or p_expected_price is null
    or length(coalesce(note,'')) > 2000 then
    raise exception 'Complete booking details required' using errcode='22023';
  end if;
  -- Same request may be retried after a lost HTTP response. A different payload
  -- must not silently reuse it, and a retry must retain its original price.
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':service-booking:' || p_request::text,0));
  if p_reward_quote is null then
    payload:=jsonb_build_object('p_service',p_service,'p_branch',p_branch,'p_vehicle',p_vehicle,'p_date',p_date,'p_time',p_time,'p_expected_price',p_expected_price,'p_notes',note);
    perform private.assert_service_booking_attempt(p_request,'normal',payload,false);
    if exists(select 1 from private.service_reward_redemptions where customer_id=actor and request_id=p_request) then raise exception 'Request belongs to reward checkout' using errcode='22023';end if;
  else
    select * into q from private.service_reward_quotes where quote_id=p_reward_quote and customer_id=actor;
    if q.quote_id is null then raise exception 'Own actual reward quote required' using errcode='42501';end if;
    payload:=jsonb_build_object('p_quote',q.quote_id,'p_fingerprint',q.fingerprint,'p_accept_terms',true,'p_adopt_existing_visits',p_adopt_existing);
    perform private.assert_service_booking_attempt(p_request,'reward',payload,true);
  end if;
  select * into a from private.service_booking_attempts where request_id=p_request and customer_id=actor;
  if a.state='succeeded' then return a.result;end if;
  select * into work from public.business_orders
    where customer_id=actor and customer_request_id=p_request;
  if found then
    if p_reward_quote is not null then raise exception 'Request already belongs to non-reward booking' using errcode='22023';end if;
    select * into visit from public.bookings where id=work.booking_id and customer_id=actor;
    if visit.id is null or work.order_type<>'service'
      or visit.catalog_item_id is distinct from p_service
      or visit.branch_id is distinct from p_branch or visit.vehicle_id is distinct from p_vehicle
      or visit.booking_date is distinct from p_date or visit.booking_time is distinct from p_time
      or visit.quoted_price is distinct from p_expected_price or visit.notes is distinct from note then
      raise exception 'Booking request payload mismatch' using errcode='22023';
    end if;
    select * into receipt from public.business_invoices where invoice_id='BOOKING-'||visit.id::text and order_id=work.order_id;
    if not found then raise exception 'Booking invoice unavailable; contact support'; end if;
    result_data:=jsonb_build_object('booking_id',visit.id,'order_id',work.order_id,
      'invoice_id',receipt.invoice_id,'quoted_price',visit.quoted_price,'branch_id',visit.branch_id);
    perform private.finish_service_booking_attempt(p_request,'normal',payload,result_data);return result_data;
  end if;

  select * into customer from public.customers where id=actor;
  if not found then raise exception 'Customer profile required' using errcode='42501'; end if;
  select * into car from public.vehicles where id=p_vehicle and customer_id=actor for share;
  if not found then raise exception 'Vehicle ownership required' using errcode='42501'; end if;
  select * into service from public.business_catalog_items
    where item_id=p_service and branch_id=p_branch and item_type='service'
      and is_active and is_public
      and name !~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'
    for share;
  if not found then raise exception 'Published branch service required' using errcode='22023'; end if;
  if service.price is distinct from p_expected_price then
    raise exception 'Service price changed; refresh before booking' using errcode='40001';
  end if;
  -- Serialize the same vehicle even across different resource/branch locks.
  perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||p_vehicle::text,0));
  -- Existing triggers retain hours, closure, capacity, ownership and server
  -- price/duration snapshots. Failure rolls the entire checkout back.
  insert into public.bookings(id,customer_id,branch_id,vehicle_id,catalog_item_id,
    service_name,booking_date,booking_time,notes)
    values(bid,actor,p_branch,p_vehicle,p_service,service.name,p_date,p_time,note)
    returning * into visit;
  iid := 'BOOKING-'||bid::text;
  insert into public.business_orders(order_id,order_number,customer_id,customer_name,
    customer_phone,booking_id,branch_id,plate_number,vehicle_type,service_name,
    order_type,customer_request_id,created_by,notes)
    values(oid,iid,actor,customer.full_name,customer.phone,bid,p_branch,car.plate_number,
      visit.vehicle_type,visit.service_name,'service',p_request,'customer_booking',note);
  insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)
    values(oid,p_service,visit.service_name,1,visit.quoted_price,visit.quoted_price);
  if p_reward_quote is null then
  insert into public.business_invoices(invoice_id,order_id,branch_id,plate_number,
    service_name,vehicle_type,total,payment_method,created_by)
    values(iid,oid,p_branch,car.plate_number,visit.service_name,visit.vehicle_type,
      visit.quoted_price,'cash_on_receipt','customer_booking');
  else
    if q.expires_at<=clock_timestamp() or q.gross_amount is distinct from visit.quoted_price or q.service_id<>p_service or q.branch_id<>p_branch or q.vehicle_id<>p_vehicle or q.booking_date<>p_date or q.booking_time<>p_time or q.notes is distinct from note then raise exception 'Reward quote expired or booking details changed' using errcode='40001';end if;
    snapshot:=jsonb_build_object('state','covered_by_reward','quote_id',q.quote_id,'quote_fingerprint',q.fingerprint,'policy_version_id',q.policy_version_id,'rules_version_id',q.rules_version_id,'threshold_visits',q.threshold_visits,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','rules',q.terms_snapshot->'rules','source_channel','booking','order_id',oid,'booking_id',bid,'reward_service',jsonb_build_object('id',p_service,'name',visit.service_name),'adopted_visit_count',cardinality(q.adoption_ids),'original_credit_expiry_preserved',true);
    insert into private.service_reward_redemptions(redemption_id,customer_id,request_id,quote_id,source_channel,branch_id,order_id,booking_id,invoice_id,rules_version_id,policy_version_id,consent,coverage_snapshot,creator_xid) values(rid,actor,p_request,q.quote_id,'booking',p_branch,oid,bid,iid,q.rules_version_id,q.policy_version_id,jsonb_build_object('accept_terms',true,'adopt_existing_visits',p_adopt_existing,'fingerprint',q.fingerprint,'accepted_at',clock_timestamp()),snapshot,txid_current());
    insert into private.reward_credit_claims(earning_id,customer_id,kind,redemption_id,quote_id) select e,actor,'reward',rid,q.quote_id from unnest(q.earning_ids)e;
    insert into private.reward_ledger_events(event_key,redemption_id,actor_id,data) values('cover:'||rid,rid,actor,snapshot);
    insert into public.business_invoices(invoice_id,order_id,branch_id,plate_number,service_name,vehicle_type,total,discount,payment_method,created_by,reward_snapshot) values(iid,oid,p_branch,car.plate_number,visit.service_name,visit.vehicle_type,0,q.gross_amount,'reward_coverage','customer_reward_booking',snapshot) returning * into receipt;
    result_data:=jsonb_build_object('booking_id',bid,'order_id',oid,'invoice_id',iid,'booking_number',visit.display_number,'invoice_number',receipt.display_number,'quoted_price',q.gross_amount,'gross_amount',q.gross_amount,'reward_discount',q.gross_amount,'amount_due',0,'currency','EGP','payment_status','covered_by_reward','collectible',false,'quote_id',q.quote_id,'rules_version_id',q.rules_version_id,'policy_version_id',q.policy_version_id,'visits_consumed',q.threshold_visits,'rules',q.terms_snapshot->'rules','source_channel','booking','branch_id',p_branch);
    update private.service_reward_redemptions set result=result_data where redemption_id=rid;
  end if;
  insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)
    values(actor::text,actor,'customer_service_booking','bookings',bid::text,p_branch,
      jsonb_build_object('order_id',oid,'invoice_id',iid,'quoted_price',visit.quoted_price));
  if p_reward_quote is null then result_data:=jsonb_build_object('booking_id',bid,'order_id',oid,'invoice_id',iid,'quoted_price',visit.quoted_price,'branch_id',p_branch);end if;
  perform private.finish_service_booking_attempt(p_request,case when p_reward_quote is null then 'normal' else 'reward' end,payload,result_data);
  return result_data;
end;
$function$;
revoke all on function private.create_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text,uuid,boolean) from public,anon,authenticated,service_role;
create or replace function private.place_customer_service_booking(p_request uuid,p_service uuid,p_branch uuid,p_vehicle uuid,p_date date,p_time time,p_expected_price numeric,p_notes text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 return private.create_customer_service_booking(p_request,p_service,p_branch,p_vehicle,p_date,p_time,p_expected_price,p_notes,null,false);
end $$;
revoke all on function private.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text) from public,anon;
grant execute on function private.place_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text) to authenticated;
create function private.service_booking_attempt_result(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.service_reward_redemptions;o public.business_orders;b public.bookings;i public.business_invoices;c jsonb;
begin
 select * into d from private.service_reward_redemptions where customer_id=auth.uid() and request_id=p_request;
 if d.redemption_id is not null then
 perform private.sync_customer_rewards(auth.uid());select * into d from private.service_reward_redemptions where redemption_id=d.redemption_id;
 select * into b from public.bookings where id=d.booking_id;select * into i from public.business_invoices where invoice_id=d.invoice_id;c:=private.reward_invoice_coverage(d.invoice_id);
 return d.result||jsonb_build_object('booking_status',b.status,'redemption_status',d.state,'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when c->>'state'='covered_by_reward' then 'covered_by_reward' else 'not_recorded' end);end if;
 select * into o from public.business_orders where customer_id=auth.uid() and customer_request_id=p_request;
 if o.order_id is null then return null;end if;
 if o.order_type<>'service' then return jsonb_build_object('different_mode',true);end if;
 select * into b from public.bookings where id=o.booking_id and customer_id=auth.uid();select * into i from public.business_invoices where order_id=o.order_id and invoice_id='BOOKING-'||b.id::text;
 if b.id is null or i.invoice_id is null then raise exception 'Booking source requires review';end if;
 return jsonb_build_object('booking_id',b.id,'order_id',o.order_id,'invoice_id',i.invoice_id,'booking_number',b.display_number,'invoice_number',i.display_number,'quoted_price',b.quoted_price,'branch_id',b.branch_id,'booking_status',b.status,'amount_due',i.total,'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash') then 'paid' when exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='electronic') then 'verification_required' else 'unpaid' end);
end $$;
revoke all on function private.service_booking_attempt_result(uuid) from public,anon,authenticated,service_role;
create function private.service_booking_attempt_view(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a private.service_booking_attempts;r jsonb;q private.service_reward_quotes;o public.business_orders;b public.bookings;
begin
 select * into a from private.service_booking_attempts where request_id=p_request and customer_id=auth.uid();
 r:=private.service_booking_attempt_result(p_request);
 if coalesce((r->>'different_mode')::boolean,false) then return jsonb_build_object('state','different_mode','request_id',p_request);end if;
 if r is not null then
 if a.request_id is null then
 select * into o from public.business_orders where customer_id=auth.uid() and customer_request_id=p_request;select * into b from public.bookings where id=o.booking_id;
 insert into private.service_booking_attempts(request_id,customer_id,mode,payload,state,result,acknowledged_at,resolved_at) values(p_request,auth.uid(),'normal',jsonb_build_object('p_service',b.catalog_item_id,'p_branch',b.branch_id,'p_vehicle',b.vehicle_id,'p_date',b.booking_date,'p_time',b.booking_time,'p_expected_price',b.quoted_price,'p_notes',b.notes),'succeeded',r,clock_timestamp(),clock_timestamp()) returning * into a;
 elsif a.state='open' then update private.service_booking_attempts set state='succeeded',result=coalesce(result,r),resolved_at=coalesce(resolved_at,clock_timestamp()) where customer_id=auth.uid() and request_id=p_request returning * into a;
 elsif a.state='closed' then return jsonb_build_object('state','manual_review_required','request_id',p_request,'reason','closed_request_has_external_order');end if;
 return jsonb_build_object('state','succeeded','request_id',p_request,'mode',a.mode,'payload',a.payload,'result',r,'acknowledged',a.acknowledged_at is not null);end if;
 if a.request_id is null then return jsonb_build_object('state','absent','request_id',p_request);end if;
 if a.mode='reward' then select * into q from private.service_reward_quotes where quote_id=(a.payload->>'p_quote')::uuid and customer_id=auth.uid();end if;
 return jsonb_build_object('state',a.state,'request_id',p_request,'mode',a.mode,'payload',a.payload,'form_context',case when q.quote_id is null then null else to_jsonb(q) end);
end $$;
revoke all on function private.service_booking_attempt_view(uuid) from public,anon,authenticated,service_role;
create function private.get_service_booking_attempt(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare rid uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 if p_request is not null then perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':service-booking:'||p_request::text,0));end if;
 perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||auth.uid()::text,0));
 if p_request is null then select request_id into rid from private.service_booking_attempts where customer_id=auth.uid() and(state='open' or(state='succeeded' and acknowledged_at is null))order by created_at desc limit 1;else rid:=p_request;end if;
 if rid is null then return jsonb_build_object('state','absent','request_id',null);end if;
 return private.service_booking_attempt_view(rid);
end $$;
create function public.get_service_booking_attempt(p_request uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_service_booking_attempt(p_request)$$;
revoke all on function private.get_service_booking_attempt(uuid),public.get_service_booking_attempt(uuid) from public,anon;
grant execute on function private.get_service_booking_attempt(uuid),public.get_service_booking_attempt(uuid) to authenticated;
create function private.prepare_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare a private.service_booking_attempts;payload jsonb;view jsonb;q private.service_reward_quotes;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null or p_mode is null or p_mode not in('normal','reward') or p_payload is null or jsonb_typeof(p_payload)<>'object' or pg_column_size(p_payload)>16000 then raise exception 'Explicit mode and complete booking payload required' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':service-booking:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||auth.uid()::text,0));
 if p_mode='normal' then
 if not p_payload ?& array['p_service','p_branch','p_vehicle','p_date','p_time','p_expected_price','p_notes'] or p_payload-array['p_service','p_branch','p_vehicle','p_date','p_time','p_expected_price','p_notes']<>'{}'::jsonb then raise exception 'Exact normal booking fields required' using errcode='22023';end if;
 payload:=jsonb_build_object('p_service',(p_payload->>'p_service')::uuid,'p_branch',(p_payload->>'p_branch')::uuid,'p_vehicle',(p_payload->>'p_vehicle')::uuid,'p_date',(p_payload->>'p_date')::date,'p_time',(p_payload->>'p_time')::time,'p_expected_price',(p_payload->>'p_expected_price')::numeric,'p_notes',nullif(trim(p_payload->>'p_notes'),''));
 if payload->>'p_service' is null or payload->>'p_branch' is null or payload->>'p_vehicle' is null or payload->>'p_date' is null or payload->>'p_time' is null or payload->>'p_expected_price' is null or length(coalesce(payload->>'p_notes',''))>2000 then raise exception 'Complete normal booking fields required' using errcode='22023';end if;
 else
 if not p_payload ?& array['p_quote','p_fingerprint','p_accept_terms','p_adopt_existing_visits'] or p_payload-array['p_quote','p_fingerprint','p_accept_terms','p_adopt_existing_visits']<>'{}'::jsonb then raise exception 'Exact reward booking fields required' using errcode='22023';end if;
 payload:=jsonb_build_object('p_quote',(p_payload->>'p_quote')::uuid,'p_fingerprint',p_payload->>'p_fingerprint','p_accept_terms',(p_payload->>'p_accept_terms')::boolean,'p_adopt_existing_visits',(p_payload->>'p_adopt_existing_visits')::boolean);
 select * into q from private.service_reward_quotes where quote_id=(payload->>'p_quote')::uuid and customer_id=auth.uid();
 if q.quote_id is null or payload->>'p_fingerprint' is distinct from q.fingerprint or(payload->>'p_accept_terms')::boolean is distinct from true or(payload->>'p_adopt_existing_visits')is null or(cardinality(q.adoption_ids)>0 and(payload->>'p_adopt_existing_visits')::boolean is not true) then raise exception 'Own quote and explicit complete consent required' using errcode='22023';end if;
 end if;
 select * into a from private.service_booking_attempts where customer_id=auth.uid() and request_id=p_request;
 if a.request_id is not null then
 if a.state='closed' then return private.service_booking_attempt_view(p_request);end if;
 if a.mode<>p_mode or a.payload<>payload then raise exception 'Prepared mode/payload is immutable' using errcode='22023';end if;return private.service_booking_attempt_view(p_request);end if;
 view:=private.service_booking_attempt_view(p_request);if view->>'state'<>'absent' then if view->>'mode' is distinct from p_mode then raise exception 'Request belongs to another booking mode' using errcode='22023';end if;return view;end if;
 if exists(select 1 from private.service_booking_attempts where customer_id=auth.uid() and(state='open' or(state='succeeded' and acknowledged_at is null))) then raise exception 'Resolve and acknowledge the previous booking attempt first' using errcode='55000';end if;
 insert into private.service_booking_attempts(request_id,customer_id,mode,payload,state) values(p_request,auth.uid(),p_mode,payload,'open');return private.service_booking_attempt_view(p_request);
end $$;
create function public.prepare_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_service_booking_attempt(p_request,p_mode,p_payload)$$;
revoke all on function private.prepare_service_booking_attempt(uuid,text,jsonb),public.prepare_service_booking_attempt(uuid,text,jsonb) from public,anon;
grant execute on function private.prepare_service_booking_attempt(uuid,text,jsonb),public.prepare_service_booking_attempt(uuid,text,jsonb) to authenticated;
create function private.close_service_booking_attempt(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare view jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null then raise exception 'Request identity required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':service-booking:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('service-booking-customer:'||auth.uid()::text,0));
 view:=private.service_booking_attempt_view(p_request);
 if view->>'state' in('succeeded','different_mode','manual_review_required') then return view;end if;
 insert into private.service_booking_attempts(request_id,customer_id,mode,payload,state,resolved_at) values(p_request,auth.uid(),'tombstone',null,'closed',clock_timestamp()) on conflict(customer_id,request_id)do update set state='closed',resolved_at=coalesce(service_booking_attempts.resolved_at,clock_timestamp());
 return private.service_booking_attempt_view(p_request);
end $$;
create function public.close_service_booking_attempt(p_request uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_service_booking_attempt(p_request)$$;
revoke all on function private.close_service_booking_attempt(uuid),public.close_service_booking_attempt(uuid) from public,anon;
grant execute on function private.close_service_booking_attempt(uuid),public.close_service_booking_attempt(uuid) to authenticated;
create function private.acknowledge_service_booking_attempt(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare view jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 view:=private.get_service_booking_attempt(p_request);
 if view->>'state'<>'succeeded' then raise exception 'A successful own booking receipt must be reviewed before acknowledgement' using errcode='55000';end if;
 update private.service_booking_attempts set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()) where customer_id=auth.uid() and request_id=p_request;
 return jsonb_build_object('state','acknowledged','request_id',p_request);
end $$;
create function public.acknowledge_service_booking_attempt(p_request uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.acknowledge_service_booking_attempt(p_request)$$;
revoke all on function private.acknowledge_service_booking_attempt(uuid),public.acknowledge_service_booking_attempt(uuid) from public,anon;
grant execute on function private.acknowledge_service_booking_attempt(uuid),public.acknowledge_service_booking_attempt(uuid) to authenticated;
create function private.place_customer_reward_booking(p_request uuid,p_quote uuid,p_fingerprint text,p_accept_terms boolean,p_adopt_existing_visits boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare q private.service_reward_quotes;a private.service_booking_attempts;payload jsonb;blocked jsonb;available uuid[];item jsonb;terms jsonb;result jsonb;
begin
 if auth.uid() is null then raise exception 'Customer sign-in required' using errcode='42501';end if;
 if p_request is null or p_quote is null or p_fingerprint is null or p_accept_terms is distinct from true or p_adopt_existing_visits is null then raise exception 'Explicit quote and full consent required' using errcode='22023';end if;
 payload:=jsonb_build_object('p_quote',p_quote,'p_fingerprint',p_fingerprint,'p_accept_terms',p_accept_terms,'p_adopt_existing_visits',p_adopt_existing_visits);
 perform private.assert_service_booking_attempt(p_request,'reward',payload,true);
 select * into a from private.service_booking_attempts where customer_id=auth.uid() and request_id=p_request;
 if a.state='succeeded' then return private.service_booking_attempt_result(p_request);end if;
 if not exists(select 1 from private.reward_runtime where singleton and booking_installed and readers_integrated) then raise exception 'Reward checkout temporarily unavailable' using errcode='55000';end if;
 select * into q from private.service_reward_quotes where quote_id=p_quote and customer_id=auth.uid();
 if q.quote_id is null or q.fingerprint is distinct from p_fingerprint then raise exception 'Own exact quote required' using errcode='42501';end if;
 if q.expires_at<=clock_timestamp() then raise exception 'Reward quote expired; close this attempt before quoting again' using errcode='40001';end if;
 if cardinality(q.adoption_ids)>0 and not p_adopt_existing_visits then raise exception 'Existing visits require the explicitly quoted adoption consent' using errcode='22023';end if;
 if exists(select 1 from public.business_orders where customer_id=auth.uid() and customer_request_id=p_request) then raise exception 'Booking request belongs to another mode' using errcode='22023';end if;
 if exists(select 1 from private.service_reward_redemptions where quote_id=q.quote_id) then raise exception 'Quote already used by another booking request' using errcode='22023';end if;
 perform private.sync_customer_rewards(auth.uid());
 -- Refund writers hold invoice UPDATE locks but never the customer reward mutex.
 perform 1 from public.business_invoices i join private.canonical_loyalty_visits e on e.invoice_id=i.invoice_id where e.id=any(q.earning_ids) order by i.invoice_id for update of i;
 perform private.sync_customer_rewards(auth.uid());blocked:=private.reward_program_blockers(auth.uid(),q.rules_version_id);
 if not(blocked->>'eligible')::boolean then raise exception 'Refund debt or owner review now blocks this quote' using errcode='55000';end if;
 select array_agg(earning_id) into available from private.reward_program_lots(auth.uid(),q.rules_version_id)where earning_id=any(q.earning_ids);
 if coalesce(cardinality(available),0)<>q.threshold_visits then raise exception 'Quoted earning lots changed; close and review a fresh quote' using errcode='40001';end if;
 for item in select * from jsonb_array_elements(q.allocation_snapshot) loop
 terms:=private.reward_credit_terms((item->>'earning_id')::uuid,q.rules_version_id);
 if terms is distinct from item->'credit_terms' then raise exception 'Quoted credit terms changed; close and review again' using errcode='40001';end if;
 end loop;
 -- Adoption is recorded only inside the successful atomic checkout, never by quote viewing.
 insert into private.reward_earning_terms(earning_id,rules_version_id,adoption_quote_id) select e,q.rules_version_id,q.quote_id from unnest(q.adoption_ids)e on conflict(earning_id)do nothing;
 result:=private.create_customer_service_booking(p_request,q.service_id,q.branch_id,q.vehicle_id,q.booking_date,q.booking_time,q.gross_amount,q.notes,q.quote_id,p_adopt_existing_visits);
 return result;
end $$;
create function public.place_customer_reward_booking(p_request uuid,p_quote uuid,p_fingerprint text,p_accept_terms boolean,p_adopt_existing_visits boolean default false) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.place_customer_reward_booking(p_request,p_quote,p_fingerprint,p_accept_terms,p_adopt_existing_visits)$$;
revoke all on function private.place_customer_reward_booking(uuid,uuid,text,boolean,boolean),public.place_customer_reward_booking(uuid,uuid,text,boolean,boolean) from public,anon;
grant execute on function private.place_customer_reward_booking(uuid,uuid,text,boolean,boolean),public.place_customer_reward_booking(uuid,uuid,text,boolean,boolean) to authenticated;
-- Compatibility aliases for the reward-specific recovery contract; generic attempts are authoritative.
create function public.get_customer_reward_booking(p_request uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_service_booking_attempt(p_request)$$;
create function public.acknowledge_customer_reward_booking(p_request uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.acknowledge_service_booking_attempt(p_request)$$;
revoke all on function public.get_customer_reward_booking(uuid),public.acknowledge_customer_reward_booking(uuid) from public,anon;
grant execute on function public.get_customer_reward_booking(uuid),public.acknowledge_customer_reward_booking(uuid) to authenticated;

-- Preserve existing customer cancellation/rescheduling rules; synchronize the issued reward atomically.
CREATE OR REPLACE FUNCTION private.change_customer_booking(p_request uuid, p_booking uuid, p_action text, p_date date DEFAULT NULL::date, p_time time without time zone DEFAULT NULL::time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare b public.bookings%rowtype;o public.business_orders%rowtype;i public.business_invoices%rowtype;r private.customer_booking_change_requests%rowtype;payload jsonb;before_value jsonb;result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Reward operations require READ COMMITTED' using errcode='25001';end if;
 perform pg_advisory_xact_lock(hashtextextended('reward-customer:'||auth.uid()::text,0));
 select * into b from public.bookings where id=p_booking and customer_id=auth.uid() for update;
 if not found then raise exception 'Booking access denied' using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in ('cancel','reschedule') or (p_action='cancel' and (p_date is not null or p_time is not null)) or (p_action='reschedule' and (p_date is null or p_time is null)) then raise exception 'Invalid booking change' using errcode='22023';end if;
 payload:=jsonb_build_object('booking',p_booking,'action',p_action,'date',p_date,'time',p_time);
 perform pg_advisory_xact_lock(hashtextextended('customer-booking-change:'||p_request::text,0));
 select * into r from private.customer_booking_change_requests where request_id=p_request;
 if found then
  if r.actor_id<>auth.uid() or r.booking_id<>p_booking then raise exception 'Request access denied' using errcode='42501';end if;
  if r.payload<>payload then raise exception 'Request payload mismatch' using errcode='22023';end if;
  return r.result;
 end if;
 if b.status<>'pending' or coalesce(cardinality(b.assigned_staff_ids),0)>0 or (b.booking_date+b.booking_time) at time zone 'Africa/Cairo'<=clock_timestamp() then raise exception 'Only future pending unassigned bookings may be changed; contact management';end if;
 select * into o from public.business_orders where booking_id=b.id and customer_id=auth.uid() and order_type='service' for update;
 if not found or o.status<>'received' or coalesce(cardinality(o.assigned_staff_ids),0)>0 then raise exception 'Order requires management';end if;
 if (select count(*) from public.business_orders where booking_id=b.id)<>1 then raise exception 'Ambiguous booking order';end if;
 select * into i from public.business_invoices where order_id=o.order_id for update;
 if not found or (select count(*) from public.business_invoices where order_id=o.order_id)<>1 or i.status<>'active' then raise exception 'Invoice requires management';end if;
 if exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale') or exists(select 1 from private.paymob_intents where invoice_id=i.invoice_id and status in ('creating','pending','uncertain','sandbox_succeeded','refund_reported')) then raise exception 'Payment recorded or unresolved; contact management';end if;
 before_value:=jsonb_build_object('booking',to_jsonb(b),'order',to_jsonb(o),'invoice',to_jsonb(i));
 if p_action='cancel' then
  update public.bookings set status='cancelled' where id=b.id;
  update public.business_orders set status='cancelled',updated_at=now() where order_id=o.order_id;
  update public.business_invoices set status='void' where invoice_id=i.invoice_id;
 else
  if (p_date+p_time) at time zone 'Africa/Cairo'<=clock_timestamp() or not exists(select 1 from private.available_booking_slots(b.branch_id,b.catalog_item_id,p_date) where slot_time=p_time) then raise exception 'Choose an available future appointment';end if;
  perform pg_advisory_xact_lock(hashtextextended('booking-vehicle:'||b.vehicle_id::text,0));
  update public.bookings set booking_date=p_date,booking_time=p_time where id=b.id;
 end if;
 perform private.sync_customer_rewards(auth.uid());
 select * into b from public.bookings where id=b.id;select * into o from public.business_orders where order_id=o.order_id;select * into i from public.business_invoices where invoice_id=i.invoice_id;
 result:=jsonb_build_object('booking_id',b.id,'status',b.status,'booking_date',b.booking_date,'booking_time',b.booking_time,'invoice_id',i.invoice_id);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data) values(auth.uid()::text,auth.uid(),'customer_booking_'||p_action,'bookings',b.id::text,b.branch_id,before_value,jsonb_build_object('booking',to_jsonb(b),'order',to_jsonb(o),'invoice',to_jsonb(i),'request_id',p_request));
 insert into private.customer_booking_change_requests(request_id,actor_id,booking_id,payload,result) values(p_request,auth.uid(),b.id,payload,result);return result;
end;$function$;

create function private.guard_service_booking_attempt() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if tg_op='DELETE' then raise exception 'Booking request history is retained';end if;
 if new.customer_id<>old.customer_id or new.request_id<>old.request_id or new.mode<>old.mode or new.payload is distinct from old.payload or new.created_at<>old.created_at then raise exception 'Booking request identity and payload are immutable';end if;
 if old.state<>'open' and new.state<>old.state then raise exception 'Resolved booking request cannot reopen';end if;
 if old.result is not null and new.result is distinct from old.result then raise exception 'Booking receipt is immutable';end if;
 if old.acknowledged_at is not null and new.acknowledged_at is distinct from old.acknowledged_at then raise exception 'Booking acknowledgement is immutable';end if;
 return new;
end $$;
revoke all on function private.guard_service_booking_attempt() from public,anon,authenticated,service_role;
create trigger service_booking_attempt_immutable before update or delete on private.service_booking_attempts for each row execute function private.guard_service_booking_attempt();
-- This wallet deliberately reports each potentially overlapping pool separately.
create function private.get_my_reward_wallet() returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare programs jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid())then raise exception 'Customer sign-in required' using errcode='42501';end if;
 perform private.sync_customer_rewards(auth.uid());
 select coalesce(jsonb_agg(jsonb_build_object('rules_version_id',r.rules_version_id,'policy_version_id',r.policy_version_id,'offer_id',r.offer_id,'offer_name',r.terms_snapshot#>>'{offer,name}','reward_service',r.terms_snapshot->'reward_service','branch_id',r.branch_id,'rules',r.rules,'readiness',private.reward_backend_readiness(r.policy_version_id),'reserved_visits',0,'threshold_visits',(r.terms_snapshot->>'threshold_visits')::integer,'unused_valid_visits',(select count(*)from private.reward_program_lots(auth.uid(),r.rules_version_id)),'adoption_required_visits',(select count(*)from private.reward_program_lots(auth.uid(),r.rules_version_id) l where not exists(select 1 from private.reward_earning_terms e where e.earning_id=l.earning_id)),'blockers',private.reward_program_blockers(auth.uid(),r.rules_version_id))order by r.version_no),'[]'::jsonb) into programs from private.loyalty_redemption_rule_versions r join private.reward_rule_activations a using(rules_version_id)where r.terms_snapshot->'target_customer_ids'='null'::jsonb or r.terms_snapshot->'target_customer_ids' @> to_jsonb(array[auth.uid()]);
 return jsonb_build_object('unit','service_visits','programs',programs,'pools_overlap',true,'global_spendable_balance',null,'consumed_reward_visits',(select count(*)from private.reward_credit_claims where customer_id=auth.uid()and kind='reward'and released_at is null),'refund_offset_visits',(select count(*)from private.reward_credit_claims where customer_id=auth.uid()and kind='offset'and released_at is null),'redemption_supported_channel','booking');
end $$;
create function public.get_my_reward_wallet() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_reward_wallet()$$;
revoke all on function private.get_my_reward_wallet(),public.get_my_reward_wallet() from public,anon;
grant execute on function private.get_my_reward_wallet(),public.get_my_reward_wallet() to authenticated;
create or replace function private.reward_backend_readiness(p_policy uuid) returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 with capability as(select
 to_regprocedure('private.quote_service_reward(uuid,uuid,uuid,uuid,date,time without time zone,uuid,uuid,text)')is not null quote,
 to_regprocedure('private.place_customer_reward_booking(uuid,uuid,text,boolean,boolean)')is not null and x.booking_installed booking,
 to_regclass('private.reward_credit_claims')is not null allocation,
 exists(select 1 from pg_trigger where tgrelid='public.business_invoices'::regclass and tgname='guard_new_reward_invoice'and not tgisinternal) consumption,
 to_regprocedure('private.sync_customer_rewards(uuid)')is not null and position('sync_customer_rewards' in pg_get_functiondef(to_regprocedure('private.change_customer_booking(uuid,uuid,text,date,time without time zone)')))>0 release,
 to_regprocedure('private.resolve_reward_refund_review(uuid,uuid,text)')is not null resolution,
 exists(select 1 from pg_trigger where tgname='capture_new_reward_credit_terms'and not tgisinternal) binding,
 x.readers_integrated readers from private.reward_runtime x where singleton)
 select jsonb_build_object('quote_implemented',quote,'booking_implemented',booking,'allocation_implemented',allocation,'consumption_implemented',consumption,'release_implemented',release,'refund_resolution_implemented',resolution,'earning_rules_binding_implemented',binding,'readers_integrated',readers,'booking_channel_supported',true,'walk_in_supported',false,'stacking_supported',false,'partial_redemption_supported',false,'current_rules_activated',exists(select 1 from private.reward_rule_activations where rules_version_id=(select rules_version_id from private.loyalty_redemption_rule_versions where policy_version_id=p_policy order by version_no desc limit 1)),'redemption_enabled',quote and booking and allocation and consumption and release and resolution and binding and readers and exists(select 1 from private.reward_rule_activations a join private.loyalty_redemption_rule_versions r using(rules_version_id)where r.policy_version_id=p_policy))from capability;
$$;
update private.reward_runtime set booking_installed=true where singleton;
notify pgrst,'reload schema';
commit;
