begin;
do $$
declare v_owner uuid;v_manager uuid;v_worker uuid;v_customer uuid;b1 uuid:=gen_random_uuid();b2 uuid:=gen_random_uuid();o1 uuid:=gen_random_uuid();o2 uuid:=gen_random_uuid();o3 uuid:=gen_random_uuid();v jsonb;denied boolean;
begin
 select user_id into strict v_owner from public.staff_profiles where role='owner'and is_active limit 1;
 select user_id into strict v_manager from public.staff_profiles where role='manager'and is_active limit 1;
 select user_id into strict v_worker from public.staff_profiles where role='employee'and is_active limit 1;
 select id into strict v_customer from public.customers where not exists(select 1 from public.staff_profiles where user_id=customers.id)limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en)values(b1,'اختبار قارئ العمليات','Reader QA'),(b2,'اختبار فرع آخر','Other reader QA');
 insert into public.staff_branch_access(user_id,branch_id)values(v_manager,b1),(v_worker,b1);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 insert into public.business_orders(order_id,order_number,branch_id,service_name,order_type,status,assigned_staff_ids,customer_name,customer_phone)
 values(o1,'QA-'||o1,b1,'Own reader service','service','received',array[v_worker],'Private QA','QA-NOT-EXPOSED'),
 (o2,'QA-'||o2,b2,'Foreign reader service','service','received',array[v_worker],'Private QA','QA-NOT-EXPOSED'),
 (o3,'QA-'||o3,b1,'Unassigned reader service','service','received','{}','Private QA','QA-NOT-EXPOSED');
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',v_manager::text,true);
 v:=public.get_staff_operations();
 assert exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'=o1::text);
 assert exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'=o3::text);
 assert not exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'=o2::text);
 perform set_config('request.jwt.claim.sub',v_worker::text,true);v:=public.get_staff_operations();
 assert v->>'role'='employee'and v->'staff_directory'='[]'::jsonb;
 assert exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'=o1::text);
 assert not exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'in(o2::text,o3::text));
 assert not exists(select 1 from jsonb_array_elements(v->'orders')r where r?'customer_phone'or r?'customer_name'or r?'email'or r?'salary');
 assert not exists(select 1 from jsonb_array_elements(v->'bookings')r where r->'customers'<> 'null'::jsonb);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);v:=public.get_staff_operations();
 assert exists(select 1 from jsonb_array_elements(v->'orders')r where r->>'order_id'=o2::text);
 perform set_config('request.jwt.claim.sub',v_customer::text,true);denied:=false;
 begin perform public.get_staff_operations();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform set_config('request.jwt.claim.sub','',true);denied:=false;
 begin perform public.get_staff_operations();exception when insufficient_privilege then denied:=true;end;assert denied;
 execute 'reset role';
 assert not has_table_privilege('authenticated','public.business_orders','SELECT');
 assert not has_table_privilege('authenticated','public.business_orders','UPDATE');
 assert not has_function_privilege('anon','public.get_staff_operations()','EXECUTE');
 raise notice 'PASS scoped operations reader: manager branch, employee assignment/branch, owner, no private order contacts, customer/anon denial, table ACL unchanged';
end$$;
rollback;
