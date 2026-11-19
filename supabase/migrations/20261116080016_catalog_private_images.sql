begin;
-- Immutable, private catalogue media. No prices, invoices or earnings are rewritten.
create table private.catalog_image_versions(
 item_id uuid not null references public.business_catalog_items(item_id),version integer not null check(version>0),
 path text not null unique,actor_id uuid not null references auth.users(id),reason text not null,
 created_at timestamptz not null default clock_timestamp(),primary key(item_id,version));
create table private.catalog_image_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
alter table private.catalog_image_versions enable row level security;
alter table private.catalog_image_commands enable row level security;
revoke all on private.catalog_image_versions,private.catalog_image_commands from public,anon,authenticated,service_role;
create trigger immutable_catalog_image_version before update or delete on private.catalog_image_versions for each row execute function private.owner_tax_immutable();
create trigger immutable_catalog_image_command before update or delete on private.catalog_image_commands for each row execute function private.owner_tax_immutable();
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('catalog-images','catalog-images',false,2097152,array['image/png']);
create function private.can_upload_catalog_image(p_path text)returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;i uuid;begin
 if p_path!~'^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.png$'then return false;end if;
 b:=split_part(p_path,'/',1)::uuid;i:=split_part(p_path,'/',2)::uuid;
 perform private.require_owner_tax_branch(b);
 return exists(select 1 from public.business_catalog_items where item_id=i and branch_id=b);
 exception when sqlstate'42501'or invalid_text_representation then return false;end$$;
create function private.can_read_catalog_image(p_path text)returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;begin
 if private.can_upload_catalog_image(p_path)then return true;end if;
 select c.branch_id into b from private.catalog_image_versions v join public.business_catalog_items c using(item_id)where v.path=p_path;
 if b is null then return false;end if;
 if exists(select 1 from private.catalog_image_versions v join public.business_catalog_items c using(item_id)where v.path=p_path and c.is_active and c.is_public)then return true;end if;
 return private.can_read_cashier_catalog_revision(b);
 exception when sqlstate'42501'then return false;end$$;
revoke all on function private.can_upload_catalog_image(text),private.can_read_catalog_image(text)from public,anon,authenticated,service_role;
grant execute on function private.can_upload_catalog_image(text),private.can_read_catalog_image(text)to anon,authenticated;
create policy catalog_image_upload on storage.objects for insert to authenticated with check(bucket_id='catalog-images'and private.can_upload_catalog_image(name));
create policy catalog_image_read on storage.objects for select to anon,authenticated using(bucket_id='catalog-images'and private.can_read_catalog_image(name));
-- Restrictive rules protect this bucket from legacy broad owner/staff policies.
create policy catalog_image_insert_guard on storage.objects as restrictive for insert to anon,authenticated with check(bucket_id<>'catalog-images'or private.can_upload_catalog_image(name));
create policy catalog_image_select_guard on storage.objects as restrictive for select to anon,authenticated using(bucket_id<>'catalog-images'or private.can_read_catalog_image(name));
create policy catalog_image_no_overwrite on storage.objects as restrictive for update to anon,authenticated using(bucket_id<>'catalog-images')with check(bucket_id<>'catalog-images');
create policy catalog_image_no_delete on storage.objects as restrictive for delete to anon,authenticated using(bucket_id<>'catalog-images');
create function private.attach_owner_catalog_image(p_request uuid,p_branch uuid,p_item uuid,p_expected_version integer,p_path text,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;payload jsonb;prior private.catalog_image_commands;v integer;result jsonb;begin
 actor:=private.require_owner_tax_branch(p_branch);
 if p_request is null or p_expected_version is null or p_expected_version<0 or length(trim(coalesce(p_reason,'')))not between 5 and 500 or p_path is null or not private.can_upload_catalog_image(p_path)or split_part(p_path,'/',1)<>p_branch::text or split_part(p_path,'/',2)<>p_item::text then raise exception 'Valid owner image request required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'item',p_item,'version',p_expected_version,'path',p_path,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('catalog-image-request:'||p_request,0));
 select *into prior from private.catalog_image_commands where request_id=p_request;
 if found then if prior.actor_id<>actor or prior.payload<>payload then raise exception 'Image request mismatch'using errcode='22023';end if;return prior.result;end if;
 perform 1 from public.business_catalog_items where item_id=p_item and branch_id=p_branch for update;
 if not found then raise exception 'Owner branch item required'using errcode='42501';end if;
 select coalesce(max(version),0)into v from private.catalog_image_versions where item_id=p_item;
 if v<>p_expected_version then raise exception 'Image changed; reload'using errcode='40001';end if;
 if not exists(select 1 from storage.objects where bucket_id='catalog-images'and name=p_path and metadata->>'mimetype'='image/png'and(metadata->>'size')::bigint between 1 and 2097152)then raise exception 'Uploaded PNG within size limit required'using errcode='22023';end if;
 insert into private.catalog_image_versions(item_id,version,path,actor_id,reason)values(p_item,v+1,p_path,actor,trim(p_reason));
 result:=jsonb_build_object('item_id',p_item,'version',v+1,'path',p_path,'issued_invoices_unchanged',true);
 insert into private.catalog_image_commands(request_id,actor_id,payload,result)values(p_request,actor,payload,result);
 insert into public.cashier_catalog_revisions values(p_branch,1)on conflict(branch_id)do update set revision=cashier_catalog_revisions.revision+1;
 return result;end$$;
create function private.get_catalog_image_paths(p_items uuid[])returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare result jsonb;begin
 if coalesce(cardinality(p_items),0)>100 then raise exception 'At most 100 catalogue images'using errcode='22023';end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]')into result from(
 select distinct on(v.item_id)v.item_id,v.version,v.path from private.catalog_image_versions v where v.item_id=any(p_items)and private.can_read_catalog_image(v.path)order by v.item_id,v.version desc)x;
 return jsonb_build_object('images',result);end$$;
create function public.attach_owner_catalog_image(p_request uuid,p_branch uuid,p_item uuid,p_expected_version integer,p_path text,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.attach_owner_catalog_image(p_request,p_branch,p_item,p_expected_version,p_path,p_reason)$$;
create function public.get_catalog_image_paths(p_items uuid[])returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select private.get_catalog_image_paths(p_items)$$;
revoke all on function private.attach_owner_catalog_image(uuid,uuid,uuid,integer,text,text),private.get_catalog_image_paths(uuid[]),public.attach_owner_catalog_image(uuid,uuid,uuid,integer,text,text),public.get_catalog_image_paths(uuid[])from public,anon,authenticated,service_role;
grant execute on function private.attach_owner_catalog_image(uuid,uuid,uuid,integer,text,text),public.attach_owner_catalog_image(uuid,uuid,uuid,integer,text,text)to authenticated;
grant execute on function private.get_catalog_image_paths(uuid[]),public.get_catalog_image_paths(uuid[])to anon,authenticated;
notify pgrst,'reload schema';commit;
