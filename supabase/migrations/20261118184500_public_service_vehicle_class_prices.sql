begin;

-- Extend the existing anonymous, read-only public home payload with explicitly
-- public per-class rates for active/published services. This deliberately does
-- not expose the private price tables through the Data API.
create or replace function private.public_home_data()
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog'
as $function$
 select jsonb_build_object(
 'branches',coalesce((select jsonb_agg(jsonb_build_object(
 'branch_id',b.branch_id,'name_ar',b.name_ar,'name_en',b.name_en,'is_default',b.is_default,
 'address_ar',b.address_ar,'address_en',b.address_en,'maps_url',b.maps_url,
 'temporarily_closed',b.temporarily_closed,'time_zone',b.time_zone,'currency',b.currency,
 'hours',coalesce((select jsonb_agg(jsonb_build_object('weekday',h.weekday,'is_open',h.is_open,'opens_at',h.opens_at,'closes_at',h.closes_at) order by h.weekday) from public.business_branch_hours h where h.branch_id=b.branch_id),'[]'::jsonb),
 'exceptions',coalesce((select jsonb_agg(jsonb_build_object('exception_date',e.exception_date,'is_closed',e.is_closed,'opens_at',e.opens_at,'closes_at',e.closes_at)) from public.business_branch_exceptions e where e.branch_id=b.branch_id and e.exception_date >= (now() at time zone 'Africa/Cairo')::date and e.exception_date <= (now() at time zone 'Africa/Cairo')::date+30),'[]'::jsonb)) order by b.is_default desc,b.name_ar) from public.business_branches b where b.is_active),'[]'::jsonb),
 'offers',coalesce((select jsonb_agg(jsonb_build_object('offer_id',o.offer_id,'branch_id',o.branch_id,'name',o.name,'description',o.description,'offer_type',o.offer_type,'visits_required',o.visits_required,'reward_value',o.reward_value)) from public.business_offers o where o.is_active and o.is_public and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>now())),'[]'::jsonb),
 'catalog',coalesce((select jsonb_agg(jsonb_build_object(
   'item_id',c.item_id,'branch_id',c.branch_id,'item_type',c.item_type,
   'name',c.name,'name_en',c.name_en,'description',c.description,'description_en',c.description_en,
   'price',c.price,'duration_minutes',c.duration_minutes,
   'vehicle_class_prices',case when c.item_type='service' then coalesce((
     select jsonb_agg(jsonb_build_object(
       'class_code',vc.class_code,'name_ar',vc.name_ar,'name_en',vc.name_en,'price',vp.price
     ) order by vc.class_code)
     from private.business_vehicle_classes vc
     left join private.business_service_vehicle_prices vp
       on vp.class_code=vc.class_code and vp.item_id=c.item_id and vp.branch_id=c.branch_id
     where vc.is_active
   ),'[]'::jsonb) else '[]'::jsonb end
 ) order by c.name,c.item_id)
 from public.business_catalog_items c
 join public.business_branches b using(branch_id)
 where c.is_active and c.is_public and b.is_active),'[]'::jsonb));
$function$;

notify pgrst,'reload schema';
commit;
