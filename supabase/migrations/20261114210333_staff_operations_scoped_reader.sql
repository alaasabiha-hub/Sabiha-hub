begin;
-- Keep business_orders inaccessible via direct table grants. Its legacy policies
-- are not the authorization contract for the operational screen.
create function private.get_staff_operations() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_role text:=private.active_staff_role();v_bookings jsonb;v_orders jsonb;v_staff jsonb;
begin
 if auth.uid()is null or v_role is null or v_role not in('owner','manager','employee')then
  raise exception 'Active scoped service staff required'using errcode='42501';
 end if;
 select coalesce(jsonb_agg(x.item order by x.service_day,x.at_time,x.id),'[]'::jsonb)into v_bookings from(
  select b.id,b.booking_date service_day,b.booking_time at_time,jsonb_build_object(
   'id',b.id,'service_name',b.service_name,'vehicle_type',b.vehicle_type,'booking_date',b.booking_date,'booking_time',b.booking_time,
   'status',b.status,'notes',b.notes,'quoted_price',b.quoted_price,'assigned_staff_ids',b.assigned_staff_ids,
   'customers',case when v_role in('owner','manager')then jsonb_build_object('full_name',c.full_name,'phone',c.phone)else null end) item
  from public.bookings b left join public.customers c on c.id=b.customer_id
  where coalesce(private.can_access_branch(b.branch_id),false)and(
   v_role in('owner','manager')or(v_role='employee'and auth.uid()=any(b.assigned_staff_ids)and b.status in('confirmed','in_progress')))
  order by b.booking_date,b.booking_time,b.id limit 1000
 )x;
 select coalesce(jsonb_agg(x.item order by x.created_at desc,x.order_id),'[]'::jsonb)into v_orders from(
  select o.order_id,o.created_at,jsonb_build_object(
   'order_id',o.order_id,'order_number',o.order_number,'service_name',o.service_name,'vehicle_type',o.vehicle_type,
   'plate_number',o.plate_number,'status',o.status,'order_type',o.order_type,'notes',o.notes,'created_at',o.created_at,
   'assigned_staff_ids',o.assigned_staff_ids) item
  from public.business_orders o
  where coalesce(private.can_access_branch(o.branch_id),false)and(
   (v_role in('owner','manager')and o.created_by is distinct from 'customer_booking')or
   (v_role='employee'and o.status in('received','in_progress','quality_check')and(
    auth.uid()=any(o.assigned_staff_ids)or exists(select 1 from public.bookings b where b.id=o.booking_id and b.branch_id=o.branch_id
     and auth.uid()=any(b.assigned_staff_ids)and(select count(*)from public.business_orders p where p.booking_id=b.id and p.order_type='service')=1))))
  order by o.created_at desc,o.order_id limit 100
 )x;
 if v_role in('owner','manager')then
  select coalesce(jsonb_agg(x.item order by x.full_name,x.user_id),'[]'::jsonb)into v_staff from(
   select s.user_id,s.full_name,jsonb_build_object('user_id',s.user_id,'full_name',s.full_name,'role',s.role) item
   from public.staff_profiles s where s.is_active and(v_role='owner'or exists(
    select 1 from public.staff_branch_access a where a.user_id=s.user_id and coalesce(private.can_access_branch(a.branch_id),false)))
   order by s.full_name,s.user_id limit 1000
  )x;
 else v_staff:='[]'::jsonb;end if;
 return jsonb_build_object('role',v_role,'bookings',v_bookings,'orders',v_orders,'staff_directory',v_staff,
  'scope','current_staff_role_branch_and_assignment','booking_limit',1000,'order_limit',100);
end$$;
revoke all on function private.get_staff_operations()from public,anon,service_role;
grant execute on function private.get_staff_operations()to authenticated;
create function public.get_staff_operations()returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_staff_operations()$$;
revoke all on function public.get_staff_operations()from public,anon,service_role;
grant execute on function public.get_staff_operations()to authenticated;
notify pgrst,'reload schema';
commit;
