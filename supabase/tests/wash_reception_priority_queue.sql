-- Fixture-only historical confirmed visits; no production access. Entire test rolls back.
begin;
do $$
<<qa>>
declare owner_id uuid;manager_id uuid;employee_id uuid;c uuid;branch uuid:=gen_random_uuid();other_branch uuid:=gen_random_uuid();
 normal_id uuid:=gen_random_uuid();vip_id uuid:=gen_random_uuid();later_id uuid:=gen_random_uuid();foreign_id uuid:=gen_random_uuid();future_id uuid:=gen_random_uuid();
 request_id uuid:=gen_random_uuid();template public.bookings%rowtype;item jsonb;result jsonb;queue jsonb;rejected boolean;prior_time timestamptz;
begin
 select user_id into strict owner_id from public.staff_profiles where role='owner' and is_active limit 1;
 select user_id into strict manager_id from public.staff_profiles where role='manager' and is_active limit 1;
 select user_id into strict employee_id from public.staff_profiles where role='employee' and is_active limit 1;
 select id into strict c from public.customers where not exists(select 1 from public.staff_profiles s where s.user_id=customers.id) limit 1;
 select * into strict template from public.bookings limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en) values(branch,'اختبار الاستقبال','Reception QA'),(other_branch,'فرع آخر','Other reception QA');
 insert into public.staff_branch_access(user_id,branch_id) values(manager_id,branch),(employee_id,branch);
 -- Only synthetic historical fixture inserts bypass booking-time triggers. RPCs below
 -- run with normal triggers/RLS enabled and never alter booking workflow state.
 perform set_config('session_replication_role','replica',true);
 for item in select jsonb_build_object('id',id,'customer_id',c,'branch_id',case when id=foreign_id then other_branch else branch end,
   'vehicle_id',null,'catalog_item_id',null,'display_number',null,'booking_date',(now() at time zone 'Africa/Cairo')::date+case when id=future_id then 1 else 0 end,
   'booking_time','10:00:00','status','confirmed','assigned_staff_ids',case when id=normal_id then jsonb_build_array(employee_id) else '[]'::jsonb end)
   from unnest(array[normal_id,vip_id,later_id,foreign_id,future_id]) id loop
  insert into public.bookings select (jsonb_populate_record(null::public.bookings,to_jsonb(template)||item)).*;
 end loop;
 perform set_config('session_replication_role','origin',true);
 assert not has_table_privilege('authenticated','private.wash_reception_entries','UPDATE');
 execute 'set local role anon';rejected:=false;begin perform public.get_wash_reception_queue(branch);exception when insufficient_privilege then rejected:=true;end;assert rejected;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',c::text,true);rejected:=false;begin perform public.get_wash_reception_queue(branch);exception when insufficient_privilege then rejected:=true;end;assert rejected;
 perform set_config('request.jwt.claim.sub',employee_id::text,true);rejected:=false;begin perform public.update_wash_reception(request_id,normal_id,'arrive','vip',0,'Customer intake');exception when insufficient_privilege then rejected:=true;end;assert rejected;
 queue:=public.get_wash_reception_queue(branch);assert jsonb_array_length(queue)=1 and queue->0->>'id'=normal_id::text,'Employee queue leaked unassigned visits';
 perform set_config('request.jwt.claim.sub',manager_id::text,true);rejected:=false;begin perform public.update_wash_reception(request_id,foreign_id,'arrive','vip',0,'Customer intake');exception when insufficient_privilege then rejected:=true;end;assert rejected;
 rejected:=false;begin perform public.update_wash_reception(gen_random_uuid(),future_id,'arrive','normal',0,'Future intake');exception when object_not_in_prerequisite_state then rejected:=true;end;assert rejected;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);perform public.update_wash_reception(gen_random_uuid(),foreign_id,'arrive','normal',0,'Owner branch intake');assert jsonb_array_length(public.get_wash_reception_queue(other_branch))=1;perform set_config('request.jwt.claim.sub',manager_id::text,true);
 result:=public.update_wash_reception(request_id,normal_id,'arrive','normal',0,'Customer intake');prior_time:=(result->>'arrived_at')::timestamptz;
 assert public.update_wash_reception(request_id,normal_id,'arrive','normal',0,'Customer intake')=result,'Arrival retry changed its time';
 rejected:=false;begin perform public.update_wash_reception(request_id,normal_id,'arrive','vip',0,'Customer intake');exception when invalid_parameter_value then rejected:=true;end;assert rejected;
 perform public.update_wash_reception(gen_random_uuid(),vip_id,'arrive','vip',0,'Approved VIP intake');
 perform public.update_wash_reception(gen_random_uuid(),later_id,'arrive','normal',0,'Customer intake');
 queue:=public.get_wash_reception_queue(branch);assert queue->0->>'id'=vip_id::text and queue->1->>'id'=normal_id::text and queue->2->>'id'=later_id::text,'VIP/FIFO order incorrect';
 rejected:=false;begin perform public.update_wash_reception(gen_random_uuid(),normal_id,'priority','vip',0,'Approved VIP upgrade');exception when serialization_failure then rejected:=true;end;assert rejected,'Stale revision changed priority';
 result:=public.update_wash_reception(gen_random_uuid(),normal_id,'priority','vip',1,'Approved VIP upgrade');assert (result->>'arrived_at')::timestamptz=prior_time,'Changing priority reset arrival FIFO';
 execute 'reset role';
 assert (select status='confirmed' from public.bookings where id=normal_id),'Priority advanced booking workflow';
 assert exists(select 1 from public.business_audit_log where entity_id=normal_id::text and action='wash_reception_priority' and before_data->>'priority'='normal' and after_data->>'priority'='vip');
 assert (select count(*)=3 from private.wash_reception_entries where branch_id=branch);
 update private.wash_reception_entries set branch_id=other_branch where booking_id=normal_id;
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',manager_id::text,true);
 rejected:=false;begin perform public.update_wash_reception(gen_random_uuid(),normal_id,'priority','normal',2,'Branch review required');exception when object_not_in_prerequisite_state then rejected:=true;end;assert rejected,'Mismatched reception branch allowed mutation';
 queue:=public.get_wash_reception_queue(branch);assert exists(select 1 from jsonb_array_elements(queue) as q where q->>'id'=normal_id::text and (q->>'branch_conflict')::boolean);
 execute 'reset role';
 raise notice 'PASS owner/manager scope, anonymous/customer/employee denial, branch/assignment isolation, today guard, stable arrival, request/revision guard, VIP/FIFO and audit';
end;$$;
rollback;
