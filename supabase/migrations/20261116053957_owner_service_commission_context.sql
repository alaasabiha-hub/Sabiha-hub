begin;
create function private.get_owner_service_commission_context(p_branch uuid default null)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare b uuid;begin
 if not coalesce(private.has_live_invoice_session(),false)or private.active_staff_role()is distinct from'owner'then raise exception 'Current owner session required'using errcode='42501';end if;
 b:=p_branch;if b is null then select branch_id into b from public.business_branches where is_default and is_active;end if;
 perform private.require_owner_tax_branch(b);
 return jsonb_build_object('branch',b,'items',(select coalesce(jsonb_agg(jsonb_build_object('item_id',c.item_id,'name',c.name,'name_en',c.name_en,'policy',(select to_jsonb(x)from private.owner_service_commission_policies x where x.branch_id=b and x.item_id=c.item_id order by version desc limit 1))order by c.name,c.item_id),'[]')from public.business_catalog_items c where c.branch_id=b and c.item_type='service'and c.is_active),'staff',(select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')from public.staff_profiles s where s.is_active and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=b))),'basis','before_discount_ex_tax','future_only',true);end$$;
create function public.get_owner_service_commission_context(p_branch uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_service_commission_context(p_branch)$$;
revoke all on function private.get_owner_service_commission_context(uuid),public.get_owner_service_commission_context(uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_owner_service_commission_context(uuid),public.get_owner_service_commission_context(uuid)to authenticated;
notify pgrst,'reload schema';commit;
