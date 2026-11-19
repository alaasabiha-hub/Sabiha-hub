-- SOURCE ONLY / rollback fixture. No public work-start API is installed by this stage.
-- Synthetic PRIVATE span/event times below test occupancy arithmetic, not actual
-- physical-work acceptance; every fixture, invoice and event rolls back.
begin;
do $$
declare v_owner uuid;v_manager uuid;v_worker uuid;v_customer uuid;v_vehicle uuid:=gen_random_uuid();v_branch uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_long_service uuid:=gen_random_uuid();v_vehicle2 uuid:=gen_random_uuid();v_other_service uuid:=gen_random_uuid();v_req uuid:=gen_random_uuid();v_intake jsonb;v_consent jsonb;v_result jsonb;v_order uuid;v_span uuid;v_event uuid;v_release uuid;v_booking uuid;v_linked_order uuid;v_facts jsonb;v_denied boolean;v_t0 timestamp:=((clock_timestamp()at time zone'Africa/Cairo')::date+2)+time'10:00';v_start timestamptz;v_before text;v_after text;
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_manager from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active limit 1;
 select id into strict v_customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select md5(string_agg(x::text,''order by x::text))into v_before from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار السعة المشتركة','Shared resource QA');
 update public.business_branch_hours set opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 update public.business_branch_resources set capacity=1 where branch_id=v_branch;
 insert into public.staff_branch_access(user_id,branch_id)values(v_manager,v_branch),(v_worker,v_branch);
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on)values(v_manager,0,15,'EGP',current_date-365),(v_worker,0,25,'EGP',current_date-365)on conflict(staff_id)do update set commission_percent=excluded.commission_percent,currency='EGP',starts_on=excluded.starts_on,ends_on=null,updated_at=clock_timestamp();
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_service,v_branch,'service','Shared wash QA','sedan',120,5,'wash',true,true),(v_other_service,v_branch,'service','Shared polish QA','sedan',120,5,'polish',true,true);
 -- Real Auth vehicle is used ONLY for real booking guard cases, never as an offline substitute.
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(v_vehicle,v_customer,'QA','Resource fixture','QA-'||left(gen_random_uuid()::text,8));
 v_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'Shared resource source QA','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA RESOURCE1"}',v_consent);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_manager,array[v_manager,v_worker]);
 perform set_config('request.jwt.claim.sub',v_manager::text,true);v_result:=public.place_offline_walk_in(v_req);v_order:=(v_result->'result'->>'order_id')::uuid;execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);
 assert v_result->'capabilities'->>'work_start_supported'='false';
 assert not has_table_privilege('authenticated','private.service_resource_spans','SELECT');assert not has_table_privilege('service_role','private.service_resource_events','INSERT');
 assert not has_function_privilege('authenticated','private.service_resource_occupancy(uuid,text,timestamp with time zone,timestamp with time zone,uuid,uuid,boolean)','EXECUTE');
 v_facts:=private.service_resource_occupancy(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo');assert(v_facts->>'planned_peak')::integer=0;
 -- Exact shared mutex helper accepts sorted distinct dates; it does not create reservations.
 perform private.lock_service_resource_days(v_branch,'wash',array[v_t0::date+1,v_t0::date,v_t0::date]);
 begin
  v_span:=gen_random_uuid();v_event:=gen_random_uuid();v_start:=v_t0 at time zone'Africa/Cairo';
  insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_event,gen_random_uuid(),v_owner,'walk_in',v_order,'start','{"qa_synthetic_arithmetic_only":true}',v_start,txid_current());
  insert into private.service_resource_spans(span_id,source_kind,walk_in_order_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id)values(v_span,'walk_in',v_order,v_branch,'wash',5,v_start,v_start+interval'5 minutes',v_event);
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_start,v_start+interval'5 minutes');assert(v_facts->>'planned_peak')::integer=1 and(v_facts->>'physical_now')::integer=1,'Walk-in NULL booking identity incorrectly excluded span';
  v_denied:=false;begin insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time)values(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Server price authoritative',v_t0::date,v_t0::time);exception when raise_exception then v_denied:=true;end;assert v_denied,'Future booking ignored known walk-in interval';
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time,quoted_price)values(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Server price authoritative',v_t0::date,(v_t0+interval'10 minutes')::time,999);
  assert exists(select 1 from public.bookings where branch_id=v_branch and quoted_price=120 and duration_minutes=5 and resource_key='wash');
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_start,v_start+interval'5 minutes',null,v_order);assert(v_facts->>'planned_peak')::integer=0,'Typed self exclusion failed';
  v_denied:=false;begin perform private.assert_service_resource_start(v_branch,'wash',v_start,v_start+interval'5 minutes');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  -- First actual witnessed release is the only mutable span fact.
  v_release:=gen_random_uuid();insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_release,gen_random_uuid(),v_owner,'walk_in',v_order,'complete','{"qa_synthetic_arithmetic_only":true}',v_start+interval'2 minutes',txid_current());
  update private.service_resource_spans set ended_at=v_start+interval'2 minutes',end_event_id=v_release where span_id=v_span;
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_start,v_start+interval'5 minutes');assert(v_facts->>'physical_now')::integer=0 and(v_facts->>'planned_peak')::integer=0;
  v_denied:=false;begin update private.service_resource_spans set ended_at=null,end_event_id=null where span_id=v_span;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback known interval fixtures'using errcode='PZ041';
 exception when sqlstate'PZ041'then null;end;
 begin
  -- Overrun physically blocks actual start but never reserves all future slots.
  v_span:=gen_random_uuid();v_event:=gen_random_uuid();v_start:=(v_t0-interval'1 hour')at time zone'Africa/Cairo';
  insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_event,gen_random_uuid(),v_owner,'walk_in',v_order,'start','{"qa_synthetic_arithmetic_only":true}',v_start,txid_current());
  insert into private.service_resource_spans(span_id,source_kind,walk_in_order_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id)values(v_span,'walk_in',v_order,v_branch,'wash',5,v_start,v_start+interval'5 minutes',v_event);
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo',null,null,true);assert(v_facts->>'physical_now')::integer=1 and(v_facts->>'admission_peak')::integer=1 and(v_facts->>'overrun_count')::integer=1;
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo');assert(v_facts->>'planned_peak')::integer=0;
  v_denied:=false;begin perform private.assert_service_resource_start(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time)values(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Future planned slot, physical recheck required',v_t0::date,v_t0::time);
  raise exception 'rollback overrun fixtures'using errcode='PZ042';
 exception when sqlstate'PZ042'then null;end;
 begin
  v_booking:=gen_random_uuid();v_linked_order:=gen_random_uuid();v_start:=v_t0 at time zone'Africa/Cairo';
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time,status)values(v_booking,v_customer,v_vehicle,v_branch,v_service,'One real booking source',v_t0::date,v_t0::time,'confirmed');
  insert into public.business_orders(order_id,order_number,booking_id,customer_id,branch_id,service_name,status)values(v_linked_order,'QA-SOURCE-'||v_linked_order::text,v_booking,v_customer,v_branch,'One real booking source','in_progress');
  v_event:=gen_random_uuid();v_span:=gen_random_uuid();insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,booking_id,action,payload,occurred_at,creator_xid)values(v_event,gen_random_uuid(),v_owner,'booking',v_booking,'start','{"qa_synthetic_arithmetic_only":true}',v_start,txid_current());
  insert into private.service_resource_spans(span_id,source_kind,booking_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id)values(v_span,'booking',v_booking,v_branch,'wash',5,v_start,v_start+interval'5 minutes',v_event);
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_start,v_start+interval'5 minutes',null,null,true);assert(v_facts->>'physical_now')::integer=1 and(v_facts->>'admission_peak')::integer=1,'Booking+order+span counted more than once';
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_start,v_start+interval'5 minutes',v_booking,null,true);assert(v_facts->>'physical_now')::integer=0;
  v_denied:=false;begin update public.bookings set booking_time=(v_t0+interval'10 minutes')::time where id=v_booking;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Started source schedule moved away from its frozen span';
  raise exception 'rollback booked source fixtures'using errcode='PZ043';
 exception when sqlstate'PZ043'then null;end;
 begin
  -- Three disjoint source windows overlap a long proposed interval, but peak is ONE.
  -- This verifies actual peak calculation, not a total count of intersecting rows.
  update public.business_branch_resources set capacity=2 where branch_id=v_branch and resource_key='wash';
  insert into public.vehicles(id,customer_id,brand,model,plate_number)values(v_vehicle2,v_customer,'QA','Long interval fixture','QA-'||left(gen_random_uuid()::text,8));
  insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_long_service,v_branch,'service','Long shared wash QA','sedan',120,15,'wash',true,true);
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time)values(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Disjoint first window',v_t0::date,v_t0::time),(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Disjoint last window',v_t0::date,(v_t0+interval'10 minutes')::time);
  v_span:=gen_random_uuid();v_event:=gen_random_uuid();v_start:=(v_t0+interval'5 minutes')at time zone'Africa/Cairo';
  insert into private.service_resource_events(event_id,request_id,actor_id,source_kind,walk_in_order_id,action,payload,occurred_at,creator_xid)values(v_event,gen_random_uuid(),v_owner,'walk_in',v_order,'start','{"qa_synthetic_arithmetic_only":true}',v_start,txid_current());
  insert into private.service_resource_spans(span_id,source_kind,walk_in_order_id,branch_id,resource_key,duration_minutes,started_at,expected_end_at,start_event_id)values(v_span,'walk_in',v_order,v_branch,'wash',5,v_start,v_start+interval'5 minutes',v_event);
  v_facts:=private.service_resource_occupancy(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'15 minutes')at time zone'Africa/Cairo');assert(v_facts->>'planned_peak')::integer=1,'Disjoint windows were summed instead of peak concurrency';
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time)values(gen_random_uuid(),v_customer,v_vehicle2,v_branch,v_long_service,'Long interval fits remaining single bay',v_t0::date,v_t0::time);
  raise exception 'rollback disjoint windows fixture'using errcode='PZ046';
 exception when sqlstate'PZ046'then null;end;
 v_denied:=false;begin perform private.service_resource_occupancy(gen_random_uuid(),'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 begin
  insert into public.business_orders(order_id,order_number,branch_id,service_name,status)values(gen_random_uuid(),'QA-UNCLASSIFIED-'||gen_random_uuid()::text,v_branch,'Unclassified legacy active source','in_progress');
  v_denied:=false;begin perform private.assert_service_resource_start(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback unclassified source'using errcode='PZ044';
 exception when sqlstate'PZ044'then null;end;
 begin
  update public.business_branches set inspection_required=true where branch_id=v_branch;
  v_denied:=false;begin perform private.assert_service_resource_start(v_branch,'wash',v_t0 at time zone'Africa/Cairo',(v_t0+interval'5 minutes')at time zone'Africa/Cairo',null,v_order);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
  raise exception 'rollback required inspection branch'using errcode='PZ045';
 exception when sqlstate'PZ045'then null;end;
 v_denied:=false;begin insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time)values(gen_random_uuid(),v_customer,v_vehicle,v_branch,v_service,'Outside hours',v_t0::date,'23:58');exception when raise_exception then v_denied:=true;end;assert v_denied;
 select md5(string_agg(x::text,''order by x::text))into v_after from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 assert v_before=v_after,'Capacity foundation changed Auth/customer/loyalty rows';
 assert(select status from public.business_orders where order_id=v_order)='received','Private arithmetic fixture enabled real work';
 assert private.offline_walk_in_flags()->>'work_start_supported'='false';
 raise notice 'PASS capacity foundation fixture: shared planned intervals, physical overrun, typed exclusions, no double count, immutable evidence, original booking guards, no work API/readiness';
end$$;
rollback;
