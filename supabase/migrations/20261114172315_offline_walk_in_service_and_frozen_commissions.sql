begin;
-- Received offline service only. Work start/completion and all loyalty remain fenced.
create table private.offline_walk_in_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),prepared_by uuid not null references auth.users(id),executed_by uuid references auth.users(id),branch_id uuid references public.business_branches(branch_id),
 payload jsonb not null,financial_snapshot jsonb,state text not null check(state in('prepared','succeeded','closed')),result jsonb,
 order_id uuid unique references public.business_orders(order_id),created_at timestamptz not null default clock_timestamp(),resolved_at timestamptz,acknowledged_at timestamptz);
create unique index one_unresolved_offline_walk_in on private.offline_walk_in_commands(actor_id)where acknowledged_at is null;
create table private.offline_walk_in_subjects(
 order_id uuid primary key references public.business_orders(order_id)deferrable initially deferred,invoice_id text not null unique references public.business_invoices(invoice_id)deferrable initially deferred,
 command_id uuid not null unique references private.offline_walk_in_commands(request_id),registration_request_id uuid not null references private.offline_customer_registration_requests(request_id),
 profile_id uuid not null references private.offline_customer_profiles(profile_id),car_ref_id uuid not null references private.offline_customer_car_refs(car_ref_id),
 branch_id uuid not null references public.business_branches(branch_id),service_id uuid not null references public.business_catalog_items(item_id),
 gross numeric(12,2)not null check(gross>0),duration_minutes integer not null check(duration_minutes between 5 and 480),resource_key text not null,
 staff_ids uuid[]not null check(cardinality(staff_ids)>0),consent_hash text not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp());
create table private.offline_walk_in_commissions(
 invoice_id text not null references private.offline_walk_in_subjects(invoice_id),staff_id uuid not null references public.staff_profiles(user_id),staff_name text not null,
 rate_percent numeric(7,4)not null check(rate_percent between 0 and 100),assigned_count integer not null check(assigned_count>0),gross numeric(12,2)not null,
 amount numeric(12,2)not null,employment_snapshot jsonb not null,primary key(invoice_id,staff_id),check(amount=round(gross*rate_percent/100/assigned_count,2)));
create table private.offline_walk_in_reception(order_id uuid primary key references private.offline_walk_in_subjects(order_id),branch_id uuid not null references public.business_branches(branch_id),arrived_at timestamptz not null default clock_timestamp(),priority text not null default 'normal'check(priority='normal'));
create table private.offline_walk_in_events(event_id uuid primary key default gen_random_uuid(),request_id uuid not null,actor_id uuid not null references auth.users(id),action text not null,payload jsonb not null,result jsonb not null,creator_xid bigint not null,created_at timestamptz not null default clock_timestamp(),unique(request_id,action));
do $$declare v_t text;begin foreach v_t in array array['offline_walk_in_commands','offline_walk_in_subjects','offline_walk_in_commissions','offline_walk_in_reception','offline_walk_in_events']loop
 execute format('alter table private.%I enable row level security',v_t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',v_t);
 if v_t<>'offline_walk_in_commands'then execute format('create trigger immutable_offline_walk_in before update or delete on private.%I for each row execute function private.immutable_loyalty_policy()',v_t);end if;end loop;end$$;
alter table public.business_invoices add column commission_model text not null default 'legacy_scalar'check(commission_model in('legacy_scalar','walk_in_frozen_workers'));
alter table public.business_invoices alter column commission_share drop not null;
alter table public.business_invoices add constraint legacy_invoice_share_required check(commission_model='walk_in_frozen_workers'or commission_share is not null);
create function private.guard_offline_walk_in_command()returns trigger language plpgsql set search_path=pg_catalog as $$begin
 if tg_op='DELETE'then raise exception 'Walk-in command history is retained'using errcode='55000';end if;
 if(to_jsonb(new)-array['state','result','order_id','executed_by','resolved_at','acknowledged_at'])is distinct from(to_jsonb(old)-array['state','result','order_id','executed_by','resolved_at','acknowledged_at'])then raise exception 'Prepared walk-in payload and actors are immutable'using errcode='55000';end if;
 if old.state='prepared'and new.state in('succeeded','closed')then
  if new.resolved_at is null or new.acknowledged_at is not null or(old.state='prepared'and old.resolved_at is not null)then raise exception 'Invalid final resolution'using errcode='55000';end if;
  if new.state='succeeded'and(new.executed_by is distinct from auth.uid()or(new.executed_by is distinct from new.actor_id and private.active_staff_role()is distinct from'owner')or new.order_id is null or new.result->>'order_id'is distinct from new.order_id::text or not exists(select 1 from private.offline_walk_in_subjects where order_id=new.order_id and command_id=new.request_id))then raise exception 'Actual canonical order proof required'using errcode='55000';end if;
  if new.state='closed'and(new.executed_by is not null or new.order_id is not null or new.result is distinct from '{"status":"closed"}'::jsonb)then raise exception 'Closed commands cannot have a created order'using errcode='55000';end if;
 elsif new.state=old.state and old.state in('succeeded','closed')and new.result is not distinct from old.result and new.order_id is not distinct from old.order_id and new.resolved_at is not distinct from old.resolved_at and new.executed_by is not distinct from old.executed_by then
  if old.acknowledged_at is not null and new.acknowledged_at is distinct from old.acknowledged_at then raise exception 'Acknowledgment is immutable'using errcode='55000';end if;
 else raise exception 'Resolved command cannot reopen or change identity'using errcode='55000';end if;
 return new;
end$$;
revoke all on function private.guard_offline_walk_in_command()from public,anon,authenticated,service_role;
create trigger guard_offline_walk_in_command before update or delete on private.offline_walk_in_commands for each row execute function private.guard_offline_walk_in_command();
create function private.offline_walk_in_flags()returns jsonb language sql immutable set search_path=pg_catalog as $$select '{"auth_customer_subject_supported":false,"walk_in_loyalty_accrual":false,"points_enabled":false,"redemption_enabled":false,"linked_history_visible":false,"work_start_supported":false}'::jsonb$$;
create function private.offline_walk_in_cashier(p_actor uuid,p_branch uuid)returns boolean language sql stable security definer set search_path=pg_catalog as $$select exists(select 1 from public.staff_profiles s where s.user_id=p_actor and s.is_active and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=p_branch)and(s.role='manager'or s.role='employee'and s.permissions->>'cashier'='true')))$$;
create function private.guard_offline_walk_in_finance()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_s private.offline_walk_in_subjects;v_total numeric;v_share numeric;v_rates integer;v_ids uuid[];v_workers jsonb;begin
 if tg_op='DELETE'then
  if tg_table_name='business_orders'then
   if exists(select 1 from private.offline_walk_in_subjects where order_id=old.order_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  else
   if exists(select 1 from private.offline_walk_in_subjects where invoice_id=old.invoice_id)then raise exception 'Walk-in financial history is retained'using errcode='55000';end if;
  end if;return old;
 end if;
 if tg_table_name='business_orders'then
  select * into v_s from private.offline_walk_in_subjects where order_id=new.order_id;
  if not found then return new;end if;
  if new.customer_id is not null or new.booking_id is not null or new.order_type<>'service'or new.branch_id<>v_s.branch_id or new.assigned_staff_ids<>v_s.staff_ids then raise exception 'Typed offline subject/assignment mismatch'using errcode='55000';end if;
  if tg_op='INSERT'then
   if new.status<>'received'or v_s.creator_xid<>txid_current()then raise exception 'Only canonical received creation supported'using errcode='55000';end if;
  else
   if new.order_number is distinct from old.order_number and not(v_s.creator_xid=txid_current()and old.order_number=v_s.invoice_id and new.order_number=(select display_number from public.business_invoices where invoice_id=v_s.invoice_id))then raise exception 'Issued work reference is immutable'using errcode='55000';end if;
   if(to_jsonb(new)-array['status','updated_at','order_number'])is distinct from(to_jsonb(old)-array['status','updated_at','order_number'])then raise exception 'Issued walk-in identity and assignment are immutable'using errcode='55000';end if;
   if new.status is distinct from old.status and not(old.status='received'and new.status='cancelled'and exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=new.order_id::text))then raise exception 'Walk-in work start/completion unavailable until shared capacity adapter'using errcode='55000';end if;
  end if;return new;
 end if;
 select * into v_s from private.offline_walk_in_subjects where invoice_id=new.invoice_id;
 if not found then
  if exists(select 1 from private.offline_walk_in_subjects where order_id=new.order_id)then raise exception 'Typed work already has its canonical invoice'using errcode='55000';end if;
  if new.commission_model<>'legacy_scalar'or new.commission_share is null then raise exception 'Typed commission requires canonical sidecar proof'using errcode='55000';end if;return new;
 end if;
 select sum(c.amount),case when count(distinct c.rate_percent)=1 then min(c.amount)end,count(distinct c.rate_percent),array_agg(c.staff_id order by c.staff_id),jsonb_agg(c.staff_name order by c.staff_id)
 into v_total,v_share,v_rates,v_ids,v_workers from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id;
 if new.commission_model<>'walk_in_frozen_workers'or new.order_id is distinct from v_s.order_id or new.branch_id<>v_s.branch_id or new.total<>v_s.gross or new.discount<>0 or new.sale_type<>'service'or new.reward_snapshot is not null or new.commission_total is distinct from v_total or new.commission_share is distinct from v_share or v_ids is distinct from v_s.staff_ids or new.workers is distinct from v_workers or exists(select 1 from private.offline_walk_in_commissions c where c.invoice_id=new.invoice_id and(c.gross<>v_s.gross or c.assigned_count<>cardinality(v_s.staff_ids)))then raise exception 'Complete truthful frozen worker commission proof required'using errcode='55000';end if;
 if tg_op='INSERT'and v_s.creator_xid<>txid_current()then raise exception 'Invoice must be issued with new canonical proof'using errcode='55000';end if;
 if tg_op='UPDATE'then
  if(to_jsonb(new)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])is distinct from(to_jsonb(old)-array['status','payment_method','document_snapshot','document_origin','document_link_enabled'])then raise exception 'Issued walk-in finance and commission facts are immutable'using errcode='55000';end if;
  if new.status='void'and old.status<>'void'and not exists(select 1 from private.offline_walk_in_events e where e.action='cancel'and e.creator_xid=txid_current()and e.result->>'order_id'=v_s.order_id::text)then raise exception 'Use canonical unpaid cancellation'using errcode='55000';end if;
 end if;return new;
end$$;
create trigger guard_offline_walk_in_order before insert or update or delete on public.business_orders for each row execute function private.guard_offline_walk_in_finance();
create trigger guard_offline_walk_in_invoice before insert or update or delete on public.business_invoices for each row execute function private.guard_offline_walk_in_finance();
create function private.guard_offline_walk_in_line()returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare v_s private.offline_walk_in_subjects;begin
 if tg_op='DELETE'then select * into v_s from private.offline_walk_in_subjects where order_id=old.order_id;
 else select * into v_s from private.offline_walk_in_subjects where order_id=new.order_id;end if;
 if v_s.order_id is null then if tg_op='DELETE'then return old;else return new;end if;end if;
 if tg_op<>'INSERT'then raise exception 'Typed issued service line is immutable'using errcode='55000';end if;
 if v_s.creator_xid<>txid_current()or new.item_id is distinct from v_s.service_id or new.quantity<>1 or new.unit_price<>v_s.gross or new.subtotal<>v_s.gross or exists(select 1 from public.business_order_items where order_id=new.order_id)then raise exception 'Exactly one actual canonical service line required'using errcode='55000';end if;return new;
end$$;
revoke all on function private.guard_offline_walk_in_line()from public,anon,authenticated,service_role;
create trigger guard_offline_walk_in_line before insert or update or delete on public.business_order_items for each row execute function private.guard_offline_walk_in_line();
create function private.walk_in_service_facts(p_registration uuid,p_service uuid,p_expected_price numeric,p_staff_ids uuid[],p_cashier uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_r private.offline_customer_registration_requests;v_p private.offline_customer_profiles;v_car private.offline_customer_car_refs;v_service public.business_catalog_items;v_b public.business_branches;v_h public.business_branch_hours;v_e public.business_branch_exceptions;v_now timestamp:=clock_timestamp()at time zone'Africa/Cairo';v_open time;v_close time;v_staff uuid[];v_lines jsonb;v_n integer;begin
 select * into v_r from private.offline_customer_registration_requests where request_id=p_registration;
 if not found or v_r.actor_id<>p_cashier or v_r.result->>'status'not in('created_unverified','reused_unverified')or not coalesce(private.can_access_branch(v_r.branch_id),false)or not private.offline_walk_in_cashier(p_cashier,v_r.branch_id)then raise exception 'Authorized same-cashier branch intake receipt required'using errcode='42501';end if;
 select * into v_p from private.offline_customer_profiles where profile_id=(v_r.result->>'offline_profile_id')::uuid and created_branch_id=v_r.branch_id;
 select * into v_car from private.offline_customer_car_refs where car_ref_id=(v_r.result->>'car_ref_id')::uuid and profile_id=v_p.profile_id;
 if v_p.profile_id is null or v_car.car_ref_id is null then raise exception 'Actual intake profile and car binding required'using errcode='55000';end if;
 select * into v_b from public.business_branches where branch_id=v_r.branch_id for share;
 if not v_b.is_active or v_b.temporarily_closed or v_b.currency<>'EGP'then raise exception 'Active EGP branch required'using errcode='55000';end if;
 select * into v_service from public.business_catalog_items where item_id=p_service and branch_id=v_b.branch_id and item_type='service'and is_active and is_public and name!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'for share;
 if not found or v_service.price<=0 or v_service.price::text in('NaN','Infinity','-Infinity')then raise exception 'Supported actual positive-price service required'using errcode='22023';end if;
 if v_service.price is distinct from p_expected_price then raise exception 'Service price changed; close this preparation and refresh'using errcode='40001';end if;
 select * into v_h from public.business_branch_hours where branch_id=v_b.branch_id and weekday=extract(dow from v_now)::integer;
 if not found then raise exception 'Configured branch hours required'using errcode='55000';end if;
 v_open:=v_h.opens_at;v_close:=v_h.closes_at;
 select * into v_e from public.business_branch_exceptions where branch_id=v_b.branch_id and exception_date=v_now::date;
 if found then if v_e.is_closed then raise exception 'Branch closed today'using errcode='55000';end if;v_open:=v_e.opens_at;v_close:=v_e.closes_at;
 elsif not v_h.is_open then raise exception 'Branch closed today'using errcode='55000';end if;
 if v_now::time<v_open or v_now+make_interval(mins=>v_service.duration_minutes)>v_now::date+v_close then raise exception 'Reception service outside configured hours'using errcode='55000';end if;
 if p_staff_ids is null or cardinality(p_staff_ids)not between 1 and 20 or array_position(p_staff_ids,null)is not null then raise exception 'Explicit assigned workers required'using errcode='22023';end if;
 select array_agg(x order by x),count(*)into v_staff,v_n from(select distinct unnest(p_staff_ids)x)s;
 if v_n<>cardinality(p_staff_ids)then raise exception 'Duplicate assigned worker'using errcode='22023';end if;
 perform 1 from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.user_id=any(v_staff)order by s.user_id for share of s,e;
 select jsonb_agg(jsonb_build_object('staff_id',s.user_id,'staff_name',s.full_name,'rate_percent',e.commission_percent,'assigned_count',v_n,'gross',v_service.price,'amount',round(v_service.price*e.commission_percent/100/v_n,2),'employment_snapshot',to_jsonb(e))order by s.user_id)into v_lines
 from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.user_id=any(v_staff)and s.is_active and e.currency='EGP'and e.starts_on<=v_now::date and(e.ends_on is null or e.ends_on>=v_now::date)and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=v_b.branch_id);
 if coalesce(jsonb_array_length(v_lines),0)<>v_n then raise exception 'Every assigned branch worker needs actual current EGP employment'using errcode='55000';end if;
 return jsonb_build_object('branch_id',v_b.branch_id,'profile_id',v_p.profile_id,'car_ref_id',v_car.car_ref_id,'customer_name',v_p.full_name,'customer_phone',v_r.payload->>'phone','plate_number',v_car.plate_key,'consent_hash',v_r.consent_hash,'service_id',v_service.item_id,'service_name',v_service.name,'vehicle_type',v_service.vehicle_type,'gross',v_service.price,'duration_minutes',v_service.duration_minutes,'resource_key',v_service.resource_key,'staff_ids',to_jsonb(v_staff),'lines',v_lines);
end$$;
create function private.get_offline_walk_in_command(p_request uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.offline_walk_in_commands;v_result jsonb;v_quote jsonb;v_work text;v_invoice text;begin
 if auth.uid()is null or not exists(select 1 from public.business_branches b where private.offline_walk_in_cashier(auth.uid(),b.branch_id))then raise exception 'Active cashier account required'using errcode='42501';end if;
 if p_request is null then select * into v_c from private.offline_walk_in_commands where(actor_id=auth.uid()or(executed_by=auth.uid()and private.active_staff_role()='owner'))and acknowledged_at is null order by case when state='prepared'then 0 else 1 end,created_at desc limit 1;
 else select * into v_c from private.offline_walk_in_commands where request_id=p_request;end if;
 if v_c.request_id is null then return jsonb_build_object('status','absent','definitive_failure',false,'capabilities',private.offline_walk_in_flags());end if;
 if(v_c.actor_id<>auth.uid()and v_c.prepared_by<>auth.uid()and private.active_staff_role()is distinct from'owner')or(v_c.branch_id is not null and not coalesce(private.can_access_branch(v_c.branch_id),false))then raise exception 'Walk-in command unavailable'using errcode='42501';end if;
 v_result:=v_c.result;
 if v_c.state='succeeded'then
  select o.status,i.status into strict v_work,v_invoice from public.business_orders o join private.offline_walk_in_subjects ws on ws.order_id=o.order_id join public.business_invoices i on i.invoice_id=ws.invoice_id where o.order_id=v_c.order_id;
  v_quote:=private.invoice_payment_quote(v_c.result->>'invoice_id');
  -- Stored creation receipt is immutable; recovery overlays current canonical states.
  v_result:=v_c.result||jsonb_build_object('work_status',v_work,'invoice_status',v_invoice,'payment_status',v_quote->>'payment_status','collectible',(v_quote->>'collectible')::boolean,'collectible_amount',case when(v_quote->>'collectible')::boolean then(v_quote->>'amount_due')::numeric else 0 end);
 end if;
 return jsonb_build_object('request_id',v_c.request_id,'status',v_c.state,'payload',v_c.payload,'result',v_result,'executed_by',v_c.executed_by,'acknowledged',v_c.acknowledged_at is not null,'capabilities',private.offline_walk_in_flags());
end$$;
create function private.prepare_offline_walk_in(p_request uuid,p_registration uuid,p_service uuid,p_expected_price numeric,p_cashier uuid,p_staff_ids uuid[],p_notes text default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_prior private.offline_walk_in_commands;v_facts jsonb;v_payload jsonb;v_staff uuid[];begin
 if auth.uid()is null or private.active_staff_role()not in('owner','manager')or private.active_staff_role()is null then raise exception 'Active owner or branch manager required to assign workers'using errcode='42501';end if;
 if p_request is null or p_cashier is null or p_registration is null or p_service is null or p_expected_price is null or length(coalesce(p_notes,''))>1000 then raise exception 'Stable actual service preparation required'using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Walk-in requires READ COMMITTED'using errcode='55000';end if;perform set_config('lock_timeout','20s',true);
 select array_agg(x order by x)into v_staff from unnest(p_staff_ids)x;
 v_payload:=jsonb_build_object('registration_request_id',p_registration,'service_id',p_service,'expected_price',p_expected_price,'cashier_id',p_cashier,'staff_ids',to_jsonb(v_staff),'notes',nullif(trim(p_notes),''));
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));perform pg_advisory_xact_lock(hashtextextended('offline-walkin-actor:'||p_cashier::text,0));
 select * into v_prior from private.offline_walk_in_commands where request_id=p_request;
 if found then
  if v_prior.prepared_by<>auth.uid()or v_prior.actor_id<>p_cashier then raise exception 'Preparation receipt unavailable'using errcode='42501';end if;
  if v_prior.payload<>v_payload then raise exception 'Preparation payload changed'using errcode='22023';end if;return private.get_offline_walk_in_command(p_request);
 end if;
 v_facts:=private.walk_in_service_facts(p_registration,p_service,p_expected_price,p_staff_ids,p_cashier);
 insert into private.offline_walk_in_commands(request_id,actor_id,prepared_by,branch_id,payload,financial_snapshot,state)values(p_request,p_cashier,auth.uid(),(v_facts->>'branch_id')::uuid,v_payload,v_facts,'prepared');
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,auth.uid(),'prepare',v_payload,jsonb_build_object('status','prepared','bound_cashier',p_cashier),txid_current());
 return private.get_offline_walk_in_command(p_request);
end$$;
create function private.place_offline_walk_in(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.offline_walk_in_commands;v_f jsonb;v_oid uuid:=gen_random_uuid();v_iid text;v_i public.business_invoices;v_staff uuid[];v_total numeric;v_share numeric;v_workers jsonb;v_result jsonb;begin
 if auth.uid()is null then raise exception 'Cashier required'using errcode='42501';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Walk-in requires READ COMMITTED'using errcode='55000';end if;perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 select * into v_c from private.offline_walk_in_commands where request_id=p_request;
 if not found or not private.offline_walk_in_cashier(auth.uid(),v_c.branch_id)or(v_c.actor_id<>auth.uid()and private.active_staff_role()is distinct from'owner')then raise exception 'Authorized bound cashier command required'using errcode='42501';end if;
 if v_c.state='succeeded'then return private.get_offline_walk_in_command(p_request);end if;
 if v_c.state<>'prepared'then raise exception 'Command is closed; delayed placement is fenced'using errcode='55000';end if;
 select array_agg(value::uuid order by value::uuid)into v_staff from jsonb_array_elements_text(v_c.payload->'staff_ids');
 v_f:=private.walk_in_service_facts((v_c.payload->>'registration_request_id')::uuid,(v_c.payload->>'service_id')::uuid,(v_c.payload->>'expected_price')::numeric,v_staff,v_c.actor_id);
 if v_f is distinct from v_c.financial_snapshot then raise exception 'Price, worker rate/version or intake changed; close preparation and refresh'using errcode='40001';end if;
 v_iid:='WALKIN-'||v_oid::text;
 insert into private.offline_walk_in_subjects(order_id,invoice_id,command_id,registration_request_id,profile_id,car_ref_id,branch_id,service_id,gross,duration_minutes,resource_key,staff_ids,consent_hash,creator_xid)
 values(v_oid,v_iid,p_request,(v_c.payload->>'registration_request_id')::uuid,(v_f->>'profile_id')::uuid,(v_f->>'car_ref_id')::uuid,v_c.branch_id,(v_f->>'service_id')::uuid,(v_f->>'gross')::numeric,(v_f->>'duration_minutes')::integer,v_f->>'resource_key',v_staff,v_f->>'consent_hash',txid_current());
 insert into private.offline_walk_in_commissions(invoice_id,staff_id,staff_name,rate_percent,assigned_count,gross,amount,employment_snapshot)
 select v_iid,(x->>'staff_id')::uuid,x->>'staff_name',(x->>'rate_percent')::numeric,(x->>'assigned_count')::integer,(x->>'gross')::numeric,(x->>'amount')::numeric,x->'employment_snapshot'from jsonb_array_elements(v_f->'lines')x;
 select sum(amount),case when count(distinct rate_percent)=1 then min(amount)end,jsonb_agg(staff_name order by staff_id)into v_total,v_share,v_workers from private.offline_walk_in_commissions where invoice_id=v_iid;
 insert into public.business_orders(order_id,order_number,branch_id,customer_id,booking_id,customer_name,customer_phone,plate_number,vehicle_type,service_name,order_type,status,assigned_staff_ids,assigned_workers,created_by,notes)
 values(v_oid,v_iid,v_c.branch_id,null,null,v_f->>'customer_name',v_f->>'customer_phone',v_f->>'plate_number',v_f->>'vehicle_type',v_f->>'service_name','service','received',v_staff,v_workers,'offline_walk_in',v_c.payload->>'notes');
 insert into public.business_order_items(order_id,item_id,item_name,quantity,unit_price,subtotal)values(v_oid,(v_f->>'service_id')::uuid,v_f->>'service_name',1,(v_f->>'gross')::numeric,(v_f->>'gross')::numeric);
 insert into private.offline_walk_in_reception(order_id,branch_id)values(v_oid,v_c.branch_id);
 insert into public.business_invoices(invoice_id,order_id,branch_id,plate_number,service_name,vehicle_type,total,discount,sale_type,payment_method,commission_model,commission_total,commission_share,workers,created_by)
 values(v_iid,v_oid,v_c.branch_id,v_f->>'plate_number',v_f->>'service_name',v_f->>'vehicle_type',(v_f->>'gross')::numeric,0,'service','cash_on_receipt','walk_in_frozen_workers',v_total,v_share,v_workers,'offline_walk_in')returning * into v_i;
 update public.business_orders set order_number=v_i.display_number where order_id=v_oid;
 -- Shared sequential invoice reference is the actual short work/order reference too.
 v_result:=jsonb_build_object('order_id',v_oid,'invoice_id',v_iid,'work_reference',v_i.display_number,'invoice_number',v_i.display_number,'invoice_token',v_i.document_token,'amount_due',v_i.total,'gross_amount',v_i.total,'currency','EGP','work_status','received','payment_status','unpaid','capabilities',private.offline_walk_in_flags());
 update private.offline_walk_in_commands set state='succeeded',order_id=v_oid,executed_by=auth.uid(),result=v_result,resolved_at=clock_timestamp()where request_id=p_request;
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,auth.uid(),'place',jsonb_build_object('bound_cashier',v_c.actor_id,'executed_by_owner',v_c.actor_id<>auth.uid()),v_result,txid_current());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data)values(auth.uid()::text,auth.uid(),'offline_walk_in_received','business_orders',v_oid::text,v_c.branch_id,v_result||jsonb_build_object('bound_cashier',v_c.actor_id));
 return private.get_offline_walk_in_command(p_request);
end$$;
create function private.close_offline_walk_in_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.offline_walk_in_commands;begin
 if auth.uid()is null or not exists(select 1 from public.business_branches b where private.offline_walk_in_cashier(auth.uid(),b.branch_id))then raise exception 'Active cashier required'using errcode='42501';end if;
 if p_request is null then raise exception 'Stable command required'using errcode='22023';end if;perform set_config('lock_timeout','20s',true);
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 select * into v_c from private.offline_walk_in_commands where request_id=p_request;
 if not found then
  perform pg_advisory_xact_lock(hashtextextended('offline-walkin-actor:'||auth.uid()::text,0));
  insert into private.offline_walk_in_commands(request_id,actor_id,prepared_by,payload,state,result,resolved_at)values(p_request,auth.uid(),auth.uid(),'{}','closed','{"status":"closed"}',clock_timestamp());
 elsif(v_c.actor_id<>auth.uid()and v_c.prepared_by<>auth.uid()and private.active_staff_role()is distinct from'owner')or(v_c.branch_id is not null and not coalesce(private.can_access_branch(v_c.branch_id),false))then raise exception 'Command unavailable'using errcode='42501';
 elsif v_c.state='prepared'then update private.offline_walk_in_commands set state='closed',result='{"status":"closed"}',resolved_at=clock_timestamp()where request_id=p_request;
 end if;
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,auth.uid(),'close','{}',jsonb_build_object('status',coalesce((select state from private.offline_walk_in_commands where request_id=p_request),'closed')),txid_current())on conflict(request_id,action)do nothing;
 return private.get_offline_walk_in_command(p_request);
end$$;
create function private.ack_offline_walk_in_command(p_request uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_c private.offline_walk_in_commands;begin
 perform set_config('lock_timeout','20s',true);perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 select * into v_c from private.offline_walk_in_commands where request_id=p_request;
 if not found or(v_c.actor_id is distinct from auth.uid()and not coalesce(v_c.executed_by=auth.uid()and private.active_staff_role()='owner',false))or not exists(select 1 from public.business_branches b where private.offline_walk_in_cashier(auth.uid(),b.branch_id))or(v_c.branch_id is not null and not coalesce(private.can_access_branch(v_c.branch_id),false))then raise exception 'Bound cashier or actual active owner executor final receipt required'using errcode='42501';end if;
 if v_c.state='prepared'then raise exception 'Cannot acknowledge unresolved preparation'using errcode='55000';end if;
 update private.offline_walk_in_commands set acknowledged_at=coalesce(acknowledged_at,clock_timestamp())where request_id=p_request;
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,auth.uid(),'ack','{}',jsonb_build_object('state',v_c.state),txid_current())on conflict(request_id,action)do nothing;
 return private.get_offline_walk_in_command(p_request);
end$$;
create function private.cancel_offline_walk_in(p_request uuid,p_order uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_s private.offline_walk_in_subjects;v_o public.business_orders;v_i public.business_invoices;v_old private.offline_walk_in_events;v_payload jsonb;v_result jsonb;begin
 if p_request is null or p_order is null or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Stable cancellation and actual reason required'using errcode='22023';end if;
 select * into v_s from private.offline_walk_in_subjects where order_id=p_order;
 if not found or not coalesce(private.can_cashier_branch(v_s.branch_id),false)or private.active_staff_role()is null or private.active_staff_role()not in('owner','manager')then raise exception 'Authorized branch manager required for cancellation'using errcode='42501';end if;
 perform set_config('lock_timeout','20s',true);perform pg_advisory_xact_lock(hashtextextended('offline-walkin-cancel:'||p_request::text,0));
 v_payload:=jsonb_build_object('order_id',p_order,'reason',trim(p_reason));select * into v_old from private.offline_walk_in_events where request_id=p_request and action='cancel';
 if found then
  if v_old.actor_id<>auth.uid()then raise exception 'Cancellation receipt unavailable'using errcode='42501';end if;
  if v_old.payload<>v_payload then raise exception 'Cancellation payload changed'using errcode='22023';end if;return v_old.result;
 end if;
 select * into v_o from public.business_orders where order_id=p_order for update;
 -- Never take a cashier shift lock after order/invoice; existing sale takes shift→invoice.
 select * into v_i from public.business_invoices where invoice_id=v_s.invoice_id for update;
 if v_o.status<>'received'or v_i.status<>'active'or exists(select 1 from public.business_payment_events where invoice_id=v_s.invoice_id)or exists(select 1 from private.paymob_intents where invoice_id=v_s.invoice_id and status in('creating','pending','uncertain','sandbox_succeeded','refund_reported'))then raise exception 'Only received unpaid work without unresolved payment may cancel; management required otherwise'using errcode='55000';end if;
 v_result:=jsonb_build_object('order_id',p_order,'invoice_id',v_i.invoice_id,'work_reference',v_i.display_number,'work_status','cancelled','invoice_status','void','capabilities',private.offline_walk_in_flags());
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)values(p_request,auth.uid(),'cancel',v_payload,v_result,txid_current());
 update public.business_orders set status='cancelled'where order_id=p_order;update public.business_invoices set status='void'where invoice_id=v_i.invoice_id;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data)values(auth.uid()::text,auth.uid(),'offline_walk_in_cancel','business_orders',p_order::text,v_s.branch_id,trim(p_reason),jsonb_build_object('work_status',v_o.status,'invoice_status',v_i.status),v_result);
 return v_result;
end$$;
create function private.list_offline_walk_in_reception(p_branch uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 if auth.uid()is null or not coalesce(private.can_access_branch(p_branch),false)or private.active_staff_role()not in('owner','manager','employee')or private.active_staff_role()is null then raise exception 'Active branch staff required'using errcode='42501';end if;
 return coalesce((select jsonb_agg(v.item order by v.arrived_at)from(select r.arrived_at,jsonb_build_object('source_kind','walk_in','order_id',o.order_id,'work_reference',i.display_number,'invoice_id',i.invoice_id,'invoice_token',case when private.can_cashier_branch(p_branch)then i.document_token end,'branch_id',s.branch_id,'service_name',o.service_name,'plate_number',o.plate_number,'status',o.status,'arrived_at',r.arrived_at,'priority',r.priority,'amount_due',i.total,'capabilities',private.offline_walk_in_flags())item
 from private.offline_walk_in_subjects s join public.business_orders o using(order_id)join private.offline_walk_in_reception r using(order_id)join public.business_invoices i on i.invoice_id=s.invoice_id
 where s.branch_id=p_branch and o.status='received'and(r.arrived_at at time zone'Africa/Cairo')::date=(clock_timestamp()at time zone'Africa/Cairo')::date and(private.active_staff_role()in('owner','manager')or auth.uid()=any(o.assigned_staff_ids)or private.can_cashier_branch(p_branch)))v),'[]'::jsonb);
end$$;
-- Private immutable snapshots and all entry points remain inaccessible directly to clients.
revoke all on function private.offline_walk_in_flags(),private.offline_walk_in_cashier(uuid,uuid),private.guard_offline_walk_in_finance(),private.walk_in_service_facts(uuid,uuid,numeric,uuid[],uuid)from public,anon,authenticated,service_role;

-- Existing legacy replay remains ahead of typed-source exclusion.
create or replace function public.finalize_service_loyalty(
    p_customer_id uuid,
    p_order_id uuid,
    p_invoice_id text
)
returns table (reward_applied boolean, points_balance bigint)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
    v_offer_id uuid;
    v_visits_required integer;
    v_balance bigint;
    v_invoice_total numeric(12, 2);
begin
    if p_customer_id is null or p_order_id is null or p_invoice_id is null then
        raise exception 'Customer, order, and invoice are required';
    end if;
    perform 1 from public.customers where id = p_customer_id for update;
    if not found then
        raise exception 'Customer not found';
    end if;
    if not exists (
        select 1 from public.business_orders
        where order_id = p_order_id and customer_id = p_customer_id
    ) then
        raise exception 'Order does not belong to this customer';
    end if;
    if exists (
        select 1 from public.business_loyalty_transactions t
        where t.customer_id = p_customer_id and t.order_id = p_order_id
          and t.reason in ('Completed service visit', 'Wash reward redeemed')
    ) then
        if exists (
            select 1 from public.business_loyalty_transactions t
            where t.customer_id = p_customer_id and t.order_id = p_order_id
              and t.reason = 'Wash reward redeemed'
        ) then
            update public.business_invoices
            set discount = discount + total, total = 0
            where invoice_id = p_invoice_id and order_id = p_order_id and total > 0;
        end if;
        select coalesce(sum(t.points), 0) into v_balance
        from public.business_loyalty_transactions t where t.customer_id = p_customer_id;
        return query select exists (
            select 1 from public.business_loyalty_transactions t
            where t.customer_id = p_customer_id and t.order_id = p_order_id
              and t.reason = 'Wash reward redeemed'
        ), v_balance;
        return;
    end if;
    select coalesce(sum(t.points), 0) into v_balance
    from public.business_loyalty_transactions t where t.customer_id = p_customer_id;
    -- Preserve old receipts above; new canonical orders must never fall back to
    -- an unrelated unmanaged/global legacy offer or import the legacy balance.
    if exists(select 1 from public.business_invoices where invoice_id=p_invoice_id and order_id=p_order_id)
      and (coalesce(private.reward_invoice_coverage(p_invoice_id)->>'state' in ('covered_by_reward','cancelled_reward'),false) or exists(
        select 1 from public.business_orders o join private.loyalty_earning_snapshot_bindings eb on eb.booking_id=o.booking_id
        where o.order_id=p_order_id and o.customer_id=p_customer_id)) then
        return query select false,v_balance;return;
    end if;
    if exists(select 1 from private.offline_walk_in_subjects s where s.order_id=p_order_id)then return query select false,v_balance;return;end if;
    select o.offer_id, o.visits_required into v_offer_id, v_visits_required
    from public.business_offers o
    where o.is_active and o.is_public and o.offer_type = 'visit_reward'
      and not exists (select 1 from private.managed_visit_reward_offers m where m.offer_id=o.offer_id)
      and o.visits_required is not null
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at is null or o.ends_at >= now())
    order by (o.name = 'غسيل 3 مرات والرابعة مجاناً') desc, o.created_at desc
    limit 1;
    -- Managed/new-program offers never activate legacy earning or redemption.
    -- With no explicitly configured unmanaged program, do not mint visits.
    if v_offer_id is null then
        return query select false, v_balance;
        return;
    end if;
    select i.total into v_invoice_total
    from public.business_invoices i where i.invoice_id = p_invoice_id and i.order_id = p_order_id;
    if not found then
        raise exception 'Service invoice was not found';
    end if;
    if v_invoice_total > 0 and v_offer_id is not null and v_balance >= v_visits_required then
        update public.business_invoices
        set discount = discount + total,
            total = 0
        where invoice_id = p_invoice_id;
        insert into public.business_loyalty_transactions (customer_id, points, reason, order_id, offer_id)
        values (p_customer_id, -v_visits_required, 'Wash reward redeemed', p_order_id, v_offer_id);
        v_balance := v_balance - v_visits_required;
        return query select true, v_balance;
        return;
    end if;
    if v_invoice_total > 0 then
        insert into public.business_loyalty_transactions (customer_id, points, reason, order_id, offer_id)
        values (p_customer_id, 1, 'Completed service visit', p_order_id, v_offer_id);
        v_balance := v_balance + 1;
    end if;
    return query select false, v_balance;
end;
$$;

-- Existing booking expression preserved; typed walk-ins use actual frozen worker lines.
CREATE OR REPLACE FUNCTION private.hr_execute(p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET "TimeZone" TO 'UTC'
AS $function$
declare uid uuid:=auth.uid();r text:=private.active_staff_role();s uuid;rid uuid;v jsonb;a private.hr_attendance;e private.hr_employment;
 f date;t date;mins numeric;sched numeric;base numeric;comm numeric;adjustments numeric;lines jsonb;pid uuid;existing private.hr_payroll;
begin
 if uid is null or r is null then raise exception 'Active staff access required' using errcode='42501';end if;
 s:=coalesce((p_data->>'staff_id')::uuid,uid);
 if r<>'owner' and s<>uid then raise exception 'Own HR records only' using errcode='42501';end if;
 if p_action='read' then
 return jsonb_build_object('staff',case when r='owner' then (select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'full_name',full_name)),'[]') from public.staff_profiles where is_active) else '[]'::jsonb end,
 'employment',(select to_jsonb(x) from private.hr_employment x where staff_id=s),
 'attendance',(select coalesce(jsonb_agg(to_jsonb(x) order by clock_in desc),'[]') from (select * from private.hr_attendance where staff_id=s order by clock_in desc limit 100)x),
 'leave',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_leave x where staff_id=s),
 'adjustments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s),
 'payroll',(select coalesce(jsonb_agg(to_jsonb(x) order by from_date desc),'[]') from private.hr_payroll x where staff_id=s));
 end if;
 rid:=(p_data->>'request_id')::uuid;if rid is null then raise exception 'Request identity required';end if;
 -- Serialize each staff workflow: avoids overlapping periods and duplicate open shifts.
 perform pg_advisory_xact_lock(hashtextextended('hr:'||s::text,0));
 if p_action in ('clock_in','clock_out','leave') and s<>uid then raise exception 'Attendance and leave must be submitted by employee' using errcode='42501';end if;
 if p_action='clock_in' then
 select to_jsonb(x) into v from private.hr_attendance x where request_id=rid and staff_id=s;if v is not null then return v;end if;
 if exists(select 1 from private.hr_leave where staff_id=s and status='approved' and current_date between from_date and to_date) then raise exception 'Approved leave covers today';end if;
 insert into private.hr_attendance(staff_id,request_id) values(s,rid) returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='clock_out' then
 select * into a from private.hr_attendance where staff_id=s and id=(p_data->>'id')::uuid for update;
 if a.id is null then raise exception 'Attendance record not found';end if;
 if a.clock_out is not null then return to_jsonb(a);end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and a.clock_in::date<=to_date and clock_timestamp()::date>=from_date) then raise exception 'Attendance overlaps approved payroll';end if;
 update private.hr_attendance set clock_out=clock_timestamp() where id=a.id returning to_jsonb(hr_attendance.*) into v;return v;
 elsif p_action='leave' then
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;
 if f is null or t is null or f<current_date then raise exception 'Future leave dates required';end if;
 insert into private.hr_leave(staff_id,from_date,to_date,reason,request_id) values(s,f,t,p_data->>'reason',rid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_leave x where request_id=rid and staff_id=s);
 end if;
 if r<>'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if not exists(select 1 from public.staff_profiles where user_id=s and is_active) then raise exception 'Active staff required';end if;
 if p_action='employment' then
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on,ends_on) values(s,(p_data->>'salary')::numeric,(p_data->>'commission_percent')::numeric,upper(p_data->>'currency'),(p_data->>'starts_on')::date,(p_data->>'ends_on')::date)
 on conflict(staff_id) do update set salary=excluded.salary,commission_percent=excluded.commission_percent,currency=excluded.currency,starts_on=excluded.starts_on,ends_on=excluded.ends_on,updated_at=now();
 return (select to_jsonb(x) from private.hr_employment x where staff_id=s);
 elsif p_action='decide_leave' then
 if p_data->>'status' not in ('approved','rejected') then raise exception 'Choose approved or rejected';end if;
 if p_data->>'status'='approved' and exists(select 1 from private.hr_leave target join private.hr_leave other on other.staff_id=target.staff_id and other.id<>target.id and other.status='approved' and other.from_date<=target.to_date and other.to_date>=target.from_date where target.id=(p_data->>'id')::uuid and target.staff_id=s) then raise exception 'Approved leave dates overlap';end if;
 update private.hr_leave set status=p_data->>'status',decided_by=uid where id=(p_data->>'id')::uuid and staff_id=s and status='pending' returning to_jsonb(hr_leave.*) into v;
 if v is null then raise exception 'Pending leave required';end if;return v;
 elsif p_action='adjustment' then
 select * into e from private.hr_employment where staff_id=s;
 if e.staff_id is null then raise exception 'Employment currency must be configured first';end if;
 f:=(p_data->>'on_date')::date;
 if exists(select 1 from private.hr_payroll where staff_id=s and f between from_date and to_date) then raise exception 'Approved payroll period is closed';end if;
 insert into private.hr_adjustment(staff_id,on_date,currency,kind,amount,reason,request_id,created_by) values(s,f,e.currency,p_data->>'kind',(p_data->>'amount')::numeric,p_data->>'reason',rid,uid) on conflict(request_id) do nothing;
 return (select to_jsonb(x) from private.hr_adjustment x where request_id=rid and staff_id=s);
 elsif p_action='approve_payroll' then
 select * into existing from private.hr_payroll where request_id=rid;
 if existing.id is not null then if existing.staff_id<>s then raise exception 'Request belongs to another staff';end if;return to_jsonb(existing);end if;
 f:=(p_data->>'from_date')::date;t:=(p_data->>'to_date')::date;sched:=(p_data->>'scheduled_minutes')::numeric;
 if f is null or t is null or t<f or t>=current_date or t-f>366 or sched is null or sched<=0 or sched::text in ('NaN','Infinity','-Infinity') then raise exception 'Closed dates and explicit scheduled minutes required';end if;
 if exists(select 1 from private.hr_payroll where staff_id=s and from_date<=t and to_date>=f) then raise exception 'Payroll periods cannot overlap';end if;
 select * into e from private.hr_employment where staff_id=s;
 if e.currency is distinct from 'EGP' then raise exception 'Payroll requires EGP compensation; no exchange conversion is configured';end if;
 if e.staff_id is null or e.starts_on>f or coalesce(e.ends_on,t)<t then raise exception 'Employment must cover entire period';end if;
 if exists(select 1 from private.hr_attendance where staff_id=s and clock_in<(t+1)::timestamptz and (clock_out is null or clock_out>f::timestamptz) and (clock_out is null or clock_in<f::timestamptz or clock_out>(t+1)::timestamptz)) then raise exception 'Open or boundary-spanning attendance must be resolved before payroll';end if;
 select coalesce(sum(extract(epoch from(clock_out-clock_in))/60),0) into mins from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz;
 base:=round(e.salary*least(mins/sched,1),2);
 -- Freeze relevant assignments and invoice values while approving the financial snapshot.
 perform 1 from public.business_orders o join public.business_invoices i using(order_id) where s=any(o.assigned_staff_ids) and o.order_type='service' and i.status='active' and i.sale_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz for update of o,i;
 -- One invoice per order only. Duplicate invoice associations are rejected, never multiplied or silently chosen.
 if exists(select 1 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz and (select count(*) from public.business_invoices dup where dup.order_id=i.order_id and dup.status='active')>1) then raise exception 'Duplicate service invoices require reconciliation';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'order_id',i.order_id,'before_discount',i.total+i.discount,'rate_percent',case when i.commission_model='walk_in_frozen_workers'then(select wc.rate_percent from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s)else e.commission_percent end,'assigned_count',(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),'commission',case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end)),'[]'),coalesce(sum(case when i.commission_model='walk_in_frozen_workers' then (select wc.amount from private.offline_walk_in_commissions wc where wc.invoice_id=i.invoice_id and wc.staff_id=s) else round((i.total+i.discount)*e.commission_percent/100/(select count(distinct worker) from unnest(o.assigned_staff_ids) worker),2) end),0) into lines,comm
 from public.business_invoices i join public.business_orders o using(order_id) where s=any(o.assigned_staff_ids) and i.status='active' and i.sale_type='service' and o.order_type='service' and o.status in ('completed','delivered') and i.issued_at>=f::timestamptz and i.issued_at<(t+1)::timestamptz;
 if exists(select 1 from private.hr_adjustment where staff_id=s and on_date between f and t and currency<>e.currency) then raise exception 'Adjustment and payroll currencies must match';end if;
 select coalesce(sum(case when kind='bonus' then amount else -amount end),0) into adjustments from private.hr_adjustment where staff_id=s and on_date between f and t;
 v:=jsonb_build_object('employment',to_jsonb(e),'actual_minutes',mins,'scheduled_minutes',sched,'base_earned',base,'commission',comm,'commission_lines',lines,'adjustments',adjustments,'net',base+comm+adjustments,'currency',e.currency,'attendance_ids',(select coalesce(jsonb_agg(id),'[]') from private.hr_attendance where staff_id=s and clock_in>=f::timestamptz and clock_in<(t+1)::timestamptz and clock_out<=(t+1)::timestamptz),'adjustment_lines',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from private.hr_adjustment x where staff_id=s and on_date between f and t),'leave_policy','Leave approval does not create paid time; actual clocked minutes only','payment_status','not_transferred');
 insert into private.hr_payroll(staff_id,from_date,to_date,scheduled_minutes,snapshot,request_id,approved_by) values(s,f,t,sched,v,rid,uid) returning to_jsonb(hr_payroll.*) into v;return v;
 end if;
 raise exception 'Unknown HR action';
end $function$;
create function public.prepare_offline_walk_in(p_request uuid,p_registration uuid,p_service uuid,p_expected_price numeric,p_cashier uuid,p_staff_ids uuid[],p_notes text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_offline_walk_in(p_request,p_registration,p_service,p_expected_price,p_cashier,p_staff_ids,p_notes)$$;
revoke all on function private.prepare_offline_walk_in(uuid,uuid,uuid,numeric,uuid,uuid[],text),public.prepare_offline_walk_in(uuid,uuid,uuid,numeric,uuid,uuid[],text)from public,anon,service_role;
grant execute on function private.prepare_offline_walk_in(uuid,uuid,uuid,numeric,uuid,uuid[],text),public.prepare_offline_walk_in(uuid,uuid,uuid,numeric,uuid,uuid[],text)to authenticated;
create function public.place_offline_walk_in(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.place_offline_walk_in(p_request)$$;
revoke all on function private.place_offline_walk_in(uuid),public.place_offline_walk_in(uuid)from public,anon,service_role;
grant execute on function private.place_offline_walk_in(uuid),public.place_offline_walk_in(uuid)to authenticated;
create function public.get_offline_walk_in_command(p_request uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_offline_walk_in_command(p_request)$$;
revoke all on function private.get_offline_walk_in_command(uuid),public.get_offline_walk_in_command(uuid)from public,anon,service_role;
grant execute on function private.get_offline_walk_in_command(uuid),public.get_offline_walk_in_command(uuid)to authenticated;
create function public.close_offline_walk_in_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.close_offline_walk_in_command(p_request)$$;
revoke all on function private.close_offline_walk_in_command(uuid),public.close_offline_walk_in_command(uuid)from public,anon,service_role;
grant execute on function private.close_offline_walk_in_command(uuid),public.close_offline_walk_in_command(uuid)to authenticated;
create function public.ack_offline_walk_in_command(p_request uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.ack_offline_walk_in_command(p_request)$$;
revoke all on function private.ack_offline_walk_in_command(uuid),public.ack_offline_walk_in_command(uuid)from public,anon,service_role;
grant execute on function private.ack_offline_walk_in_command(uuid),public.ack_offline_walk_in_command(uuid)to authenticated;
create function public.cancel_offline_walk_in(p_request uuid,p_order uuid,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.cancel_offline_walk_in(p_request,p_order,p_reason)$$;
revoke all on function private.cancel_offline_walk_in(uuid,uuid,text),public.cancel_offline_walk_in(uuid,uuid,text)from public,anon,service_role;
grant execute on function private.cancel_offline_walk_in(uuid,uuid,text),public.cancel_offline_walk_in(uuid,uuid,text)to authenticated;
create function public.list_offline_walk_in_reception(p_branch uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.list_offline_walk_in_reception(p_branch)$$;
revoke all on function private.list_offline_walk_in_reception(uuid),public.list_offline_walk_in_reception(uuid)from public,anon,service_role;
grant execute on function private.list_offline_walk_in_reception(uuid),public.list_offline_walk_in_reception(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
