begin;

-- QA-forward migration: permit an explicitly authorized cashier to prepare a
-- received walk-in and atomically flag an intake as VIP. Payment/work state is
-- unchanged; VIP never starts service.
alter table private.offline_walk_in_reception
  drop constraint if exists offline_walk_in_reception_priority_check;
alter table private.offline_walk_in_reception
  add constraint offline_walk_in_reception_priority_check
  check (priority in ('normal', 'vip'));

-- Keep typed reception rows immutable except for the one audited normal→VIP
-- transition, which is only reachable through the scoped RPC below.
drop trigger if exists immutable_offline_walk_in on private.offline_walk_in_reception;
drop trigger if exists guard_offline_walk_in_reception_priority on private.offline_walk_in_reception;
create or replace function private.guard_offline_walk_in_reception_priority()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_request uuid;begin
 if tg_op='DELETE' then
  raise exception 'Walk-in reception history is retained' using errcode='55000';
 elsif tg_op='INSERT' then
  if new.priority<>'normal' then raise exception 'Walk-in begins at normal reception priority' using errcode='55000';end if;
  return new;
 end if;
 if (to_jsonb(new)-'priority') is distinct from (to_jsonb(old)-'priority')
    or old.priority<>'normal' or new.priority<>'vip' then
  raise exception 'Only a recorded normal-to-VIP intake transition is supported' using errcode='55000';
 end if;
 v_request:=nullif(current_setting('app.vip_walk_in_request',true),'')::uuid;
 if v_request is null or not exists(
   select 1 from private.offline_walk_in_events e
   where e.request_id=v_request and e.action='vip_priority'
     and e.actor_id=auth.uid() and e.creator_xid=txid_current()
     and e.payload->>'order_id'=new.order_id::text
     and e.result->>'priority'='vip'
 ) then
  raise exception 'Audited VIP intake command required' using errcode='55000';
 end if;
 return new;
end$$;
revoke all on function private.guard_offline_walk_in_reception_priority()
  from public,anon,authenticated,service_role;
create trigger guard_offline_walk_in_reception_priority
  before insert or update or delete on private.offline_walk_in_reception
  for each row execute function private.guard_offline_walk_in_reception_priority();

create or replace function private.get_offline_walk_in_context(p_registration uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare r private.offline_customer_registration_requests;
 p private.offline_customer_profiles;c private.offline_customer_car_refs;
 b public.business_branches;role text:=private.active_staff_role();
 can_prepare boolean;cashier_name text;today date:=(clock_timestamp()at time zone'Africa/Cairo')::date;
begin
 if auth.uid() is null or role is null or role not in('owner','manager','employee') or p_registration is null then
  raise exception 'Authorized current reception receipt required' using errcode='42501';
 end if;
 select * into r from private.offline_customer_registration_requests where request_id=p_registration;
 if not found or r.result->>'status' not in('created_unverified','reused_unverified')
    or not coalesce(private.can_cashier_branch(r.branch_id),false)
    or not coalesce(private.can_access_branch(r.branch_id),false)
    or not private.offline_walk_in_cashier(r.actor_id,r.branch_id)
    or (role='employee' and r.actor_id<>auth.uid()) then
  raise exception 'Authorized current reception receipt required' using errcode='42501';
 end if;
 select * into b from public.business_branches where branch_id=r.branch_id and is_active;
 select * into p from private.offline_customer_profiles
  where profile_id=(r.result->>'offline_profile_id')::uuid and created_branch_id=r.branch_id;
 select * into c from private.offline_customer_car_refs
  where car_ref_id=(r.result->>'car_ref_id')::uuid and profile_id=p.profile_id;
 if b.branch_id is null or p.profile_id is null or c.car_ref_id is null then
  raise exception 'Authorized current reception receipt required' using errcode='42501';
 end if;
 select full_name into cashier_name from public.staff_profiles where user_id=r.actor_id and is_active;
 can_prepare:=role in('owner','manager') or (role='employee' and r.actor_id=auth.uid()
   and exists(select 1 from public.staff_profiles s where s.user_id=auth.uid() and s.is_active and s.role='employee' and s.permissions->>'cashier'='true'));
 return jsonb_build_object(
  'registration_request_id',r.request_id,
  'branch',jsonb_build_object('id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en,'currency',b.currency),
  'subject',jsonb_build_object('profile_id',p.profile_id,'name',p.full_name,'car_ref_id',c.car_ref_id,'plate_number',c.plate_key,'brand',c.car_snapshot->>'brand','model',c.car_snapshot->>'model','identity_verified',false),
  'bound_cashier',jsonb_build_object('id',r.actor_id,'name',cashier_name),'can_prepare',can_prepare,
  'services',case when can_prepare then(select coalesce(jsonb_agg(jsonb_build_object('id',s.item_id,'name',s.name,'name_en',s.name_en,'vehicle_type',s.vehicle_type,'price',s.price,'duration_minutes',s.duration_minutes)order by s.name,s.item_id),'[]')from public.business_catalog_items s where s.branch_id=b.branch_id and s.item_type='service' and s.is_active and s.is_public and s.price>0 and s.price::text not in('NaN','Infinity','-Infinity') and s.name!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)')else'[]'::jsonb end,
  'workers',case when can_prepare then(select coalesce(jsonb_agg(jsonb_build_object('id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and e.currency='EGP' and e.starts_on<=today and(e.ends_on is null or e.ends_on>=today) and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=b.branch_id))else'[]'::jsonb end,
  'capabilities',private.offline_walk_in_flags());
end$$;

create or replace function private.prepare_offline_walk_in(
 p_request uuid,p_registration uuid,p_service uuid,p_expected_price numeric,
 p_cashier uuid,p_staff_ids uuid[],p_notes text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_prior private.offline_walk_in_commands;v_facts jsonb;v_payload jsonb;v_staff uuid[];
 v_role text:=private.active_staff_role();
begin
 if auth.uid() is null or v_role is null or not(
   v_role in('owner','manager') or
   (v_role='employee' and p_cashier=auth.uid() and exists(
     select 1 from public.staff_profiles s where s.user_id=auth.uid() and s.is_active
       and s.role='employee' and s.permissions->>'cashier'='true'))
 ) then raise exception 'Active owner, manager or authorized cashier required' using errcode='42501';end if;
 if p_request is null or p_cashier is null or p_registration is null or p_service is null or p_expected_price is null or length(coalesce(p_notes,''))>1000 then
  raise exception 'Stable actual service preparation required' using errcode='22023';
 end if;
 if current_setting('transaction_isolation')<>'read committed' then raise exception 'Walk-in requires READ COMMITTED' using errcode='55000';end if;
 perform set_config('lock_timeout','20s',true);
 select array_agg(x order by x) into v_staff from unnest(p_staff_ids)x;
 v_payload:=jsonb_build_object('registration_request_id',p_registration,'service_id',p_service,'expected_price',p_expected_price,'cashier_id',p_cashier,'staff_ids',to_jsonb(v_staff),'notes',nullif(trim(p_notes),''));
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-actor:'||p_cashier::text,0));
 select * into v_prior from private.offline_walk_in_commands where request_id=p_request;
 if found then
  if v_prior.prepared_by<>auth.uid() or v_prior.actor_id<>p_cashier then raise exception 'Preparation receipt unavailable' using errcode='42501';end if;
  if v_prior.payload<>v_payload then raise exception 'Preparation payload changed' using errcode='22023';end if;
  return private.get_offline_walk_in_command(p_request);
 end if;
 v_facts:=private.walk_in_service_facts(p_registration,p_service,p_expected_price,p_staff_ids,p_cashier);
 insert into private.offline_walk_in_commands(request_id,actor_id,prepared_by,branch_id,payload,financial_snapshot,state)
 values(p_request,p_cashier,auth.uid(),(v_facts->>'branch_id')::uuid,v_payload,v_facts,'prepared');
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)
 values(p_request,auth.uid(),'prepare',v_payload,jsonb_build_object('status','prepared','bound_cashier',p_cashier),txid_current());
 return private.get_offline_walk_in_command(p_request);
end$$;

create or replace function private.set_offline_walk_in_vip(p_request uuid,p_order uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c private.offline_walk_in_commands;o public.business_orders;e private.offline_walk_in_events;
 payload jsonb;result jsonb;role text:=private.active_staff_role();
begin
 if auth.uid() is null or p_request is null or p_order is null then raise exception 'Authenticated VIP intake command required' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-walkin-request:'||p_request::text,0));
 select * into c from private.offline_walk_in_commands where request_id=p_request for update;
 if not found or c.state<>'succeeded' or c.order_id<>p_order or (c.actor_id<>auth.uid() and role is distinct from 'owner')
    or not coalesce(private.can_access_branch(c.branch_id),false)
    or not coalesce(private.offline_walk_in_cashier(auth.uid(),c.branch_id),false) then
  raise exception 'Authorized received walk-in required' using errcode='42501';
 end if;
 if role='employee' and not exists(select 1 from public.staff_profiles s where s.user_id=auth.uid() and s.is_active and s.role='employee' and s.permissions->>'cashier'='true' and s.permissions->>'vip_reception'='true') then
  raise exception 'Explicit VIP reception permission required' using errcode='42501';
 elsif role not in('owner','manager','employee') then
  raise exception 'Active reception staff required' using errcode='42501';
 end if;
 select * into o from public.business_orders where order_id=p_order for update;
 if o.order_id is null or o.branch_id<>c.branch_id or o.status<>'received' or exists(select 1 from public.business_payment_events p where p.invoice_id=c.result->>'invoice_id') then
  raise exception 'VIP priority is only available before service and payment' using errcode='55000';
 end if;
 payload:=jsonb_build_object('order_id',p_order,'priority','vip');
 select * into e from private.offline_walk_in_events where request_id=p_request and action='vip_priority';
 if found then
  if e.actor_id<>auth.uid() or e.payload<>payload then raise exception 'VIP request replay does not match' using errcode='22023';end if;
  return e.result;
 end if;
 if not exists(select 1 from private.offline_walk_in_reception r where r.order_id=p_order and r.priority='normal' and r.branch_id=c.branch_id for update) then
  raise exception 'Normal reception row required for one-time VIP promotion' using errcode='55000';
 end if;
 result:=jsonb_build_object('request_id',p_request,'order_id',p_order,'priority','vip','work_status','received','service_started',false,'payment_confirmed',false);
 insert into private.offline_walk_in_events(request_id,actor_id,action,payload,result,creator_xid)
 values(p_request,auth.uid(),'vip_priority',payload,result,txid_current());
 perform set_config('app.vip_walk_in_request',p_request::text,true);
 update private.offline_walk_in_reception set priority='vip' where order_id=p_order;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data)
 values(auth.uid()::text,auth.uid(),'offline_walk_in_vip_priority','business_orders',p_order::text,c.branch_id,'VIP requested at vehicle intake',result);
 return result;
end$$;

create or replace function public.place_offline_walk_in_with_priority(p_request uuid,p_priority text)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare response jsonb;priority_receipt jsonb;
begin
 if p_priority not in('normal','vip') then raise exception 'Supported reception priority required' using errcode='22023';end if;
 response:=private.place_offline_walk_in(p_request);
 if p_priority='vip' and response->>'status'='succeeded' then
  priority_receipt:=private.set_offline_walk_in_vip(p_request,(response->'result'->>'order_id')::uuid);
  response:=response||jsonb_build_object('reception_priority',priority_receipt->>'priority');
 end if;
 return response;
end$$;
revoke all on function private.set_offline_walk_in_vip(uuid,uuid),public.place_offline_walk_in_with_priority(uuid,text) from public,anon,service_role;
grant execute on function private.set_offline_walk_in_vip(uuid,uuid) to authenticated;
grant execute on function public.place_offline_walk_in_with_priority(uuid,text) to authenticated;

notify pgrst,'reload schema';
commit;
