begin;
-- Server engine only. No scheduler or policy activation is enabled by this migration.
create table private.loyalty_visit_runtime(singleton boolean primary key default true check(singleton),scheduler_configured boolean not null default false,installed_at timestamptz not null default clock_timestamp());
insert into private.loyalty_visit_runtime(singleton,scheduler_configured) values(true,false);
create table private.loyalty_visit_activations(activation_id uuid primary key,policy_version_id uuid not null unique references private.loyalty_policy_versions(version_id),activated_by uuid not null references public.staff_profiles(user_id),activated_at timestamptz not null default clock_timestamp());
create table private.loyalty_earning_snapshot_bindings(booking_id uuid primary key references private.booking_loyalty_policy_snapshots(booking_id),activation_id uuid not null references private.loyalty_visit_activations(activation_id),customer_id uuid not null references public.customers(id),branch_id uuid not null references public.business_branches(branch_id),catalog_item_id uuid not null references public.business_catalog_items(item_id),captured_at timestamptz not null default clock_timestamp());
create table private.canonical_loyalty_visits(
 id uuid primary key default gen_random_uuid(),kind text not null check(kind in ('earn','refund')),visits integer not null,branch_id uuid not null references public.business_branches(branch_id),customer_id uuid not null references public.customers(id),
 order_id uuid not null references public.business_orders(order_id),booking_id uuid not null references public.bookings(id),invoice_id text not null references public.business_invoices(invoice_id),
 sale_payment_id uuid not null references public.business_payment_events(payment_id),refund_payment_id uuid references public.business_payment_events(payment_id),
 activation_id uuid not null references private.loyalty_visit_activations(activation_id),policy_version_id uuid not null references private.loyalty_policy_versions(version_id),
 reverses_earning uuid references private.canonical_loyalty_visits(id),facts jsonb not null,created_at timestamptz not null default clock_timestamp(),
 check((kind='earn' and visits=1 and reverses_earning is null and refund_payment_id is null) or (kind='refund' and visits=-1 and reverses_earning is not null and refund_payment_id is not null)));
create unique index canonical_one_visit_per_order on private.canonical_loyalty_visits(order_id) where kind='earn';
create unique index canonical_one_visit_reversal on private.canonical_loyalty_visits(reverses_earning) where kind='refund';
create index canonical_visit_branch_kind on private.canonical_loyalty_visits(branch_id,kind);
create index canonical_visit_customer on private.canonical_loyalty_visits(customer_id,created_at);
create table private.loyalty_visit_outbox(event_id uuid primary key default gen_random_uuid(),source_kind text not null,source_id uuid not null,order_id uuid,booking_id uuid,invoice_id text,
 created_at timestamptz not null default clock_timestamp(),processed_at timestamptz,result_code text,attempts integer not null default 0,next_attempt_at timestamptz not null default clock_timestamp(),last_error_code text,unique(source_kind,source_id));
create index loyalty_visit_outbox_pending on private.loyalty_visit_outbox(next_attempt_at,created_at,event_id) where processed_at is null;
do $$declare t text;begin foreach t in array array['loyalty_visit_runtime','loyalty_visit_activations','loyalty_earning_snapshot_bindings','canonical_loyalty_visits','loyalty_visit_outbox'] loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end $$;
create function private.immutable_canonical_visit() returns trigger language plpgsql security invoker set search_path=pg_catalog as $$begin raise exception 'Canonical visit history is immutable';end $$;
revoke all on function private.immutable_canonical_visit() from public,anon,authenticated,service_role;
create trigger immutable_canonical_visit before update or delete on private.canonical_loyalty_visits for each row execute function private.immutable_canonical_visit();
create trigger immutable_earning_snapshot_binding before update or delete on private.loyalty_earning_snapshot_bindings for each row execute function private.immutable_canonical_visit();
create trigger immutable_visit_activation before update or delete on private.loyalty_visit_activations for each row execute function private.immutable_canonical_visit();
create function private.loyalty_visit_scheduler_ready() returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare ready boolean;
begin
 if not coalesce((select scheduler_configured from private.loyalty_visit_runtime where singleton),false) or to_regclass('cron.job') is null then return false;end if;
 execute 'select exists(select 1 from cron.job where jobname=$1 and active and database=$2 and username=''postgres'' and schedule=''* * * * *'' and command=''select private.run_loyalty_visit_cron();'')' into ready using 'canonical-loyalty-visits',current_database();
 return ready;
end $$;
revoke all on function private.loyalty_visit_scheduler_ready() from public,anon,authenticated,service_role;
create function private.loyalty_visit_cron_last_success() returns timestamptz language plpgsql stable security definer set search_path=pg_catalog as $$
declare last_success timestamptz;installed timestamptz;
begin
 if not private.loyalty_visit_scheduler_ready() or to_regclass('cron.job_run_details') is null then return null;end if;
 select installed_at into installed from private.loyalty_visit_runtime where singleton;
 execute 'select max(r.end_time) from cron.job j join cron.job_run_details r using(jobid) where j.jobname=$1 and j.active and j.database=$2 and j.username=''postgres'' and j.command=''select private.run_loyalty_visit_cron();'' and r.command=''select private.run_loyalty_visit_cron();'' and r.database=$2 and r.username=''postgres'' and r.status=''succeeded'' and r.start_time>=$3 and r.end_time>=$3' into last_success using 'canonical-loyalty-visits',current_database(),installed;
 return last_success;
end $$;
revoke all on function private.loyalty_visit_cron_last_success() from public,anon,authenticated,service_role;
create function private.activate_loyalty_visits(p_request uuid,p_policy_version uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v private.loyalty_policy_versions;a private.loyalty_visit_activations;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_policy_version is null then raise exception 'Explicit activation request and policy required';end if;
 perform pg_advisory_xact_lock(hashtextextended('loyalty-activation:'||p_policy_version::text,0));
 select * into a from private.loyalty_visit_activations where activation_id=p_request;
 if a.activation_id is not null then if a.policy_version_id<>p_policy_version or a.activated_by<>auth.uid() then raise exception 'Activation request reused';end if;return to_jsonb(a);end if;
 if not private.loyalty_visit_scheduler_ready() or coalesce(private.loyalty_visit_cron_last_success()<clock_timestamp()-interval '5 minutes',true) then raise exception 'A recent successful durable visit scheduler run is required';end if;
 select * into v from private.loyalty_policy_versions where version_id=p_policy_version;
 if v.version_id is null or not v.enabled or exists(select 1 from private.loyalty_policy_versions newer where newer.branch_id=v.branch_id and newer.version_no>v.version_no) then raise exception 'Current explicitly enabled policy version required';end if;
 insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by) values(p_request,p_policy_version,auth.uid()) returning * into a;
 return to_jsonb(a);
end $$;
revoke all on function private.activate_loyalty_visits(uuid,uuid) from public,anon;
grant execute on function private.activate_loyalty_visits(uuid,uuid) to authenticated;
create function public.activate_loyalty_visits(p_request uuid,p_policy_version uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.activate_loyalty_visits(p_request,p_policy_version)$$;
revoke all on function public.activate_loyalty_visits(uuid,uuid) from public,anon;
grant execute on function public.activate_loyalty_visits(uuid,uuid) to authenticated;
create function private.evaluate_loyalty_visit(p_order uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare o public.business_orders;b public.bookings;s private.booking_loyalty_policy_snapshots;a private.loyalty_visit_activations;eb private.loyalty_earning_snapshot_bindings;i public.business_invoices;p public.business_payment_events;n bigint;
begin
 if not private.loyalty_visit_scheduler_ready() then return jsonb_build_object('eligible',false,'reason','scheduler_disabled');end if;
 select * into o from public.business_orders where order_id=p_order;
 if o.order_id is null or o.order_type<>'service' or o.booking_id is null then return jsonb_build_object('eligible',false,'reason','canonical_service_order_required');end if;
 select * into b from public.bookings where id=o.booking_id;
 select * into s from private.booking_loyalty_policy_snapshots where booking_id=o.booking_id;
 if s.booking_id is null then return jsonb_build_object('eligible',false,'reason','no_frozen_policy');end if;
 select * into eb from private.loyalty_earning_snapshot_bindings where booking_id=s.booking_id;
 select * into a from private.loyalty_visit_activations where activation_id=eb.activation_id and policy_version_id=s.policy_version_id;
 if a.activation_id is null or s.captured_at<a.activated_at then return jsonb_build_object('eligible',false,'reason','predates_explicit_activation');end if;
 if b.customer_id is null or eb.customer_id is distinct from b.customer_id or eb.branch_id is distinct from b.branch_id or eb.catalog_item_id is distinct from b.catalog_item_id or o.customer_id is distinct from b.customer_id or o.branch_id is distinct from b.branch_id or s.branch_id is distinct from b.branch_id or b.catalog_item_id is distinct from s.catalog_item_id or s.policy_snapshot->>'unit' is distinct from 'service_visits' or s.policy_snapshot->>'eligibility_basis' is distinct from 'booking_created_time' or coalesce((s.policy_snapshot->>'enabled')::boolean,false) is not true or not(s.policy_snapshot->'eligible_service_ids' @> to_jsonb(array[eb.catalog_item_id])) or (s.policy_snapshot->'target_customer_ids'<>'null'::jsonb and not(s.policy_snapshot->'target_customer_ids' @> to_jsonb(array[eb.customer_id]))) or (s.policy_snapshot->>'offer_starts_at' is not null and s.captured_at<(s.policy_snapshot->>'offer_starts_at')::timestamptz) or (s.policy_snapshot->>'offer_ends_at' is not null and s.captured_at>(s.policy_snapshot->>'offer_ends_at')::timestamptz) then return jsonb_build_object('eligible',false,'reason','snapshot_identity_mismatch');end if;
 select count(*) into n from public.business_orders where booking_id=b.id and order_type='service';
 if n<>1 then return jsonb_build_object('eligible',false,'reason','ambiguous_booking_orders');end if;
 if b.status<>'completed' or o.status not in ('completed','delivered') then return jsonb_build_object('eligible',false,'reason','awaiting_completed_booking_and_order');end if;
 select count(*) into n from public.business_invoices where order_id=o.order_id and status<>'void';
 if n<>1 then return jsonb_build_object('eligible',false,'reason','ambiguous_service_invoice');end if;
 select * into i from public.business_invoices where order_id=o.order_id and status<>'void';
 if i.sale_type<>'service' or i.branch_id<>o.branch_id or i.status<>'active' or i.total<=0 or i.total::text='NaN' or i.discount::text='NaN' or exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='refund') then return jsonb_build_object('eligible',false,'reason','invoice_not_active_or_refunded');end if;
 select * into p from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash';
 if p.payment_id is null or p.amount<>i.total or p.amount<=0 or p.amount::text='NaN' or not exists(select 1 from public.business_cashier_shifts where shift_id=p.shift_id and branch_id=i.branch_id) then return jsonb_build_object('eligible',false,'reason','awaiting_actual_full_cash_sale');end if;
 return jsonb_build_object('eligible',true,'reason','eligible','customer_id',o.customer_id,'order_id',o.order_id,'booking_id',b.id,'invoice_id',i.invoice_id,'sale_payment_id',p.payment_id,'sale_amount',p.amount,'branch_id',o.branch_id,'policy_version_id',s.policy_version_id,'activation_id',a.activation_id,'policy_snapshot',s.policy_snapshot,'invoice_total',i.total,'invoice_discount',i.discount,'invoice_commission_total',i.commission_total);
end $$;
revoke all on function private.evaluate_loyalty_visit(uuid) from public,anon,authenticated,service_role;
create function private.reconcile_loyalty_visit(p_order uuid) returns text language plpgsql security definer set search_path=pg_catalog as $$
declare e private.canonical_loyalty_visits;r public.business_payment_events;facts jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Visit reconciliation requires READ COMMITTED';end if;
 perform pg_advisory_xact_lock(hashtextextended('canonical-visit:'||p_order::text,0));
 select * into e from private.canonical_loyalty_visits where order_id=p_order and kind='earn';
 if e.id is not null then
 select * into r from public.business_payment_events where invoice_id=e.invoice_id and event_type='refund' and method='cash' and amount=(e.facts->>'sale_amount')::numeric;
 if r.payment_id is not null and exists(select 1 from public.business_cashier_shifts where shift_id=r.shift_id and branch_id=(e.facts->>'branch_id')::uuid) then
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,order_id,booking_id,invoice_id,sale_payment_id,refund_payment_id,activation_id,policy_version_id,reverses_earning,facts) values('refund',-1,e.branch_id,e.customer_id,e.order_id,e.booking_id,e.invoice_id,e.sale_payment_id,r.payment_id,e.activation_id,e.policy_version_id,e.id,jsonb_build_object('original_earning',e.id,'refund_payment_id',r.payment_id,'refund_amount',r.amount,'unit','service_visits')) on conflict(reverses_earning) where kind='refund' do nothing;
 return 'refunded';end if;
 return 'already_earned';end if;
 facts:=private.evaluate_loyalty_visit(p_order);
 if coalesce((facts->>'eligible')::boolean,false) is not true then return facts->>'reason';end if;
 insert into private.canonical_loyalty_visits(kind,visits,branch_id,customer_id,order_id,booking_id,invoice_id,sale_payment_id,activation_id,policy_version_id,facts) values('earn',1,(facts->>'branch_id')::uuid,(facts->>'customer_id')::uuid,p_order,(facts->>'booking_id')::uuid,facts->>'invoice_id',(facts->>'sale_payment_id')::uuid,(facts->>'activation_id')::uuid,(facts->>'policy_version_id')::uuid,facts) on conflict(order_id) where kind='earn' do nothing;
 -- A refund may have committed while FK checks waited for the invoice row.
 if exists(select 1 from public.business_payment_events where invoice_id=facts->>'invoice_id' and event_type='refund') then return private.reconcile_loyalty_visit(p_order);end if;
 return 'earned';
end $$;
revoke all on function private.reconcile_loyalty_visit(uuid) from public,anon,authenticated,service_role;
create function private.drain_loyalty_visit_event() returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare job private.loyalty_visit_outbox;oid uuid;orders uuid[];result text;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Visit drain requires READ COMMITTED';end if;
 -- Exactly one event/order per transaction. Never lock another worker's event.
 select * into job from private.loyalty_visit_outbox where processed_at is null and next_attempt_at<=clock_timestamp() order by next_attempt_at,created_at,event_id limit 1 for update skip locked;
 if job.event_id is null then return jsonb_build_object('processed',false);end if;
 begin
 oid:=job.order_id;
 if oid is null and job.invoice_id is not null then select order_id into oid from public.business_invoices where invoice_id=job.invoice_id;end if;
 if oid is null and job.booking_id is not null then
 select array_agg(order_id) into orders from public.business_orders where booking_id=job.booking_id and order_type='service';
 if cardinality(orders)=1 then oid:=orders[1];end if;end if;
 if oid is null then result:='canonical_order_not_resolved';else result:=private.reconcile_loyalty_visit(oid);end if;
 if result='scheduler_disabled' then
 update private.loyalty_visit_outbox set attempts=attempts+1,result_code=result,next_attempt_at=clock_timestamp()+interval '2 minutes' where event_id=job.event_id;return jsonb_build_object('processed',false,'retry',true,'result',result);end if;
 update private.loyalty_visit_outbox set processed_at=clock_timestamp(),result_code=result,attempts=attempts+1,last_error_code=null where event_id=job.event_id;
 return jsonb_build_object('processed',true,'result',result);
 exception when others then
 update private.loyalty_visit_outbox set attempts=attempts+1,last_error_code=sqlstate,next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,120*power(2,least(job.attempts,5)))::integer) where event_id=job.event_id;
 return jsonb_build_object('processed',false,'retry',true,'error_code',sqlstate);
 end;
end $$;
revoke all on function private.drain_loyalty_visit_event() from public,anon,authenticated;
grant execute on function private.drain_loyalty_visit_event() to service_role;
create function public.drain_loyalty_visit_event() returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$begin if current_user not in ('postgres','service_role') then raise exception 'System worker required' using errcode='42501';end if;return private.drain_loyalty_visit_event();end $$;
revoke all on function public.drain_loyalty_visit_event() from public,anon,authenticated;
grant execute on function public.drain_loyalty_visit_event() to service_role;
create function private.run_loyalty_visit_cron() returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$begin if current_user<>'postgres' then raise exception 'Postgres scheduler required' using errcode='42501';end if;if not pg_try_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0)) then return jsonb_build_object('processed',false,'busy',true);end if;return private.drain_loyalty_visit_event();end $$;
revoke all on function private.run_loyalty_visit_cron() from public,anon,authenticated,service_role;
create function private.enqueue_loyalty_visit_source() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare oid uuid;bid uuid;iid text;sid uuid:=gen_random_uuid();
begin
 if tg_table_schema='private' and tg_table_name='loyalty_earning_snapshot_bindings' then bid:=new.booking_id;sid:=new.booking_id;
 elsif tg_table_name='bookings' then bid:=new.id;if not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid) then return new;end if;
 elsif tg_table_name='business_orders' then if new.order_type<>'service' then return new;end if;oid:=new.order_id;bid:=new.booking_id;
 elsif tg_table_name='business_invoices' then oid:=new.order_id;iid:=new.invoice_id;select booking_id into bid from public.business_orders where order_id=oid;
 else sid:=new.payment_id;iid:=new.invoice_id;select order_id into oid from public.business_invoices where invoice_id=iid;select booking_id into bid from public.business_orders where order_id=oid;end if;
 if bid is null or not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=bid) then return new;end if;
 -- Distinct append-only events: never a mutable shared queue row per order.
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,booking_id,invoice_id) values(tg_table_name,sid,oid,bid,iid) on conflict(source_kind,source_id) do nothing;
 return new;
end $$;
revoke all on function private.enqueue_loyalty_visit_source() from public,anon,authenticated,service_role;
create function private.capture_loyalty_earning_binding() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare a private.loyalty_visit_activations;c uuid;
begin
 select customer_id into c from public.bookings where id=new.booking_id;
 select * into a from private.loyalty_visit_activations where policy_version_id=new.policy_version_id and activated_at<=new.captured_at;
 if a.activation_id is not null and c is not null then insert into private.loyalty_earning_snapshot_bindings(booking_id,activation_id,customer_id,branch_id,catalog_item_id) values(new.booking_id,a.activation_id,c,new.branch_id,new.catalog_item_id);end if;return new;
end $$;
revoke all on function private.capture_loyalty_earning_binding() from public,anon,authenticated,service_role;
create trigger capture_visible_visit_activation after insert on private.booking_loyalty_policy_snapshots for each row execute function private.capture_loyalty_earning_binding();
create trigger enqueue_visit_policy_capture after insert on private.loyalty_earning_snapshot_bindings for each row execute function private.enqueue_loyalty_visit_source();
create trigger enqueue_visit_booking_state after update of status on public.bookings for each row when(old.status is distinct from new.status) execute function private.enqueue_loyalty_visit_source();
create trigger enqueue_visit_order_state after insert or update of status,booking_id,customer_id,branch_id on public.business_orders for each row execute function private.enqueue_loyalty_visit_source();
create trigger enqueue_visit_invoice_state after insert or update of status,order_id on public.business_invoices for each row execute function private.enqueue_loyalty_visit_source();
create trigger enqueue_visit_payment after insert on public.business_payment_events for each row execute function private.enqueue_loyalty_visit_source();
create function private.get_loyalty_visit_lifecycle(p_branch uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;v private.loyalty_policy_versions;a private.loyalty_visit_activations;success timestamptz;
begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_active and (p_branch is null or branch_id=p_branch) order by is_default desc,branch_id limit 1;
 if b is null then raise exception 'Active branch required';end if;
 select * into v from private.loyalty_policy_versions where branch_id=b order by version_no desc limit 1;
 select * into a from private.loyalty_visit_activations where policy_version_id=v.version_id;
 success:=private.loyalty_visit_cron_last_success();
 return jsonb_build_object('branch_id',b,'unit','service_visits','policy_version_id',v.version_id,'current_policy_enabled',coalesce(v.enabled,false),'activation',case when a.activation_id is null then null else to_jsonb(a) end,
 'scheduler_ready',private.loyalty_visit_scheduler_ready(),'actual_cron_run_observed',coalesce(success>=clock_timestamp()-interval '5 minutes',false),'last_successful_cron_run_at',success,
 'pending_events',(select count(*) from private.loyalty_visit_outbox x join private.booking_loyalty_policy_snapshots s on s.booking_id=x.booking_id where x.processed_at is null and s.branch_id=b),
 'earned_visits',(select count(*) from private.canonical_loyalty_visits where branch_id=b and kind='earn'),'reversed_visits',(select count(*) from private.canonical_loyalty_visits where branch_id=b and kind='refund'),'net_visits',(select coalesce(sum(visits),0) from private.canonical_loyalty_visits where branch_id=b),'redemption_enabled',false,'legacy_imported',false);
end $$;
revoke all on function private.get_loyalty_visit_lifecycle(uuid) from public,anon;
grant execute on function private.get_loyalty_visit_lifecycle(uuid) to authenticated;
create function public.get_loyalty_visit_lifecycle(p_branch uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_loyalty_visit_lifecycle(p_branch)$$;
revoke all on function public.get_loyalty_visit_lifecycle(uuid) from public,anon;
grant execute on function public.get_loyalty_visit_lifecycle(uuid) to authenticated;
create function private.get_my_canonical_service_visits() returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null then raise exception 'Authentication required' using errcode='42501';end if;
 return jsonb_build_object('unit','service_visits','earned_visits',(select count(*) from private.canonical_loyalty_visits where customer_id=auth.uid() and kind='earn'),'reversed_visits',(select count(*) from private.canonical_loyalty_visits where customer_id=auth.uid() and kind='refund'),'net_visits',(select coalesce(sum(visits),0) from private.canonical_loyalty_visits where customer_id=auth.uid()),'redemption_enabled',false,'legacy_imported',false);
end $$;
revoke all on function private.get_my_canonical_service_visits() from public,anon;
grant execute on function private.get_my_canonical_service_visits() to authenticated;
create function public.get_my_canonical_service_visits() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_my_canonical_service_visits()$$;
revoke all on function public.get_my_canonical_service_visits() from public,anon;
grant execute on function public.get_my_canonical_service_visits() to authenticated;
notify pgrst,'reload schema';
commit;
