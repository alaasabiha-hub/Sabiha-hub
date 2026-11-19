-- SOURCE ONLY. All QA fixtures, event proofs and invoices roll back. No actual
-- physical bay/electronic gateway/payment/loyalty activation is claimed by SQL QA.
begin;
do $$
declare v_owner uuid;v_actor uuid;v_worker uuid;v_unassigned uuid;v_customer uuid;v_branch uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_orders uuid[]:='{}';v_intake jsonb;v_consent jsonb;v_req uuid;v_work uuid;v_closed uuid;v_result jsonb;v_retry jsonb;v_oid uuid;v_booking uuid:=gen_random_uuid();v_book_order uuid:=gen_random_uuid();v_vehicle uuid:=gen_random_uuid();v_staff uuid[];v_span private.service_resource_spans;v_denied boolean;v_i integer;v_t timestamp:=clock_timestamp()at time zone'Africa/Cairo';v_future timestamp;v_invoice_hash text;v_current_hash text;v_before text;v_after text;v_saved_start uuid;v_facts jsonb;
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_actor from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active limit 1;
 select user_id into strict v_unassigned from public.staff_profiles where role='employee'and is_active and user_id<>v_worker limit 1;
 select id into strict v_customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select array_agg(x order by x)into v_staff from unnest(array[v_actor,v_worker])x;
 select md5(string_agg(x::text,''order by x::text))into v_before from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار تنفيذ الخدمة','Work kernel QA');
 update public.business_branch_hours set opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 update public.business_branch_resources set capacity=1 where branch_id=v_branch;
 insert into public.staff_branch_access(user_id,branch_id)values(v_actor,v_branch),(v_worker,v_branch),(v_unassigned,v_branch);
 update public.staff_profiles set permissions=coalesce(permissions,'{}')||'{"cashier":true}'::jsonb where user_id=v_unassigned;
 insert into private.hr_employment(staff_id,salary,commission_percent,currency,starts_on)values(v_actor,0,15,'EGP',v_t::date-365),(v_worker,0,25,'EGP',v_t::date-365)on conflict(staff_id)do update set commission_percent=excluded.commission_percent,currency='EGP',starts_on=excluded.starts_on,ends_on=null,updated_at=clock_timestamp();
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_service,v_branch,'service','Work kernel QA standard service','sedan',120,5,'wash',true,true);
 v_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 for v_i in 1..2 loop
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);
  v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'Actual work QA '||v_i,'+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG',jsonb_build_object('plate_number','QA WORK'||v_i),v_consent);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);v_req:=gen_random_uuid();perform public.prepare_offline_walk_in(v_req,(v_intake->>'request_id')::uuid,v_service,120,v_actor,v_staff);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);v_result:=public.place_offline_walk_in(v_req);v_orders:=array_append(v_orders,(v_result->'result'->>'order_id')::uuid);perform public.ack_offline_walk_in_command(v_req);execute 'reset role';
 end loop;
 select md5(string_agg(to_jsonb(i)::text,''order by invoice_id))into v_invoice_hash from public.business_invoices i where order_id=any(v_orders);
 assert not has_table_privilege('authenticated','private.service_work_ledger','INSERT');assert not has_table_privilege('service_role','private.service_work_commands','SELECT');
 -- Actual client ACLs already reject these fields; the invoker trigger also fences
 -- identified-user definer/server inserts, without granting any INSERT privilege.
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_denied:=false;begin insert into public.business_orders(order_id,order_number,branch_id,service_name,status)values(gen_random_uuid(),'QA-CLIENT-'||gen_random_uuid()::text,v_branch,'Forbidden active client insert','in_progress');exception when insufficient_privilege or object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin insert into public.bookings(id,branch_id,catalog_item_id,service_name,booking_date,booking_time,status)values(gen_random_uuid(),v_branch,v_service,'Forbidden active client insert',v_t::date+1,'10:00','in_progress');exception when insufficient_privilege or object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 execute 'reset role';
 v_denied:=false;begin insert into public.business_orders(order_id,order_number,branch_id,service_name,status)values(gen_random_uuid(),'QA-DEFINER-'||gen_random_uuid()::text,v_branch,'Identified user cannot manufacture quality work','quality_check');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 v_denied:=false;begin insert into public.bookings(id,branch_id,catalog_item_id,service_name,booking_date,booking_time,status)values(gen_random_uuid(),v_branch,v_service,'Identified user cannot insert active work',v_t::date+1,'10:00','in_progress');exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 begin
  -- Only an actual Auth-UID-null PostgreSQL historical fixture context is exempt.
  -- This is not an exposed client/import RPC and its synthetic row immediately rolls back.
  perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claim.role','',true);perform set_config('request.jwt.claims','{}',true);
  assert auth.uid()is null and current_user='postgres';
  insert into public.business_orders(order_id,order_number,branch_id,service_name,status)values(gen_random_uuid(),'QA-HISTORICAL-'||gen_random_uuid()::text,v_branch,'Trusted historical fixture only','quality_check');
  raise exception 'rollback trusted historical fixture'using errcode='PZ085';
 exception when sqlstate'PZ085'then null;end;


 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_unassigned::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_unassigned,'user_metadata',jsonb_build_object('role','owner'))::text,true);
 v_denied:=false;begin perform public.prepare_service_work(gen_random_uuid(),v_orders[1],'received','in_progress','Cashier alone cannot perform work');exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v_work:=gen_random_uuid();v_result:=public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Existing owner authority may certify assigned crew work');assert v_result->>'status'='prepared';perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 perform set_config('request.jwt.claim.sub',v_actor::text,true);
 v_work:=gen_random_uuid();v_result:=public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Actual assigned worker starts queued service');assert v_result->>'status'='prepared';assert public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Actual assigned worker starts queued service')=v_result;
 v_denied:=false;begin perform public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Changed work reason');exception when invalid_parameter_value then v_denied:=true;end;assert v_denied;
 -- Closing unrelated absent UUID never blocks resolution of the real prepared command.
 v_closed:=gen_random_uuid();assert public.close_service_work_command(v_closed)->>'status'='closed';perform public.ack_service_work_command(v_closed);assert public.get_service_work_command(null)->>'request_id'=v_work::text;
 assert public.close_service_work_command(v_work)->>'status'='closed';v_denied:=false;begin perform public.place_service_work(v_work);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;perform public.ack_service_work_command(v_work);
 -- Required typed inspection blocks start without changing work or occupancy.
 execute 'reset role';update public.business_branches set inspection_required=true where branch_id=v_branch;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Required inspection has no typed adapter');
 v_denied:=false;begin perform public.place_service_work(v_work);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 execute 'reset role';update public.business_branches set inspection_required=false where branch_id=v_branch;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);
 v_work:=gen_random_uuid();v_saved_start:=v_work;perform public.prepare_service_work(v_work,v_orders[1],'received','in_progress','Assigned worker actual service admission');v_result:=public.place_service_work(v_work);assert v_result->'result'->>'current_work_status'='in_progress'and v_result->'result'->>'physical_open'='true';assert public.place_service_work(v_work)=v_result;assert public.get_service_work_command(null)->>'request_id'=v_work::text;perform public.ack_service_work_command(v_work);
 -- Capacity1 rejects a different car/service while the first source is physically open.
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[2],'received','in_progress','Second car cannot consume occupied capacity');v_denied:=false;begin perform public.place_service_work(v_work);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[1],'in_progress','quality_check','Real assigned worker quality check');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);execute 'reset role';
 select * into strict v_span from private.service_resource_spans where walk_in_order_id=v_orders[1];assert v_span.ended_at is null;
 -- Read-only logical future query proves no estimated-time/overnight auto-release.
 v_facts:=private.service_resource_occupancy(v_branch,'wash',v_span.expected_end_at+interval'1 day',v_span.expected_end_at+interval'1 day 5 minutes',null,null,true);assert(v_facts->>'physical_now')::integer=1 and(v_facts->>'overrun_count')::integer=1;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);v_denied:=false;begin perform public.prepare_service_work(gen_random_uuid(),v_orders[1],'quality_check','delivered','Worker cannot skip completed or deliver');exception when insufficient_privilege or invalid_parameter_value then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_actor::text,true);v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[1],'quality_check','completed','Assigned worker certifies actual completion');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);
 assert public.get_service_work_command(v_saved_start)->'result'->>'current_work_status'='completed','Recovery cannot freeze old action state as current work';
 execute 'reset role';assert exists(select 1 from private.service_resource_spans where walk_in_order_id=v_orders[1]and ended_at is not null);
 v_denied:=false;begin update public.business_orders set status='in_progress'where order_id=v_orders[1];exception when raise_exception or object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[1],'completed','delivered','Management delivers actual completed service');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);
 for v_i in 1..3 loop
  v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_orders[2],case v_i when 1 then 'received'when 2 then 'in_progress'else 'quality_check'end,case v_i when 1 then 'in_progress'when 2 then 'quality_check'else 'completed'end,'Second actual service follows shared admission and work graph');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);
 end loop;execute 'reset role';
 select md5(string_agg(to_jsonb(i)::text,''order by invoice_id))into v_current_hash from public.business_invoices i where order_id=any(v_orders);assert v_current_hash=v_invoice_hash,'Work changed issued finance/commission/QR snapshot';
 assert not exists(select 1 from public.business_payment_events e join public.business_invoices i using(invoice_id)where i.order_id=any(v_orders));assert not exists(select 1 from private.canonical_loyalty_visits where order_id=any(v_orders));
 -- Actual booked-source fixture: one booking/order, no offline fake booking.
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v_future:=date_trunc('minute',clock_timestamp()at time zone'Africa/Cairo')+interval'2 minutes';
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(v_vehicle,v_customer,'QA','Paired service','QA-'||left(gen_random_uuid()::text,8));
 insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time,status,assigned_staff_ids)values(v_booking,v_customer,v_vehicle,v_branch,v_service,'Actual booked work QA',v_future::date,v_future::time,'confirmed',v_staff);
 insert into public.business_orders(order_id,order_number,booking_id,customer_id,branch_id,service_name,status,assigned_staff_ids)values(v_book_order,'QA-BOOK-'||v_book_order::text,v_booking,v_customer,v_branch,'Actual booked work QA','received',v_staff);
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);
 v_denied:=false;begin update public.business_orders set status='in_progress'where order_id=v_book_order;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Linked order cannot bypass booking admission';
 -- Dispatch changes invalidate saved execution context, without trapping own nonce recovery.
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'received','in_progress','Saved dispatch must not silently change');
 execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);update public.business_orders set assigned_staff_ids=array[v_actor]where order_id=v_book_order;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);v_denied:=false;begin perform public.place_service_work(v_work);exception when serialization_failure then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);update public.business_orders set assigned_staff_ids=v_staff where order_id=v_book_order;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'received','in_progress','Own stale command may safely close after unassignment');
 execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);update public.business_orders set assigned_staff_ids=array[v_actor]where order_id=v_book_order;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);v_result:=public.get_service_work_command(v_work);assert v_result->'result'->>'current_state_available'='false'and not(v_result->'result'?'current_work_status');perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);update public.business_orders set assigned_staff_ids=v_staff where order_id=v_book_order;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'received','in_progress','Canonical paired service start');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);
 v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'in_progress','quality_check','Actual paired service quality check');perform public.place_service_work(v_work);perform public.ack_service_work_command(v_work);
 v_denied:=false;begin update public.bookings set status='completed'where id=v_booking;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Booking-only completion bypassed live order quality check';
 v_denied:=false;begin update public.business_orders set status='completed'where order_id=v_book_order;exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied,'Order-only completion bypassed paired booking';
 execute 'reset role';assert exists(select 1 from public.bookings where id=v_booking and status='in_progress');assert exists(select 1 from public.business_orders where order_id=v_book_order and status='quality_check');assert exists(select 1 from private.service_resource_spans where booking_id=v_booking and ended_at is null);
 v_facts:=private.service_resource_occupancy(v_branch,'wash',clock_timestamp(),clock_timestamp()+interval'5 minutes',null,null,true);assert(v_facts->>'physical_now')::integer=1,'Paired source counted twice';
 update public.business_branches set inspection_required=true where branch_id=v_branch;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'quality_check','completed','Required actual inspections must be approved');v_denied:=false;begin perform public.place_service_work(v_work);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_work);perform public.ack_service_work_command(v_work);
 execute 'reset role';update public.business_branches set inspection_required=false where branch_id=v_branch;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_actor::text,true);v_work:=gen_random_uuid();perform public.prepare_service_work(v_work,v_book_order,'quality_check','completed','Atomic actual paired completion with one bay release');v_result:=public.place_service_work(v_work);assert v_result->'result'->>'current_work_status'='completed'and v_result->'result'->>'current_booking_status'='completed'and v_result->'result'->>'physical_open'='false';perform public.ack_service_work_command(v_work);execute 'reset role';
 assert(select count(*)from private.service_resource_spans where booking_id=v_booking)=1;assert exists(select 1 from private.service_resource_spans where booking_id=v_booking and ended_at is not null);
 select md5(string_agg(x::text,''order by x::text))into v_after from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;assert v_before=v_after,'Work kernel changed original identity or loyalty truth';
 raise notice 'PASS work kernel fixture: durable fences/replay, actual admission, assigned scope, quality occupancy, inspection gates, atomic paired completion, no restart/finance/loyalty changes';
end$$;
rollback;
