-- SOURCE ONLY. Kernel + follow-up must be reviewed/applied in order before this rollback QA.
begin;
do $$
declare v_owner uuid;v_manager uuid;v_worker uuid;v_other uuid;v_customer uuid;v_branch uuid:=gen_random_uuid();v_foreign uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_vehicle uuid:=gen_random_uuid();v_booking uuid;v_order uuid;v_req uuid;v_context jsonb;v_queue jsonb;v_result jsonb;v_denied boolean;v_i integer;v_future timestamp;v_first_booking uuid;v_first_order uuid;v_old_hash text;v_new_hash text;
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_manager from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active limit 1;
 select user_id into strict v_other from public.staff_profiles where role='employee'and is_active and user_id<>v_worker limit 1;
 select id into strict v_customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id)limit 1;
 select md5(string_agg(x::text,''order by x::text))into v_old_hash from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار سياق العمل','Scoped work QA'),(v_foreign,'فرع آخر','Other work QA');
 update public.business_branch_hours set opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 insert into public.staff_branch_access(user_id,branch_id)values(v_manager,v_branch),(v_worker,v_branch),(v_other,v_branch);
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(v_service,v_branch,'service','Scoped work QA service','sedan',120,5,'wash',true,true);
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(v_vehicle,v_customer,'QA','Scoped actual booking','QA-'||left(gen_random_uuid()::text,8));
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_future:=date_trunc('minute',clock_timestamp()at time zone'Africa/Cairo')+interval'2 minutes';
 for v_i in 1..4 loop
  v_booking:=gen_random_uuid();v_order:=gen_random_uuid();
  insert into public.bookings(id,customer_id,vehicle_id,branch_id,catalog_item_id,service_name,booking_date,booking_time,status,assigned_staff_ids)values(v_booking,v_customer,v_vehicle,v_branch,v_service,'Actual booking-only assignment QA',case when v_i=1 then v_future::date else v_future::date+1 end,case when v_i=1 then v_future::time else(time'10:00'+make_interval(hours=>v_i))end,'confirmed',array[v_worker]);
  insert into public.business_orders(order_id,order_number,booking_id,customer_id,branch_id,service_name,status,assigned_staff_ids)values(v_order,'QA-SCOPED-'||v_order::text,v_booking,v_customer,v_branch,'Actual booking-only assignment QA','received','{}');
  if v_i=1 then
   v_first_booking:=v_booking;v_first_order:=v_order;
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);
   v_context:=public.get_service_work_context(null,v_booking);assert v_context->>'source_kind'='booking'and v_context->>'order_id'=v_order::text and v_context->>'can_prepare'='true';
   assert not(v_context?'salary')and not(v_context?'email')and not(v_context?'customer_phone')and not(v_context?'invoice_total')and not(v_context?'commission_total');
   v_queue:=public.list_service_work_queue(v_branch);assert jsonb_array_length(v_queue->'items')=1;
   for v_req in select gen_random_uuid()from generate_series(1,3)loop
    v_context:=public.get_service_work_context(v_order,null);perform public.prepare_service_work(v_req,v_order,v_context->>'work_status',v_context->>'next_status','Actual booking-assigned employee performs same-source work');v_result:=public.place_service_work(v_req);perform public.ack_service_work_command(v_req);
   end loop;
   assert v_result->'result'->>'current_booking_status'='completed'and v_result->'result'->>'current_work_status'='completed';execute 'reset role';
   assert(select cardinality(assigned_staff_ids)from public.business_orders where order_id=v_order)=0,'Operational authority copied/reassigned wages';
  elsif v_i=2 then
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);v_req:=gen_random_uuid();perform public.prepare_service_work(v_req,v_order,'received','in_progress','Management preparation freezes actual booking dispatch');execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);
   update public.bookings set assigned_staff_ids=array[v_other]where id=v_booking;
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);v_denied:=false;begin perform public.place_service_work(v_req);exception when serialization_failure then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_req);perform public.ack_service_work_command(v_req);execute 'reset role';
   assert not exists(select 1 from private.service_work_ledger where command_id=v_req);assert(select status from public.business_orders where order_id=v_order)='received';
  elsif v_i=3 then
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);v_req:=gen_random_uuid();perform public.prepare_service_work(v_req,v_order,'received','in_progress','Removed booking assignment must lose execution authority');execute 'reset role';perform set_config('request.jwt.claim.sub',v_owner::text,true);update public.bookings set assigned_staff_ids=array[v_other]where id=v_booking;
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_worker::text,true);v_denied:=false;begin perform public.place_service_work(v_req);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;assert public.get_service_work_command(v_req)->'result'->>'current_state_available'='false';perform public.close_service_work_command(v_req);perform public.ack_service_work_command(v_req);execute 'reset role';
  else
   -- Legacy v1 prepared data is recoverable/closable, never guessed into v2 execution.
   v_req:=gen_random_uuid();insert into private.service_work_commands(request_id,actor_id,order_id,branch_id,payload,source_snapshot,state)values(v_req,v_manager,v_order,v_branch,jsonb_build_object('order_id',v_order,'expected_status','received','next_status','in_progress','reason','Legacy saved command context'),jsonb_build_object('branch_id',v_branch,'booking_id',v_booking,'staff_ids','[]'::jsonb),'prepared');
   execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);v_denied:=false;begin perform public.place_service_work(v_req);exception when serialization_failure then v_denied:=true;end;assert v_denied;perform public.close_service_work_command(v_req);perform public.ack_service_work_command(v_req);execute 'reset role';
  end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
 end loop;
 begin
  -- Synthetic trusted-server historical rows exercise NULL-safe queue ordering only.
  -- No admission/work/payment claim: both rows immediately roll back.
  v_order:=gen_random_uuid();v_booking:=gen_random_uuid();
  insert into public.business_orders(order_id,order_number,branch_id,service_name,status,assigned_staff_ids)values(v_order,'QA-QUEUED-'||v_order::text,v_branch,'Received unpaired order reader fixture','received',array[v_worker]);
  perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claim.role','',true);perform set_config('request.jwt.claims','{}',true);
  insert into public.business_orders(order_id,order_number,branch_id,service_name,status,assigned_staff_ids,created_by)values(v_booking,'QA-HISTORY-'||v_booking::text,v_branch,'Historical active reader fixture','in_progress',array[v_worker],'qa_reader_history_fixture');
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);v_queue:=public.list_service_work_queue(v_branch);assert v_queue->'items'->0->>'order_id'=v_booking::text,'NULL received physical flag sorted ahead of actual active work';
  raise exception 'rollback queue reader fixture'using errcode='PZ094';
 exception when sqlstate'PZ094'then null;end;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_customer::text,true);v_denied:=false;begin perform public.get_service_work_context(v_first_order,null);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_other::text,true);v_denied:=false;begin perform public.get_service_work_context(v_first_order,null);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 perform set_config('request.jwt.claim.sub',v_worker::text,true);v_denied:=false;begin perform public.list_service_work_queue(v_foreign);exception when insufficient_privilege then v_denied:=true;end;assert v_denied;
 execute 'reset role';
 assert not has_function_privilege('authenticated','private.service_work_source_snapshot(uuid)','EXECUTE');assert not exists(select 1 from private.canonical_loyalty_visits where order_id=v_first_order);
 select md5(string_agg(x::text,''order by x::text))into v_new_hash from(select to_jsonb(t)x from auth.users t union all select to_jsonb(t)from public.customers t union all select to_jsonb(t)from public.business_loyalty_transactions t union all select to_jsonb(t)from private.canonical_loyalty_visits t)x;assert v_old_hash=v_new_hash;
 raise notice 'PASS scoped work context fixture: actual booking-only assignment, no wage/identity copy, fresh dispatch denial, legacy snapshot fence, own-job/branch privacy';
end$$;
rollback;
