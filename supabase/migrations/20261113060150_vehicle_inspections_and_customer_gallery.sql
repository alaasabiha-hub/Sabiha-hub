-- Private, versioned inspections. Approved originals remain immutable.
alter table public.business_branches add column inspection_required boolean not null default false;
create table public.vehicle_inspections (
 inspection_id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.bookings(id),
 vehicle_id uuid not null references public.vehicles(id),customer_id uuid not null references public.customers(id),branch_id uuid not null references public.business_branches(branch_id),
 phase text not null check(phase in ('before','after')),revision integer not null check(revision>0),status text not null default 'draft' check(status in ('draft','approved')),
 supersedes_id uuid references public.vehicle_inspections(inspection_id),amendment_reason text,
 notes text not null default '' check(length(notes)<=3000),vehicle_condition text not null default '' check(length(vehicle_condition)<=1000),
 odometer integer check(odometer between 0 and 10000000),damage_markers jsonb not null default '[]'::jsonb,
 signature_consent boolean not null default false,signature_unavailable_reason text check(length(signature_unavailable_reason)<=1000),
 created_by uuid not null references public.staff_profiles(user_id),created_at timestamptz not null default now(),recorded_at timestamptz not null default now(),
 approved_by uuid references public.staff_profiles(user_id),approved_at timestamptz,version bigint not null default 1,
 unique(booking_id,phase,revision),check(revision=1 or supersedes_id is not null and length(trim(amendment_reason))>=5)
);
create unique index one_draft_inspection on public.vehicle_inspections(booking_id,phase) where status='draft';
create index inspections_customer_idx on public.vehicle_inspections(customer_id,booking_id,created_at desc);
create index inspections_branch_idx on public.vehicle_inspections(branch_id,status,created_at desc);
create table public.vehicle_inspection_media (
 media_id uuid primary key default gen_random_uuid(),inspection_id uuid not null references public.vehicle_inspections(inspection_id),
 kind text not null check(kind in ('front','back','left','right','interior','damage','signature')),
 storage_path text not null,caption text not null default '' check(length(caption)<=300),created_at timestamptz not null default now(),created_by uuid not null,
 unique(inspection_id,storage_path)
);
create unique index one_inspection_signature on public.vehicle_inspection_media(inspection_id) where kind='signature';
create index inspection_media_idx on public.vehicle_inspection_media(inspection_id);
alter table public.vehicle_inspections enable row level security;
alter table public.vehicle_inspection_media enable row level security;
revoke all on public.vehicle_inspections,public.vehicle_inspection_media from anon,authenticated;
grant select on public.vehicle_inspections,public.vehicle_inspection_media to authenticated;
grant all on public.vehicle_inspections,public.vehicle_inspection_media to service_role;
create function private.can_inspect_booking(p_booking uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid() is not null and exists(select 1 from public.bookings b where b.id=p_booking and
 (private.active_staff_role()='owner' or private.can_access_branch(b.branch_id) and (private.active_staff_role()='manager' or private.active_staff_role()='employee' and auth.uid()=any(b.assigned_staff_ids))));
$$;
revoke all on function private.can_inspect_booking(uuid) from public,anon;
grant execute on function private.can_inspect_booking(uuid) to authenticated;
create policy "Staff and approved customer inspection reads" on public.vehicle_inspections for select to authenticated using((select private.can_inspect_booking(booking_id)) or(status='approved' and customer_id=(select auth.uid())));
create policy "Inspection media follows its authorized report" on public.vehicle_inspection_media for select to authenticated using(exists(select 1 from public.vehicle_inspections i where i.inspection_id=vehicle_inspection_media.inspection_id));

create function private.begin_vehicle_inspection(p_booking uuid,p_phase text,p_previous uuid,p_reason text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare b public.bookings%rowtype;previous public.vehicle_inspections%rowtype;existing public.vehicle_inspections%rowtype;v_id uuid;v_revision integer;
begin
 if not coalesce(private.can_inspect_booking(p_booking),false) then raise exception 'Assigned inspection permission required';end if;
 if p_phase is null or p_phase not in ('before','after') then raise exception 'Choose before or after';end if;
 select * into strict b from public.bookings where id=p_booking;
 if b.vehicle_id is null or b.customer_id is null then raise exception 'Register the customer vehicle first';end if;
 if b.status='cancelled' then raise exception 'Cancelled visits cannot be inspected';end if;
 if p_phase='after' and b.status not in ('in_progress','completed') then raise exception 'After-service inspection requires started service';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_booking::text||p_phase,0));
 select * into existing from public.vehicle_inspections where booking_id=p_booking and phase=p_phase and status='draft';
 if found then if existing.supersedes_id is distinct from p_previous then raise exception 'Another draft revision exists';end if;return existing.inspection_id;end if;
 select * into previous from public.vehicle_inspections where booking_id=p_booking and phase=p_phase and status='approved' order by revision desc limit 1;
 if found and p_previous is null then return previous.inspection_id;end if;
 if p_previous is not null then
  if private.active_staff_role() is distinct from 'owner' or previous.inspection_id is distinct from p_previous or length(trim(coalesce(p_reason,''))) not between 5 and 1000 then raise exception 'Owner and latest approved revision with an amendment reason required';end if;
 end if;
 select coalesce(max(revision),0)+1 into v_revision from public.vehicle_inspections where booking_id=p_booking and phase=p_phase;
 insert into public.vehicle_inspections(booking_id,vehicle_id,customer_id,branch_id,phase,revision,supersedes_id,amendment_reason,notes,vehicle_condition,odometer,damage_markers,created_by)
 values(p_booking,b.vehicle_id,b.customer_id,b.branch_id,p_phase,v_revision,p_previous,nullif(trim(p_reason),''),coalesce(previous.notes,''),coalesce(previous.vehicle_condition,''),previous.odometer,coalesce(previous.damage_markers,'[]'),auth.uid()) returning inspection_id into v_id;
 if p_previous is not null then
  insert into public.vehicle_inspection_media(inspection_id,kind,storage_path,caption,created_at,created_by)
  select v_id,kind,storage_path,caption,created_at,created_by from public.vehicle_inspection_media where inspection_id=p_previous and kind<>'signature';
 end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data) values(auth.uid()::text,auth.uid(),'begin_inspection','vehicle_inspections',v_id::text,b.branch_id,p_reason,jsonb_build_object('phase',p_phase,'revision',v_revision,'supersedes_id',p_previous));return v_id;
end; $$;
create function private.save_vehicle_inspection(p_inspection uuid,p_expected bigint,p_notes text,p_condition text,p_odometer integer,p_markers jsonb,p_consent boolean,p_unsigned_reason text)
returns bigint language plpgsql security definer set search_path=pg_catalog as $$
declare i public.vehicle_inspections%rowtype;marker jsonb;v_version bigint;
begin
 select * into strict i from public.vehicle_inspections where inspection_id=p_inspection for update;
 if not coalesce(private.can_inspect_booking(i.booking_id),false) then raise exception 'Inspection access denied';end if;
 if i.revision>1 and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can edit an amended inspection';end if;
 if i.status<>'draft' or i.version<>p_expected then raise exception 'Report is approved or changed; refresh';end if;
 if p_markers is null or jsonb_typeof(p_markers)<>'array' or jsonb_array_length(p_markers)>50 then raise exception 'Invalid damage markers';end if;
 for marker in select * from jsonb_array_elements(p_markers) loop
  if jsonb_typeof(marker)<>'object' or coalesce(marker->>'view','') not in ('front','back','left','right','interior') or coalesce(marker->>'type','') not in ('scratch','dent','other') or jsonb_typeof(marker->'x')<>'number' or jsonb_typeof(marker->'y')<>'number' or not(marker?'x' and marker?'y') or (marker->>'x')::numeric not between 0 and 1 or (marker->>'y')::numeric not between 0 and 1 or length(coalesce(marker->>'note',''))>300 then raise exception 'Invalid damage position';end if;
 end loop;
 update public.vehicle_inspections set notes=coalesce(p_notes,''),vehicle_condition=coalesce(p_condition,''),odometer=p_odometer,damage_markers=p_markers,signature_consent=coalesce(p_consent,false),signature_unavailable_reason=nullif(trim(p_unsigned_reason),''),version=version+1 where inspection_id=p_inspection returning version into v_version;
 return v_version;
end; $$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vehicle-inspections','vehicle-inspections',false,5242880,array['image/jpeg','image/png']);
create function private.can_upload_inspection_object(p_path text) returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare i public.vehicle_inspections%rowtype;begin
 select * into i from public.vehicle_inspections where inspection_id::text=split_part(p_path,'/',1) and status='draft';
 if not found or not coalesce(private.can_inspect_booking(i.booking_id),false) then return false;end if;
 if split_part(p_path,'/',2) not in ('front','back','left','right','interior','damage','signature') then return false;end if;
 perform pg_advisory_xact_lock(hashtextextended(i.inspection_id::text,0));
 return (select count(*) from storage.objects where bucket_id='vehicle-inspections' and split_part(name,'/',1)=i.inspection_id::text)<21;
end; $$;
create function private.can_read_inspection_object(p_path text) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid() is not null and exists(select 1 from public.vehicle_inspections i join public.vehicle_inspection_media m on m.inspection_id=i.inspection_id where m.storage_path=p_path and (private.can_inspect_booking(i.booking_id) or i.status='approved' and i.customer_id=auth.uid()))
 or auth.uid() is not null and exists(select 1 from public.vehicle_inspections i where i.inspection_id::text=split_part(p_path,'/',1) and private.can_inspect_booking(i.booking_id));
$$;
revoke all on function private.can_upload_inspection_object(text),private.can_read_inspection_object(text) from public,anon;
grant execute on function private.can_upload_inspection_object(text),private.can_read_inspection_object(text) to authenticated;
create policy "Authorized draft inspection upload" on storage.objects for insert to authenticated with check(bucket_id='vehicle-inspections' and (select private.can_upload_inspection_object(name)));
create policy "Private inspection images read" on storage.objects for select to authenticated using(bucket_id='vehicle-inspections' and (select private.can_read_inspection_object(name)));

create function private.register_inspection_media(p_inspection uuid,p_kind text,p_path text,p_caption text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare i public.vehicle_inspections%rowtype;v_id uuid;
begin
 select * into strict i from public.vehicle_inspections where inspection_id=p_inspection for update;
 if not coalesce(private.can_inspect_booking(i.booking_id),false) or i.status<>'draft' then raise exception 'Authorized draft required';end if;
 if split_part(p_path,'/',1)<>p_inspection::text or split_part(p_path,'/',2)<>p_kind or not exists(select 1 from storage.objects where bucket_id='vehicle-inspections' and name=p_path) then raise exception 'Upload an authorized inspection image first';end if;
 insert into public.vehicle_inspection_media(inspection_id,kind,storage_path,caption,created_by) values(p_inspection,p_kind,p_path,coalesce(p_caption,''),auth.uid()) on conflict(inspection_id,storage_path) do nothing returning media_id into v_id;
 if v_id is null then select media_id into v_id from public.vehicle_inspection_media where inspection_id=p_inspection and storage_path=p_path;else update public.vehicle_inspections set version=version+1 where inspection_id=p_inspection;end if;return v_id;
end; $$;
create function private.approve_vehicle_inspection(p_inspection uuid,p_expected bigint) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare i public.vehicle_inspections%rowtype;begin
 select * into strict i from public.vehicle_inspections where inspection_id=p_inspection for update;
 if not coalesce(private.can_inspect_booking(i.booking_id),false) then raise exception 'Inspection access denied';end if;
 if i.revision>1 and private.active_staff_role() is distinct from 'owner' then raise exception 'Only owner can approve an amended inspection';end if;
 if i.status='approved' then return;end if;
 if i.version<>p_expected then raise exception 'Report changed; refresh before approval';end if;
 if length(trim(i.vehicle_condition))<3 then raise exception 'Record vehicle condition';end if;
 if (select count(distinct kind) from public.vehicle_inspection_media where inspection_id=p_inspection and kind in ('front','back','left','right','interior'))<>5 then raise exception 'Front, back, left, right and interior images required';end if;
 if exists(select 1 from public.vehicle_inspection_media where inspection_id=p_inspection and kind='signature') then
  if not i.signature_consent then raise exception 'Record customer consent before accepting signature';end if;
 elsif length(trim(coalesce(i.signature_unavailable_reason,'')))<5 then raise exception 'Customer signature or documented inability is required';end if;
 update public.vehicle_inspections set status='approved',approved_by=auth.uid(),approved_at=now(),version=version+1 where inspection_id=p_inspection;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,after_data) values(auth.uid()::text,auth.uid(),'approve_inspection','vehicle_inspections',p_inspection::text,i.branch_id,i.amendment_reason,jsonb_build_object('booking_id',i.booking_id,'phase',i.phase,'revision',i.revision));
end; $$;
create function private.inspection_completion_guard() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 if new.status='completed' and old.status<>'completed' and exists(select 1 from public.business_branches where branch_id=new.branch_id and inspection_required) and
 (select count(distinct phase) from public.vehicle_inspections where booking_id=new.id and status='approved')<>2 then raise exception 'Approve before and after inspections before completing this branch service';end if;return new;end; $$;
revoke all on function private.inspection_completion_guard() from public;
create trigger inspection_completion_guard before update of status on public.bookings for each row execute function private.inspection_completion_guard();

revoke all on function private.begin_vehicle_inspection(uuid,text,uuid,text) from public,anon;
grant execute on function private.begin_vehicle_inspection(uuid,text,uuid,text) to authenticated;
create function public.begin_vehicle_inspection(p_booking uuid,p_phase text,p_previous uuid default null,p_reason text default null) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.begin_vehicle_inspection(p_booking,p_phase,p_previous,p_reason); $$;
revoke all on function public.begin_vehicle_inspection(uuid,text,uuid,text) from public,anon;
grant execute on function public.begin_vehicle_inspection(uuid,text,uuid,text) to authenticated;

revoke all on function private.save_vehicle_inspection(uuid,bigint,text,text,integer,jsonb,boolean,text) from public,anon;
grant execute on function private.save_vehicle_inspection(uuid,bigint,text,text,integer,jsonb,boolean,text) to authenticated;
create function public.save_vehicle_inspection(p_inspection uuid,p_expected bigint,p_notes text,p_condition text,p_odometer integer,p_markers jsonb,p_consent boolean,p_unsigned_reason text) returns bigint language sql security invoker set search_path=pg_catalog as $$ select private.save_vehicle_inspection(p_inspection,p_expected,p_notes,p_condition,p_odometer,p_markers,p_consent,p_unsigned_reason); $$;
revoke all on function public.save_vehicle_inspection(uuid,bigint,text,text,integer,jsonb,boolean,text) from public,anon;
grant execute on function public.save_vehicle_inspection(uuid,bigint,text,text,integer,jsonb,boolean,text) to authenticated;

revoke all on function private.register_inspection_media(uuid,text,text,text) from public,anon;
grant execute on function private.register_inspection_media(uuid,text,text,text) to authenticated;
create function public.register_inspection_media(p_inspection uuid,p_kind text,p_path text,p_caption text default null) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.register_inspection_media(p_inspection,p_kind,p_path,p_caption); $$;
revoke all on function public.register_inspection_media(uuid,text,text,text) from public,anon;
grant execute on function public.register_inspection_media(uuid,text,text,text) to authenticated;

revoke all on function private.approve_vehicle_inspection(uuid,bigint) from public,anon;
grant execute on function private.approve_vehicle_inspection(uuid,bigint) to authenticated;
create function public.approve_vehicle_inspection(p_inspection uuid,p_expected bigint) returns void language sql security invoker set search_path=pg_catalog as $$ select private.approve_vehicle_inspection(p_inspection,p_expected); $$;
revoke all on function public.approve_vehicle_inspection(uuid,bigint) from public,anon;
grant execute on function public.approve_vehicle_inspection(uuid,bigint) to authenticated;
notify pgrst,'reload schema';
create function private.freeze_approved_inspection() returns trigger language plpgsql set search_path=pg_catalog as $$ begin
 if old.status='approved' then raise exception 'Approved inspections are immutable; create an audited revision';end if;
 return case when tg_op='DELETE' then old else new end;end; $$;
revoke all on function private.freeze_approved_inspection() from public;
create trigger freeze_approved_inspection before update or delete on public.vehicle_inspections for each row execute function private.freeze_approved_inspection();
create function private.guard_inspection_media_change() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare v_inspection uuid;begin
 if tg_op='DELETE' then v_inspection:=old.inspection_id;else v_inspection:=new.inspection_id;end if;
 if exists(select 1 from public.vehicle_inspections where inspection_id=v_inspection and status='approved') then raise exception 'Approved inspection media are immutable';end if;
 if tg_op='UPDATE' and old.inspection_id<>new.inspection_id then raise exception 'Media cannot be moved between reports';end if;
 return case when tg_op='DELETE' then old else new end;end; $$;
revoke all on function private.guard_inspection_media_change() from public;
create trigger guard_inspection_media_change before insert or update or delete on public.vehicle_inspection_media for each row execute function private.guard_inspection_media_change();
notify pgrst,'reload schema';
create function private.inspection_context(p_booking uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b public.bookings%rowtype;result jsonb;begin
 select * into strict b from public.bookings where id=p_booking;
 if auth.uid() is null or not(b.customer_id=auth.uid() or coalesce(private.can_inspect_booking(p_booking),false)) then raise exception 'Visit access denied';end if;
 select jsonb_build_object('booking_id',b.id,'service_name',b.service_name,'booking_date',b.booking_date,'booking_time',b.booking_time,'branch_id',b.branch_id,
 'branch_name_ar',br.name_ar,'branch_name_en',br.name_en,'vehicle_brand',v.brand,'vehicle_model',v.model,'plate_number',v.plate_number,
 'invoices',(select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'issued_at',i.issued_at)),'[]') from public.business_invoices i join public.business_orders o on o.order_id=i.order_id where o.booking_id=b.id and o.customer_id=b.customer_id)) into result
 from public.business_branches br left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id where br.branch_id=b.branch_id;return result;
end; $$;
revoke all on function private.inspection_context(uuid) from public,anon;
grant execute on function private.inspection_context(uuid) to authenticated;
create function public.inspection_context(p_booking uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.inspection_context(p_booking); $$;
revoke all on function public.inspection_context(uuid) from public,anon;
grant execute on function public.inspection_context(uuid) to authenticated;
notify pgrst,'reload schema';
create function private.guard_inspected_booking_identity() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 if (new.customer_id is distinct from old.customer_id or new.vehicle_id is distinct from old.vehicle_id or new.branch_id is distinct from old.branch_id) and exists(select 1 from public.vehicle_inspections where booking_id=old.id) then raise exception 'Inspected visit identity is immutable; create a new linked visit instead';end if;
 if new.vehicle_id is not null and not exists(select 1 from public.vehicles where id=new.vehicle_id and customer_id=new.customer_id) then raise exception 'Vehicle does not belong to visit customer';end if;
 if exists(select 1 from unnest(new.assigned_staff_ids) id where not exists(select 1 from public.staff_profiles s where s.user_id=id and s.is_active and (s.role='owner' or exists(select 1 from public.staff_branch_access a where a.user_id=id and a.branch_id=new.branch_id)))) then raise exception 'Assigned staff must belong to this branch';end if;
 return new;end; $$;
revoke all on function private.guard_inspected_booking_identity() from public;
create trigger guard_inspected_booking_identity before update of customer_id,vehicle_id,branch_id,assigned_staff_ids on public.bookings for each row execute function private.guard_inspected_booking_identity();
notify pgrst,'reload schema';
