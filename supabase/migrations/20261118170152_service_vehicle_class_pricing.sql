begin;

-- Vehicle classes and branch-specific service prices are private by design.
-- Service rows and historical invoices remain in place; no legacy price is
-- copied to a class until an owner explicitly saves it.
create table private.business_vehicle_classes (
  class_code text primary key check (class_code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name_ar text not null check (length(trim(name_ar)) between 1 and 80),
  name_en text not null check (length(trim(name_en)) between 1 and 80),
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
insert into private.business_vehicle_classes(class_code,name_ar,name_en)
values ('sedan','سيدان','Sedan'),('suv','SUV / دفع رباعي','SUV / 4WD');
alter table private.business_vehicle_classes enable row level security;
revoke all on private.business_vehicle_classes from public,anon,authenticated,service_role;

create table private.business_service_vehicle_prices (
  branch_id uuid not null references public.business_branches(branch_id),
  item_id uuid not null references public.business_catalog_items(item_id),
  class_code text not null references private.business_vehicle_classes(class_code),
  price numeric(12,2) not null check (price >= 0 and price::text not in ('NaN','Infinity','-Infinity')),
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (branch_id,item_id,class_code)
);
alter table private.business_service_vehicle_prices enable row level security;
revoke all on private.business_service_vehicle_prices from public,anon,authenticated,service_role;
create index business_service_vehicle_prices_item on private.business_service_vehicle_prices(item_id,branch_id);

-- Offline walk-in cars have a separate private registry. Keep their class in
-- an audited owner mapping instead of mutating the immutable intake snapshot.
create table private.business_offline_vehicle_classes (
  car_ref_id uuid primary key references private.offline_customer_car_refs(car_ref_id),
  branch_id uuid not null references public.business_branches(branch_id),
  class_code text not null references private.business_vehicle_classes(class_code),
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default clock_timestamp()
);
alter table private.business_offline_vehicle_classes enable row level security;
revoke all on private.business_offline_vehicle_classes from public,anon,authenticated,service_role;

create function private.cashier_vehicle_class_code(p_vehicle uuid)
returns text language plpgsql stable security definer set search_path=pg_catalog as $$
declare result text;
begin
 select v.vehicle_class_code into result from public.vehicles v where v.id=p_vehicle;
 if result is null then select x.class_code into result from private.business_offline_vehicle_classes x where x.car_ref_id=p_vehicle; end if;
 if not exists(select 1 from private.business_vehicle_classes where class_code=result and is_active) then return null; end if;
 return result;
end $$;
revoke all on function private.cashier_vehicle_class_code(uuid) from public,anon,authenticated,service_role;

create function private.get_cashier_vehicle_service_prices(p_branch uuid,p_draft uuid,p_version integer)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;b private.cashier_draft_subjects;v_class_code text;class_row private.business_vehicle_classes;prices jsonb;
begin
 actor:=private.cashier_cart_actor(p_branch);
 select * into d from private.cashier_reviewed_drafts where draft_id=p_draft and actor_id=actor and branch_id=p_branch;
 if not found or d.version<>p_version then raise exception 'Current cashier draft required' using errcode='40001';end if;
 select * into b from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor and branch_id=p_branch and draft_version=d.version;
 if not found then return jsonb_build_object('ready',false,'draft_version',d.version);end if;
 v_class_code:=private.cashier_vehicle_class_code(b.car_id);
 if v_class_code is null then return jsonb_build_object('ready',false,'draft_version',d.version,'binding_version',b.version);end if;
 select * into class_row from private.business_vehicle_classes c where c.class_code=v_class_code and c.is_active;
 select coalesce(jsonb_object_agg(p.item_id::text,p.price),'{}'::jsonb) into prices
 from private.business_service_vehicle_prices p join public.business_catalog_items i on i.item_id=p.item_id and i.branch_id=p.branch_id
 where p.branch_id=p_branch and p.class_code=v_class_code and i.item_type='service' and i.is_active;
 return jsonb_build_object('ready',true,'draft_version',d.version,'binding_version',b.version,'vehicle_class_code',v_class_code,
  'vehicle_class_name_ar',class_row.name_ar,'vehicle_class_name_en',class_row.name_en,'prices',prices);
end $$;
create function public.get_cashier_vehicle_service_prices(p_branch uuid,p_draft uuid,p_version integer) returns jsonb
language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_vehicle_service_prices(p_branch,p_draft,p_version)$$;
revoke all on function private.get_cashier_vehicle_service_prices(uuid,uuid,integer),public.get_cashier_vehicle_service_prices(uuid,uuid,integer) from public,anon;
grant execute on function private.get_cashier_vehicle_service_prices(uuid,uuid,integer),public.get_cashier_vehicle_service_prices(uuid,uuid,integer) to authenticated;

alter table public.vehicles add column vehicle_class_code text references private.business_vehicle_classes(class_code);
alter table public.bookings add column vehicle_class_code text references private.business_vehicle_classes(class_code);
alter table public.business_orders add column vehicle_class_code text references private.business_vehicle_classes(class_code);
alter table public.business_invoices add column vehicle_class_code text references private.business_vehicle_classes(class_code);

create table private.owner_vehicle_price_commands(
  request_id uuid primary key, actor_id uuid not null references auth.users(id),
  payload jsonb not null, result jsonb not null, created_at timestamptz not null default clock_timestamp()
);
create table private.business_service_vehicle_price_history (
  request_id uuid not null references private.owner_vehicle_price_commands(request_id),
  branch_id uuid not null, item_id uuid not null, class_code text not null,
  price numeric(12,2) not null, changed_by uuid not null references auth.users(id),
  changed_at timestamptz not null default clock_timestamp(),
  primary key(request_id,class_code)
);
alter table private.owner_vehicle_price_commands enable row level security;
revoke all on private.owner_vehicle_price_commands from public,anon,authenticated,service_role;
alter table private.business_service_vehicle_price_history enable row level security;
revoke all on private.business_service_vehicle_price_history from public,anon,authenticated,service_role;
create trigger immutable_vehicle_price_history before update or delete on private.business_service_vehicle_price_history
for each row execute function private.owner_tax_immutable();
create trigger immutable_owner_vehicle_price_commands before update or delete on private.owner_vehicle_price_commands
for each row execute function private.owner_tax_immutable();

create function private.try_service_vehicle_price(p_branch uuid,p_item uuid,p_vehicle uuid)
returns numeric language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_class_code text;result numeric;
begin
 v_class_code:=private.cashier_vehicle_class_code(p_vehicle);
 if v_class_code is null then return null; end if;
 select p.price into result from private.business_service_vehicle_prices p
 join private.business_vehicle_classes c using(class_code)
 join public.business_catalog_items i on i.item_id=p.item_id and i.branch_id=p.branch_id
 where p.branch_id=p_branch and p.item_id=p_item and p.class_code=v_class_code
   and c.is_active and i.item_type='service' and i.is_active;
 return result;
end $$;
revoke all on function private.try_service_vehicle_price(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function private.service_vehicle_price(p_branch uuid,p_item uuid,p_vehicle uuid)
returns numeric language plpgsql stable security definer set search_path=pg_catalog as $$
declare result numeric;
begin
 result:=private.try_service_vehicle_price(p_branch,p_item,p_vehicle);
 if result is null then raise exception 'An active price for this service and vehicle class is required' using errcode='55000'; end if;
 return result;
end $$;
revoke all on function private.service_vehicle_price(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function private.get_customer_vehicle_class_options()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then
  raise exception 'Customer sign-in required' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(jsonb_build_object('class_code',class_code,'name_ar',name_ar,'name_en',name_en) order by class_code)
  from private.business_vehicle_classes where is_active),'[]'::jsonb);
end $$;
create function public.get_customer_vehicle_class_options() returns jsonb language sql security invoker set search_path=pg_catalog as $$
 select private.get_customer_vehicle_class_options() $$;
revoke all on function private.get_customer_vehicle_class_options(),public.get_customer_vehicle_class_options() from public,anon;
grant execute on function private.get_customer_vehicle_class_options(),public.get_customer_vehicle_class_options() to authenticated;

create function private.get_customer_service_price_options(p_branch uuid,p_vehicle uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare v_class_code text;class_ar text;class_en text;services jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer sign-in required' using errcode='42501'; end if;
 select v.vehicle_class_code,c.name_ar,c.name_en into v_class_code,class_ar,class_en
 from public.vehicles v left join private.business_vehicle_classes c on c.class_code=v.vehicle_class_code and c.is_active
 where v.id=p_vehicle and v.customer_id=auth.uid();
 if not found then raise exception 'Customer-owned vehicle required' using errcode='42501'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('item_id',i.item_id,'price',p.price,'class_code',v_class_code,'class_name_ar',class_ar,'class_name_en',class_en)
   order by i.name,i.item_id),'[]'::jsonb) into services
 from public.business_catalog_items i left join private.business_service_vehicle_prices p
   on p.branch_id=i.branch_id and p.item_id=i.item_id and p.class_code=v_class_code
 where i.branch_id=p_branch and i.item_type='service' and i.is_active and i.is_public
   and i.name !~* '(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)';
 return jsonb_build_object('branch_id',p_branch,'vehicle_id',p_vehicle,'vehicle_class_code',v_class_code,
   'vehicle_class_name_ar',class_ar,'vehicle_class_name_en',class_en,'services',services);
end $$;
create function public.get_customer_service_price_options(p_branch uuid,p_vehicle uuid) returns jsonb
language sql security invoker set search_path=pg_catalog as $$select private.get_customer_service_price_options(p_branch,p_vehicle)$$;
revoke all on function private.get_customer_service_price_options(uuid,uuid),public.get_customer_service_price_options(uuid,uuid) from public,anon;
grant execute on function private.get_customer_service_price_options(uuid,uuid),public.get_customer_service_price_options(uuid,uuid) to authenticated;

create function private.save_owner_vehicle_class(p_request uuid,p_code text,p_name_ar text,p_name_en text,p_active boolean,p_reason text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;oldrow private.business_vehicle_classes;prior private.owner_vehicle_price_commands;payload jsonb;result jsonb;
begin
 if auth.uid() is null or not coalesce(private.has_live_invoice_session(),false) or private.active_staff_role() is distinct from 'owner' then raise exception 'Current owner session required' using errcode='42501'; end if;
 actor:=auth.uid();
 if p_request is null or p_code !~ '^[a-z][a-z0-9_]{1,39}$' or length(trim(coalesce(p_name_ar,''))) not between 1 and 80 or length(trim(coalesce(p_name_en,''))) not between 1 and 80 or p_active is null or length(trim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Valid class and audit reason required' using errcode='22023'; end if;
 payload:=jsonb_build_object('code',p_code,'name_ar',trim(p_name_ar),'name_en',trim(p_name_en),'active',p_active,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('vehicle-class:'||p_request,0));
 select * into prior from private.owner_vehicle_price_commands where request_id=p_request;
 if found then
  if prior.actor_id=actor and prior.payload=payload then return prior.result; end if;
  raise exception 'Request ID already used for another command' using errcode='22023';
 end if;
 select * into oldrow from private.business_vehicle_classes where class_code=p_code for update;
 insert into private.business_vehicle_classes(class_code,name_ar,name_en,is_active) values(p_code,trim(p_name_ar),trim(p_name_en),p_active)
 on conflict(class_code) do update set name_ar=excluded.name_ar,name_en=excluded.name_en,is_active=excluded.is_active,updated_at=clock_timestamp();
 result:=jsonb_build_object('class_code',p_code,'is_active',p_active,'historical_rows_retained',true);
 insert into private.owner_vehicle_price_commands values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,reason,before_data,after_data)
 values(actor::text,actor,'owner_vehicle_class_saved','vehicle_class',p_code,trim(p_reason),to_jsonb(oldrow),result);
 return result;
end $$;
create function public.save_owner_vehicle_class(p_request uuid,p_code text,p_name_ar text,p_name_en text,p_active boolean,p_reason text)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_vehicle_class(p_request,p_code,p_name_ar,p_name_en,p_active,p_reason)$$;
revoke all on function private.save_owner_vehicle_class(uuid,text,text,text,boolean,text),public.save_owner_vehicle_class(uuid,text,text,text,boolean,text) from public,anon;
grant execute on function private.save_owner_vehicle_class(uuid,text,text,text,boolean,text),public.save_owner_vehicle_class(uuid,text,text,text,boolean,text) to authenticated;

create function private.save_owner_catalog_item_with_vehicle_prices(p_request uuid,p_branch uuid,p_item uuid,p_expected_revision text,p_spec jsonb,p_reason text,p_vehicle_prices jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;prior private.owner_vehicle_price_commands;payload jsonb;catalogue_result jsonb;entry jsonb;class_count integer;expected_count integer;result jsonb;
begin
 actor:=private.require_owner_tax_branch(p_branch);
 if p_request is null or jsonb_typeof(p_vehicle_prices) is distinct from 'array' or octet_length(p_vehicle_prices::text)>65536 then raise exception 'Explicit vehicle price list required' using errcode='22023'; end if;
 payload:=jsonb_build_object('branch',p_branch,'item',p_item,'revision',p_expected_revision,'spec',p_spec,'reason',trim(p_reason),'vehicle_prices',p_vehicle_prices);
 perform pg_advisory_xact_lock(hashtextextended('owner-vehicle-price-request:'||p_request,0));
 select * into prior from private.owner_vehicle_price_commands where request_id=p_request;
 if found then if prior.actor_id<>actor or prior.payload<>payload then raise exception 'Immutable vehicle pricing request' using errcode='22023'; end if; return prior.result; end if;
 if p_spec->>'item_type'='service' then
  if (select count(*) from jsonb_array_elements(p_vehicle_prices))<>(select count(distinct value->>'class_code') from jsonb_array_elements(p_vehicle_prices)) then raise exception 'Duplicate vehicle class price' using errcode='22023'; end if;
  select count(*) into expected_count from private.business_vehicle_classes where is_active;
  if jsonb_array_length(p_vehicle_prices)<>expected_count then raise exception 'Set an explicit price for every active vehicle class' using errcode='22023'; end if;
  for entry in select value from jsonb_array_elements(p_vehicle_prices) loop
   if jsonb_typeof(entry) is distinct from 'object' or (select count(*) from jsonb_object_keys(entry))<>2 or not(entry?&array['class_code','price']) or jsonb_typeof(entry->'class_code') is distinct from 'string' or jsonb_typeof(entry->'price') is distinct from 'number' or (entry->>'price')::numeric<0 or (entry->>'price')::numeric<>round((entry->>'price')::numeric,2) or not exists(select 1 from private.business_vehicle_classes where class_code=entry->>'class_code' and is_active) then raise exception 'Valid active class and EGP price required' using errcode='22023'; end if;
  end loop;
 elsif p_spec->>'item_type'='product' and jsonb_array_length(p_vehicle_prices)<>0 then raise exception 'Products do not accept vehicle class prices' using errcode='22023';
 end if;
 catalogue_result:=private.save_owner_catalog_item(p_request,p_branch,p_item,p_expected_revision,p_spec,p_reason);
 if p_spec->>'item_type'='service' then
  insert into private.business_service_vehicle_prices(branch_id,item_id,class_code,price,updated_by)
   select p_branch,(catalogue_result->>'item_id')::uuid,value->>'class_code',(value->>'price')::numeric,actor from jsonb_array_elements(p_vehicle_prices)
   on conflict(branch_id,item_id,class_code) do update set price=excluded.price,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 end if;
 result:=catalogue_result||jsonb_build_object('vehicle_prices',p_vehicle_prices,'issued_invoices_unchanged',true);
 insert into private.owner_vehicle_price_commands values(p_request,actor,payload,result,clock_timestamp());
 if p_spec->>'item_type'='service' then
  insert into private.business_service_vehicle_price_history(request_id,branch_id,item_id,class_code,price,changed_by)
   select p_request,p_branch,(catalogue_result->>'item_id')::uuid,value->>'class_code',(value->>'price')::numeric,actor from jsonb_array_elements(p_vehicle_prices);
 end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data)
 values(actor::text,actor,'owner_vehicle_prices_saved','catalog_item',catalogue_result->>'item_id',p_branch,trim(p_reason),null,result);
 return result;
end $$;
create function public.save_owner_catalog_item_with_vehicle_prices(p_request uuid,p_branch uuid,p_item uuid,p_expected_revision text,p_spec jsonb,p_reason text,p_vehicle_prices jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_catalog_item_with_vehicle_prices(p_request,p_branch,p_item,p_expected_revision,p_spec,p_reason,p_vehicle_prices)$$;
revoke all on function private.save_owner_catalog_item_with_vehicle_prices(uuid,uuid,uuid,text,jsonb,text,jsonb),public.save_owner_catalog_item_with_vehicle_prices(uuid,uuid,uuid,text,jsonb,text,jsonb) from public,anon;
grant execute on function private.save_owner_catalog_item_with_vehicle_prices(uuid,uuid,uuid,text,jsonb,text,jsonb),public.save_owner_catalog_item_with_vehicle_prices(uuid,uuid,uuid,text,jsonb,text,jsonb) to authenticated;

create or replace function private.get_owner_catalog_items(p_branch uuid default null,p_after uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare b uuid;items jsonb;classes jsonb;
begin
 if not coalesce(private.has_live_invoice_session(),false) or private.active_staff_role() is distinct from 'owner' then raise exception 'Current owner session required' using errcode='42501'; end if;
 b:=p_branch;if b is null then select branch_id into b from public.business_branches where is_default and is_active; end if;perform private.require_owner_tax_branch(b);
 select coalesce(jsonb_agg(jsonb_build_object('class_code',class_code,'name_ar',name_ar,'name_en',name_en,'is_active',is_active) order by class_code),'[]'::jsonb) into classes from private.business_vehicle_classes;
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('vehicle_prices',coalesce(x.vehicle_prices,'{}'::jsonb)) order by item_id),'[]'::jsonb) into items from (
  select c.item_id,c.item_type,c.name,c.name_en,c.price,c.duration_minutes,c.is_active,c.is_public,c.image_url,c.category,c.stock_quantity,private.owner_catalog_revision(c.item_id) revision,
   (select jsonb_object_agg(p.class_code,p.price) from private.business_service_vehicle_prices p where p.branch_id=b and p.item_id=c.item_id) vehicle_prices
  from public.business_catalog_items c where c.branch_id=b and(p_after is null or c.item_id>p_after) order by c.item_id limit 101
 )x;
 return jsonb_build_object('branch',b,'items',case when jsonb_array_length(items)>100 then items-100 else items end,'has_more',jsonb_array_length(items)>100,'vehicle_classes',classes);
end $$;
create or replace function public.get_owner_catalog_items(p_branch uuid default null,p_after uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_catalog_items(p_branch,p_after)$$;
revoke all on function private.get_owner_catalog_items(uuid,uuid),public.get_owner_catalog_items(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function private.get_owner_catalog_items(uuid,uuid),public.get_owner_catalog_items(uuid,uuid) to authenticated;

-- Public promotion cards include class-specific service prices. The legacy
-- price remains for old readers, while the Flutter UI prefers this map.
create or replace function private.get_public_promotions() returns jsonb
language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('offers',coalesce((
  select jsonb_agg(jsonb_build_object(
   'offer_id',o.offer_id,'branch_id',o.branch_id,'name',o.name,'name_en',o.name_en,
   'description',o.description,'description_en',o.description_en,
   'category',coalesce(o.presentation_category,case when o.offer_type='visit_reward' then 'reward' else 'limited' end),
   'visits_required',o.visits_required,'service_id',c.item_id,'price',c.price,
   'compare_price',case when o.compare_price>c.price then o.compare_price end,
   'vehicle_class_prices',case when c.item_id is null then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('class_code',vc.class_code,'name_ar',vc.name_ar,'name_en',vc.name_en,
      'price',vp.price,'compare_price',case when o.compare_price>vp.price then o.compare_price end) order by vc.class_code)
    from private.business_vehicle_classes vc left join private.business_service_vehicle_prices vp
     on vp.branch_id=o.branch_id and vp.item_id=c.item_id and vp.class_code=vc.class_code
    where vc.is_active
   ),'[]'::jsonb) end,
   'image_asset',coalesce(o.image_asset,'wash')) order by o.created_at desc)
  from public.business_offers o join public.business_branches b on b.branch_id=o.branch_id
  left join public.business_catalog_items c on c.item_id=o.catalog_item_id and c.branch_id=o.branch_id and c.is_active and c.is_public and c.item_type='service'
  where b.is_default and b.is_active and o.is_active and o.is_public and(o.starts_at is null or o.starts_at<=now())
   and(o.ends_at is null or o.ends_at>now()) and(o.target_customer_ids is null or auth.uid()=any(o.target_customer_ids))
   and(o.catalog_item_id is null or c.item_id is not null)
   and concat_ws(' ',c.name,c.name_en,o.name,o.name_en)!~*'(ceramic|سيراميك|paint[[:space:]]*protect|حماية[[:space:]]*الطلاء|ppf)'
 ),'[]'::jsonb));
$$;

-- A customer can classify a vehicle only when it has no prior classification.
-- Changing an existing classification requires the audited owner RPC below.
create function private.guard_vehicle_class_change() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.vehicle_class_code is not distinct from old.vehicle_class_code then return new; end if;
 if auth.uid() is not null and auth.uid()=old.customer_id and old.vehicle_class_code is null and exists(select 1 from private.business_vehicle_classes where class_code=new.vehicle_class_code and is_active) then return new; end if;
 if auth.uid() is not null and private.active_staff_role() is distinct from 'owner' then raise exception 'Only the owner can correct an existing vehicle class' using errcode='42501'; end if;
 return new;
end $$;
revoke all on function private.guard_vehicle_class_change() from public,anon,authenticated,service_role;
create trigger guard_vehicle_class_change before update of vehicle_class_code on public.vehicles for each row execute function private.guard_vehicle_class_change();

create function private.owner_correct_vehicle_class(p_request uuid,p_branch uuid,p_vehicle uuid,p_class_code text,p_reason text)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;v public.vehicles;offline_car private.offline_customer_car_refs;offline_profile private.offline_customer_profiles;prior private.owner_vehicle_price_commands;payload jsonb;result jsonb;before_class text;
begin
 actor:=private.require_owner_tax_branch(p_branch);
 if p_request is null or p_vehicle is null or p_class_code is null or length(trim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Vehicle, active class and correction reason required' using errcode='22023'; end if;
 if not exists(select 1 from private.business_vehicle_classes where class_code=p_class_code and is_active) then raise exception 'Active vehicle class required' using errcode='22023'; end if;
 payload:=jsonb_build_object('branch',p_branch,'vehicle',p_vehicle,'class_code',p_class_code,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('owner-vehicle-correction:'||p_request,0));
 select * into prior from private.owner_vehicle_price_commands where request_id=p_request;
 if found then if prior.actor_id=actor and prior.payload=payload then return prior.result; end if; raise exception 'Immutable vehicle correction request' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('vehicle-class-correction:'||p_request,0));
 select * into v from public.vehicles where id=p_vehicle for update;
 if found then
  before_class:=v.vehicle_class_code;
  update public.vehicles set vehicle_class_code=p_class_code where id=p_vehicle;
 else
  select r.* into offline_car from private.offline_customer_car_refs r where r.car_ref_id=p_vehicle for update;
  if not found then raise exception 'Vehicle unavailable' using errcode='22023';end if;
  select * into offline_profile from private.offline_customer_profiles p where p.profile_id=offline_car.profile_id and p.created_branch_id=p_branch;
  if not found then raise exception 'Vehicle unavailable in owner branch' using errcode='42501';end if;
  select x.class_code into before_class from private.business_offline_vehicle_classes x where x.car_ref_id=p_vehicle;
  insert into private.business_offline_vehicle_classes(car_ref_id,branch_id,class_code,updated_by)
   values(p_vehicle,p_branch,p_class_code,actor)
   on conflict(car_ref_id) do update set class_code=excluded.class_code,updated_by=excluded.updated_by,updated_at=clock_timestamp();
 end if;
 result:=jsonb_build_object('vehicle_id',p_vehicle,'class_code',p_class_code,'corrected',true);
 insert into private.owner_vehicle_price_commands values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data)
 values(actor::text,actor,'owner_vehicle_class_corrected','vehicle',p_vehicle::text,p_branch,trim(p_reason),jsonb_build_object('class_code',before_class),result);
 return result;
end $$;
create function public.owner_correct_vehicle_class(p_request uuid,p_branch uuid,p_vehicle uuid,p_class_code text,p_reason text)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.owner_correct_vehicle_class(p_request,p_branch,p_vehicle,p_class_code,p_reason)$$;
revoke all on function private.owner_correct_vehicle_class(uuid,uuid,uuid,text,text),public.owner_correct_vehicle_class(uuid,uuid,uuid,text,text) from public,anon;
grant execute on function private.owner_correct_vehicle_class(uuid,uuid,uuid,text,text),public.owner_correct_vehicle_class(uuid,uuid,uuid,text,text) to authenticated;

create function private.validate_vehicle_class_on_insert() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.vehicle_class_code is not null and not exists(select 1 from private.business_vehicle_classes where class_code=new.vehicle_class_code and is_active) then
  raise exception 'Choose an active vehicle class' using errcode='22023';
 end if;
 return new;
end $$;
revoke all on function private.validate_vehicle_class_on_insert() from public,anon,authenticated,service_role;
create trigger validate_vehicle_class_on_insert before insert on public.vehicles for each row execute function private.validate_vehicle_class_on_insert();

create function private.set_booking_vehicle_class_price() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v public.vehicles;class_label text;price numeric;
begin
 select * into v from public.vehicles where id=new.vehicle_id;
 if v.id is null or v.vehicle_class_code is null then raise exception 'Vehicle class is required before booking' using errcode='55000'; end if;
 price:=private.service_vehicle_price(new.branch_id,new.catalog_item_id,new.vehicle_id);
 select class_code into new.vehicle_class_code from private.business_vehicle_classes where class_code=v.vehicle_class_code and is_active;
 if new.vehicle_class_code is null then raise exception 'Vehicle class is inactive' using errcode='55000'; end if;
 new.vehicle_type:=new.vehicle_class_code;
 new.quoted_price:=price;
 return new;
end $$;
revoke all on function private.set_booking_vehicle_class_price() from public,anon,authenticated,service_role;
create trigger zzz_set_booking_vehicle_class_price before insert on public.bookings for each row execute function private.set_booking_vehicle_class_price();

create function private.snapshot_vehicle_class_on_order() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare class_code text;vehicle_id uuid;
begin
 if new.vehicle_class_code is not null then return new; end if;
 if new.booking_id is not null then select b.vehicle_class_code into class_code from public.bookings b where b.id=new.booking_id; end if;
 vehicle_id:=nullif(current_setting('app.sabiha_cashier_vehicle_id',true),'')::uuid;
 if class_code is null and vehicle_id is not null then class_code:=private.cashier_vehicle_class_code(vehicle_id); end if;
 if class_code is not null then new.vehicle_class_code:=class_code;new.vehicle_type:=class_code;end if;
 return new;
end $$;
revoke all on function private.snapshot_vehicle_class_on_order() from public,anon,authenticated,service_role;
create trigger snapshot_order_vehicle_class before insert on public.business_orders for each row execute function private.snapshot_vehicle_class_on_order();

create function private.snapshot_vehicle_class_on_invoice() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare class_code text;
begin
 if new.vehicle_class_code is not null or new.order_id is null then return new; end if;
 select o.vehicle_class_code into class_code from public.business_orders o where o.order_id::text=new.order_id::text;
 if class_code is not null then new.vehicle_class_code:=class_code;new.vehicle_type:=class_code;end if;
 return new;
end $$;
revoke all on function private.snapshot_vehicle_class_on_invoice() from public,anon,authenticated,service_role;
create trigger snapshot_invoice_vehicle_class before insert on public.business_invoices for each row execute function private.snapshot_vehicle_class_on_invoice();

-- Preserve the existing booking attempt, idempotency, ownership and reward rules;
-- change only its price source from the old flat value to the server vehicle quote.
do $$declare d text;n integer;begin
 d:=pg_get_functiondef('private.create_customer_service_booking(uuid,uuid,uuid,uuid,date,time without time zone,numeric,text,uuid,boolean)'::regprocedure);
 d:=replace(d,'  note text := nullif(trim(p_notes),'''');','  note text := nullif(trim(p_notes),'''');'||chr(10)||'  expected_vehicle_price numeric;');
 if position('expected_vehicle_price numeric;' in d)=0 then raise exception 'Booking function declaration changed; review migration'; end if;
 d:=replace(d,'  if service.price is distinct from p_expected_price then','  expected_vehicle_price:=private.service_vehicle_price(p_branch,p_service,p_vehicle);'||chr(10)||'  if expected_vehicle_price is distinct from p_expected_price then');
 if position('expected_vehicle_price:=private.service_vehicle_price' in d)=0 then raise exception 'Booking price guard not found'; end if;
 execute d;
end $$;

-- Reward coverage uses the same class-specific gross amount and freezes it in
-- the existing reward quote; no points/visit lots are changed by repricing.
do $$declare d text;begin
 d:=pg_get_functiondef('private.quote_service_reward(uuid,uuid,uuid,uuid,date,time without time zone,uuid,uuid,text)'::regprocedure);
 d:=replace(d,'threshold integer;','threshold integer;gross numeric;');
 d:=replace(d,'for share;'||chr(10)||' if s.item_id is null or s.price<=0 or s.price::text=''NaN''','for share;'||chr(10)||' gross:=private.try_service_vehicle_price(p_branch,p_service,p_vehicle);'||chr(10)||' if s.item_id is null or gross is null or gross<=0 or gross::text=''NaN''');
 d:=replace(d,'''gross_amount'',s.price','''gross_amount'',gross');
 d:=replace(d,',threshold,s.price,ids,',',threshold,gross,ids,');
 if position('gross:=private.try_service_vehicle_price' in d)=0 or position('threshold,gross,ids' in d)=0 then raise exception 'Reward quote price source not found'; end if;
 execute d;
end $$;

-- A POS draft's verified customer/car binding is the only price-class source.
-- An unbound service cart remains visibly provisional and cannot be issued.
do $$declare d text;begin
 d:=pg_get_functiondef('private.quote_cashier_cart_reviewed(uuid,jsonb,text,numeric)'::regprocedure);
 d:=replace(d,'workers jsonb;worker jsonb;base numeric;ordinal integer:=0;','workers jsonb;worker jsonb;base numeric;ordinal integer:=0;vehicle_id uuid;vehicle_class text;vehicle_price numeric;unbound_services integer:=0;priced_lines jsonb:=''[]''::jsonb;');
 if position('priced_lines jsonb' in d)=0 then raise exception 'Reviewed quote declaration changed'; end if;
 d:=replace(d,'validated:=private.quote_cashier_cart(p_branch,p_items,p_discount_mode,p_discount_value);',
  'vehicle_id:=nullif(current_setting(''app.sabiha_cashier_vehicle_id'',true),'''')::uuid;'||chr(10)||
  'if vehicle_id is not null and not exists(select 1 from private.cashier_draft_subjects sb join private.cashier_reviewed_drafts dr using(draft_id) where sb.actor_id=auth.uid() and sb.branch_id=p_branch and sb.car_id=vehicle_id and sb.draft_version=dr.version) then vehicle_id:=null;end if;'||chr(10)||
  'if vehicle_id is not null then vehicle_class:=private.cashier_vehicle_class_code(vehicle_id);end if;'||chr(10)||
  'validated:=private.quote_cashier_cart(p_branch,p_items,p_discount_mode,p_discount_value);');
 d:=replace(d,'for source in select value from jsonb_array_elements(validated->''lines'')loop'||chr(10)||'  classification:=private.resolve_owner_reviewed_tax',
  'for source in select value from jsonb_array_elements(validated->''lines'')loop'||chr(10)||
  '  if source->>''item_type''=''service'' then'||chr(10)||
  '   if vehicle_id is null then unbound_services:=unbound_services+1; else'||chr(10)||
  '    vehicle_price:=private.service_vehicle_price(p_branch,(source->>''item_id'')::uuid,vehicle_id);'||chr(10)||
  '    source:=source||jsonb_build_object(''unit_price'',vehicle_price,''subtotal'',vehicle_price*(source->>''quantity'')::numeric,''catalog_amount'',vehicle_price*(source->>''quantity'')::numeric,''vehicle_class_code'',vehicle_class);'||chr(10)||
  '   end if;'||chr(10)||'  end if;'||chr(10)||
  '  priced_lines:=priced_lines||jsonb_build_array(source);'||chr(10)||
  '  classification:=private.resolve_owner_reviewed_tax');
 d:=replace(d,' end loop;'||chr(10)||' -- This endpoint accepts authorized manual invoice discounts only.',
  ' end loop;'||chr(10)||' validated:=jsonb_set(validated,''{lines}'',priced_lines);'||chr(10)||' -- This endpoint accepts authorized manual invoice discounts only.');
 d:=replace(d,'''quote_only'',true,''earned_commission'',false);',
  '''quote_only'',true,''earned_commission'',false,''vehicle_id'',vehicle_id,''vehicle_class_code'',vehicle_class,''vehicle_pricing_ready'',unbound_services=0);');
 if position('vehicle_pricing_ready' in d)=0 or position('vehicle_price:=private.service_vehicle_price' in d)=0 then raise exception 'Reviewed quote vehicle-price integration missing'; end if;
 execute d;
end $$;

-- The draft is the authoritative binding boundary. Preserve its binding across
-- quote revisions only when the existing binding is for the exact prior version.
do $$declare d text;begin
 d:=pg_get_functiondef('private.save_cashier_reviewed_draft(uuid,uuid,integer,uuid,jsonb,text,numeric)'::regprocedure);
 d:=replace(d,'prior private.cashier_reviewed_commands;payload jsonb;result jsonb;q jsonb;','prior private.cashier_reviewed_commands;payload jsonb;result jsonb;q jsonb;binding private.cashier_draft_subjects;');
 d:=replace(d,'q:=private.quote_cashier_cart_reviewed(p_branch,p_items,p_discount_mode,p_discount_value);',
  'select * into binding from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor and branch_id=p_branch and draft_version=p_expected_version;'||chr(10)||
  'perform set_config(''app.sabiha_cashier_vehicle_id'',coalesce(binding.car_id::text,''''),true);'||chr(10)||
  'q:=private.quote_cashier_cart_reviewed(p_branch,p_items,p_discount_mode,p_discount_value);');
 d:=replace(d,'insert into private.cashier_reviewed_commands values(p_request,actor,payload,result);',
  'if binding.draft_id is not null then update private.cashier_draft_subjects set draft_version=p_expected_version+1,updated_at=clock_timestamp() where draft_id=p_draft and actor_id=actor and version=binding.version;end if;'||chr(10)||
  'insert into private.cashier_reviewed_commands values(p_request,actor,payload,result);');
 if position('binding private.cashier_draft_subjects' in d)=0 or position('set_config(''app.sabiha_cashier_vehicle_id''' in d)=0 then raise exception 'Reviewed draft binding integration missing'; end if;
 execute d;
end $$;

-- Every quote recheck uses the exact draft vehicle, including checkout and
-- reward-intent verification. An altered or removed class invalidates checkout.
do $$declare fn record;d text;begin
 for fn in select proc.proname,proc.oid::regprocedure signature from pg_proc proc join pg_namespace ns on ns.oid=proc.pronamespace
  where ns.nspname='private' and proc.proname in('issue_cashier_invoice','issue_cashier_mixed_invoice','cashier_loyalty_draft_witness') loop
  d:=pg_get_functiondef(fn.signature::regprocedure);
  if fn.proname='cashier_loyalty_draft_witness' then
   d:=replace(d,'q:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);',
    'perform set_config(''app.sabiha_cashier_vehicle_id'',coalesce(b.car_id::text,''''),true);'||chr(10)||
    'q:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);'||chr(10)||
    'if q->>''vehicle_pricing_ready'' is distinct from ''true'' then raise exception ''Bind a classified customer vehicle before sealing service lines'' using errcode=''55000'';end if;');
   if position('vehicle_pricing_ready' in d)=0 then raise exception 'Cashier loyalty witness has no supported quote guard';end if;
  else
   d:=replace(d,'current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);',
    'perform set_config(''app.sabiha_cashier_vehicle_id'',coalesce(b.car_id::text,''''),true);'||chr(10)||'current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);'||chr(10)||
    'if current_quote->>''vehicle_pricing_ready'' is distinct from ''true'' then raise exception ''Bind a classified customer vehicle before issuing service lines'' using errcode=''55000'';end if;');
   if position('vehicle_pricing_ready' in d)=0 then raise exception 'Cashier issue function has no supported quote guard: %',fn.signature;end if;
  end if;
  execute d;
 end loop;
end $$;

do $$declare d text;begin
 d:=pg_get_functiondef('private.issue_cashier_mixed_invoice(uuid,uuid,uuid,integer,integer,timestamp with time zone)'::regprocedure);
 d:=replace(d,'values(child,service.item_id,service.name,1,service.price,service.price);',
  'values(child,service.item_id,service.name,1,(line->>''unit_price'')::numeric,(line->>''unit_price'')::numeric);');
 if position('(line->>''unit_price'')::numeric' in d)=0 then raise exception 'Mixed-service child quote value marker missing';end if;
 execute d;
end $$;

do $$declare d text;begin
 d:=pg_get_functiondef('private.get_cashier_catalogue_review(uuid,uuid,integer)'::regprocedure);
 d:=replace(d,'current_quote jsonb;changes jsonb;different boolean;','current_quote jsonb;changes jsonb;different boolean;binding private.cashier_draft_subjects;');
 d:=replace(d,'current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);',
  'select * into binding from private.cashier_draft_subjects where draft_id=p_draft and actor_id=actor and branch_id=p_branch and draft_version=d.version;'||chr(10)||
  'perform set_config(''app.sabiha_cashier_vehicle_id'',coalesce(binding.car_id::text,''''),true);'||chr(10)||
  'current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->''items'',d.payload->>''discount_mode'',(d.payload->>''discount_value'')::numeric);');
 if position('binding private.cashier_draft_subjects' in d)=0 or position('vehicle_id' in d)=0 then raise exception 'Cashier catalogue review vehicle context missing';end if;
 execute d;
end $$;

notify pgrst,'reload schema';
commit;
