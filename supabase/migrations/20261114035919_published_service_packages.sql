-- Additive presentation metadata; historical offers/services remain intact.
alter table public.business_catalog_items add column name_en text,add column description_en text;
alter table public.business_offers add column catalog_item_id uuid references public.business_catalog_items(item_id),add column name_en text,add column description_en text,add column presentation_category text check(presentation_category in ('package','limited','reward')),add column compare_price numeric(12,2) check(compare_price>0),add column image_asset text check(image_asset in ('wash','interior','complete'));
grant select(name_en,description_en) on public.business_catalog_items to authenticated;
grant select(catalog_item_id,name_en,description_en,presentation_category,compare_price,image_asset,updated_at) on public.business_offers to authenticated;
create table public.business_promotion_requests(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now());
alter table public.business_promotion_requests enable row level security;
revoke all on public.business_promotion_requests from public,anon,authenticated;
grant all on public.business_promotion_requests to service_role;
create function private.get_public_promotions() returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('offers',coalesce((select jsonb_agg(jsonb_build_object('offer_id',o.offer_id,'branch_id',o.branch_id,'name',o.name,'name_en',o.name_en,'description',o.description,'description_en',o.description_en,'category',coalesce(o.presentation_category,case when o.offer_type='visit_reward' then 'reward' else 'limited' end),'visits_required',o.visits_required,'service_id',c.item_id,'price',c.price,'compare_price',case when o.compare_price>c.price then o.compare_price end,'image_asset',coalesce(o.image_asset,'wash')) order by o.created_at desc) from public.business_offers o join public.business_branches b on b.branch_id=o.branch_id left join public.business_catalog_items c on c.item_id=o.catalog_item_id and c.branch_id=o.branch_id and c.is_active and c.is_public and c.item_type='service' where b.is_default and b.is_active and o.is_active and o.is_public and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>now()) and (o.target_customer_ids is null or auth.uid()=any(o.target_customer_ids)) and (o.catalog_item_id is null or c.item_id is not null) and concat_ws(' ',c.name,c.name_en,o.name,o.name_en) !~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'),'[]'::jsonb));
$$;
create function public.get_public_promotions() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_public_promotions();$$;
revoke all on function private.get_public_promotions(),public.get_public_promotions() from public;
grant execute on function private.get_public_promotions(),public.get_public_promotions() to anon,authenticated;
create function private.get_owner_promotions() returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare b uuid;begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_default and is_active;
 return jsonb_build_object('branch_id',b,'services',coalesce((select jsonb_agg(to_jsonb(c) order by name) from public.business_catalog_items c where branch_id=b and item_type='service'),'[]'::jsonb),'offers',coalesce((select jsonb_agg(to_jsonb(o) order by created_at desc) from public.business_offers o where branch_id=b),'[]'::jsonb));
end$$;
create function private.save_service_promotion(p_request uuid,p_service jsonb,p_offer jsonb default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare b uuid;sid uuid;oid uuid;old_service public.business_catalog_items%rowtype;old_offer public.business_offers%rowtype;prior public.business_promotion_requests%rowtype;payload jsonb;result jsonb;v_price numeric;v_duration integer;v_name text;begin
 if auth.uid() is null or private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or jsonb_typeof(p_service)<>'object' then raise exception 'Service and stable request required';end if;
 payload:=jsonb_build_object('service',p_service,'offer',p_offer);
 if length(payload::text)>20000 then raise exception 'Promotion payload too large';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into prior from public.business_promotion_requests where request_id=p_request;
 if found then if prior.actor_id<>auth.uid() or prior.payload<>payload then raise exception 'Request payload mismatch';end if;return prior.result;end if;
 select branch_id into b from public.business_branches where is_default and is_active;
 if b is null then raise exception 'Active default branch required';end if;
 v_name:=trim(p_service->>'name');v_price:=(p_service->>'price')::numeric;v_duration:=(p_service->>'duration_minutes')::integer;
 if v_name is null or length(v_name) not between 2 and 120 or v_name ~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)' or v_price is null or v_price<0 or v_price>99999999.99 or v_price<>round(v_price,2) or v_duration is null or v_duration not between 5 and 480 or coalesce(p_service->>'resource_key','wash') not in ('wash','polish') then raise exception 'Invalid current service, price or duration';end if;
 sid:=nullif(p_service->>'item_id','')::uuid;
 if sid is null then
  sid:=gen_random_uuid();insert into public.business_catalog_items(item_id,branch_id,item_type,name,name_en,description,description_en,price,duration_minutes,resource_key,is_active,is_public) values(sid,b,'service',v_name,nullif(trim(p_service->>'name_en'),''),p_service->>'description',p_service->>'description_en',v_price,v_duration,coalesce(p_service->>'resource_key','wash'),coalesce((p_service->>'is_active')::boolean,true),coalesce((p_service->>'is_public')::boolean,true));
 else
  select * into old_service from public.business_catalog_items where item_id=sid for update;
  if not found or old_service.branch_id<>b or old_service.item_type<>'service' then raise exception 'Default branch service required';end if;
  if old_service.updated_at is distinct from (p_service->>'updated_at')::timestamptz then raise exception 'Service changed; refresh before editing' using errcode='40001';end if;
  update public.business_catalog_items c set name=trim(p_service->>'name'),name_en=nullif(trim(p_service->>'name_en'),''),description=p_service->>'description',description_en=p_service->>'description_en',price=v_price,duration_minutes=v_duration,resource_key=coalesce(p_service->>'resource_key','wash'),is_active=coalesce((p_service->>'is_active')::boolean,true),is_public=coalesce((p_service->>'is_public')::boolean,true),updated_at=clock_timestamp() where c.item_id=sid;
 end if;
 if p_offer is not null then
  if jsonb_typeof(p_offer)<>'object' or length(trim(p_offer->>'name')) not between 2 and 120 or coalesce(p_offer->>'category','package') not in ('package','limited','reward') or coalesce(p_offer->>'image_asset','wash') not in ('wash','interior','complete') then raise exception 'Invalid offer';end if;
  if nullif(p_offer->>'compare_price','') is not null and ((p_offer->>'compare_price')::numeric<=v_price or (p_offer->>'compare_price')::numeric>99999999.99 or (p_offer->>'compare_price')::numeric<>round((p_offer->>'compare_price')::numeric,2)) then raise exception 'Comparison price must exceed actual price';end if;
  oid:=nullif(p_offer->>'offer_id','')::uuid;
  if oid is null then
   oid:=gen_random_uuid();insert into public.business_offers(offer_id,branch_id,name,name_en,description,description_en,offer_type,catalog_item_id,presentation_category,compare_price,image_asset,is_active,is_public,starts_at,ends_at) values(oid,b,trim(p_offer->>'name'),p_offer->>'name_en',p_offer->>'description',p_offer->>'description_en','product_bundle',sid,coalesce(p_offer->>'category','package'),nullif(p_offer->>'compare_price','')::numeric,coalesce(p_offer->>'image_asset','wash'),coalesce((p_offer->>'is_active')::boolean,false),coalesce((p_offer->>'is_public')::boolean,false),nullif(p_offer->>'starts_at','')::timestamptz,nullif(p_offer->>'ends_at','')::timestamptz);
  else
   select * into old_offer from public.business_offers where offer_id=oid for update;
   if not found or old_offer.branch_id<>b then raise exception 'Default branch offer required';end if;
   if old_offer.updated_at is distinct from (p_offer->>'updated_at')::timestamptz then raise exception 'Offer changed; refresh before editing' using errcode='40001';end if;
   update public.business_offers o set name=trim(p_offer->>'name'),name_en=p_offer->>'name_en',description=p_offer->>'description',description_en=p_offer->>'description_en',catalog_item_id=sid,presentation_category=coalesce(p_offer->>'category','package'),compare_price=nullif(p_offer->>'compare_price','')::numeric,image_asset=coalesce(p_offer->>'image_asset','wash'),is_active=coalesce((p_offer->>'is_active')::boolean,false),is_public=coalesce((p_offer->>'is_public')::boolean,false),starts_at=nullif(p_offer->>'starts_at','')::timestamptz,ends_at=nullif(p_offer->>'ends_at','')::timestamptz,updated_at=clock_timestamp() where o.offer_id=oid;
  end if;
 end if;
 result:=jsonb_build_object('service_id',sid,'offer_id',oid);
 insert into public.business_promotion_requests(request_id,actor_id,payload,result) values(p_request,auth.uid(),payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'save_service_promotion','business_catalog_items',sid::text,b,jsonb_build_object('price_egp',v_price,'offer_id',oid));return result;
end$$;
create function public.get_owner_promotions() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_promotions();$$;
create function public.save_service_promotion(p_request uuid,p_service jsonb,p_offer jsonb default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_service_promotion(p_request,p_service,p_offer);$$;
revoke all on function private.get_owner_promotions(),public.get_owner_promotions(),private.save_service_promotion(uuid,jsonb,jsonb),public.save_service_promotion(uuid,jsonb,jsonb) from public,anon;
grant execute on function private.get_owner_promotions(),public.get_owner_promotions(),private.save_service_promotion(uuid,jsonb,jsonb),public.save_service_promotion(uuid,jsonb,jsonb) to authenticated;
notify pgrst,'reload schema';
