begin;
-- Operational selection only. No salary/rates, past work, identity bridge or money writes.
create function private.get_offline_walk_in_context(p_registration uuid)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare r private.offline_customer_registration_requests;p private.offline_customer_profiles;c private.offline_customer_car_refs;b public.business_branches;role text:=private.active_staff_role();can_prepare boolean;cashier_name text;today date:=(clock_timestamp()at time zone'Africa/Cairo')::date;
begin
 if auth.uid()is null or role is null or role not in('owner','manager','employee')or p_registration is null then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 select * into r from private.offline_customer_registration_requests where request_id=p_registration;
 if not found or r.result->>'status'not in('created_unverified','reused_unverified')or not coalesce(private.can_cashier_branch(r.branch_id),false)or not coalesce(private.can_access_branch(r.branch_id),false)or not private.offline_walk_in_cashier(r.actor_id,r.branch_id)or(role='employee'and r.actor_id<>auth.uid())then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 select * into b from public.business_branches where branch_id=r.branch_id and is_active;
 select * into p from private.offline_customer_profiles where profile_id=(r.result->>'offline_profile_id')::uuid and created_branch_id=r.branch_id;
 select * into c from private.offline_customer_car_refs where car_ref_id=(r.result->>'car_ref_id')::uuid and profile_id=p.profile_id;
 if b.branch_id is null or p.profile_id is null or c.car_ref_id is null then raise exception 'Authorized current reception receipt required'using errcode='42501';end if;
 select full_name into cashier_name from public.staff_profiles where user_id=r.actor_id and is_active;
 can_prepare:=role in('owner','manager');
 return jsonb_build_object('registration_request_id',r.request_id,'branch',jsonb_build_object('id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en,'currency',b.currency),
 'subject',jsonb_build_object('profile_id',p.profile_id,'name',p.full_name,'car_ref_id',c.car_ref_id,'plate_number',c.plate_key,'brand',c.car_snapshot->>'brand','model',c.car_snapshot->>'model','identity_verified',false),
 'bound_cashier',jsonb_build_object('id',r.actor_id,'name',cashier_name),'can_prepare',can_prepare,
 'services',case when can_prepare then(select coalesce(jsonb_agg(jsonb_build_object('id',s.item_id,'name',s.name,'name_en',s.name_en,'vehicle_type',s.vehicle_type,'price',s.price,'duration_minutes',s.duration_minutes)order by s.name,s.item_id),'[]')from public.business_catalog_items s where s.branch_id=b.branch_id and s.item_type='service'and s.is_active and s.is_public and s.price>0 and s.price::text not in('NaN','Infinity','-Infinity')and s.name!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)')else'[]'::jsonb end,
 'workers',case when can_prepare then(select coalesce(jsonb_agg(jsonb_build_object('id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and e.currency='EGP'and e.starts_on<=today and(e.ends_on is null or e.ends_on>=today)and exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=b.branch_id))else'[]'::jsonb end,
 'capabilities',private.offline_walk_in_flags());
end$$;
revoke all on function private.get_offline_walk_in_context(uuid)from public,anon,service_role;
grant execute on function private.get_offline_walk_in_context(uuid)to authenticated;
create function public.get_offline_walk_in_context(p_registration uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_offline_walk_in_context(p_registration)$$;
revoke all on function public.get_offline_walk_in_context(uuid)from public,anon,service_role;
grant execute on function public.get_offline_walk_in_context(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
