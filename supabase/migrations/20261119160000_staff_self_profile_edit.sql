-- Self-service staff display name and private avatar. QA deployment only.
-- Role, permissions, activation, and branch membership remain owner-managed.
create table if not exists private.staff_profile_preferences (
  user_id uuid primary key references public.staff_profiles(user_id) on delete cascade,
  avatar_path text,
  updated_at timestamptz not null default clock_timestamp()
);
revoke all on private.staff_profile_preferences from public, anon, authenticated;

create table if not exists private.staff_profile_events (
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.staff_profiles(user_id),
  changed_fields text[] not null check (changed_fields <@ array['full_name','avatar_path']::text[]),
  created_at timestamptz not null default clock_timestamp()
);
revoke all on private.staff_profile_events from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-profile-avatars', 'staff-profile-avatars', false, 3145728,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = false,
  file_size_limit = 3145728,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

create policy "Staff upload own private profile avatar"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'staff-profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
  and (select private.active_staff_role()) is not null
  and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')
);

create policy "Staff read own private profile avatar"
on storage.objects for select to authenticated
using (
  bucket_id = 'staff-profile-avatars'
  and (
    split_part(name, '/', 1) = (select auth.uid())::text
    or (select private.active_staff_role()) = 'owner'
  )
);

create policy "Staff delete own private profile avatar"
on storage.objects for delete to authenticated
using (
  bucket_id = 'staff-profile-avatars'
  and split_part(name, '/', 1) = (select auth.uid())::text
  and (select private.active_staff_role()) is not null
);

create or replace function private.get_my_staff_profile()
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog
as $$
declare uid uuid := auth.uid(); profile public.staff_profiles%rowtype; avatar text;
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  select * into profile from public.staff_profiles where user_id=uid and is_active;
  if not found then raise exception 'Active staff profile required' using errcode='42501'; end if;
  select avatar_path into avatar from private.staff_profile_preferences where user_id=uid;
  return jsonb_build_object('full_name', coalesce(profile.full_name,''), 'avatar_path', avatar);
end;
$$;
revoke all on function private.get_my_staff_profile() from public, anon;
grant execute on function private.get_my_staff_profile() to authenticated;
create or replace function public.get_my_staff_profile()
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.get_my_staff_profile(); $$;
revoke all on function public.get_my_staff_profile() from public, anon;
grant execute on function public.get_my_staff_profile() to authenticated;

create or replace function private.save_my_staff_profile(p_full_name text, p_avatar_path text default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog
as $$
declare uid uuid := auth.uid(); old_name text; old_avatar text; new_name text := btrim(coalesce(p_full_name,''));
begin
  if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if length(new_name) not between 2 and 100 then raise exception 'Name must be 2 to 100 characters'; end if;
  select full_name into old_name from public.staff_profiles where user_id=uid and is_active for update;
  if not found then raise exception 'Active staff profile required' using errcode='42501'; end if;
  select avatar_path into old_avatar from private.staff_profile_preferences where user_id=uid for update;
  if p_avatar_path is not null then
    if p_avatar_path !~ ('^' || uid::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')
       or not exists(select 1 from storage.objects where bucket_id='staff-profile-avatars' and name=p_avatar_path) then
      raise exception 'Avatar must be an uploaded image in your own folder' using errcode='42501';
    end if;
  end if;
  -- Intentionally update only the display name; never accept role/permissions from the client.
  update public.staff_profiles set full_name=new_name where user_id=uid and is_active;
  insert into private.staff_profile_preferences(user_id,avatar_path)
    values(uid,p_avatar_path)
    on conflict(user_id) do update set avatar_path=excluded.avatar_path, updated_at=clock_timestamp();
  insert into private.staff_profile_events(user_id,changed_fields)
    values(uid, array_remove(array[case when old_name is distinct from new_name then 'full_name' end,
                                 case when old_avatar is distinct from p_avatar_path then 'avatar_path' end], null));
  return jsonb_build_object('full_name',new_name,'avatar_path',p_avatar_path);
end;
$$;
revoke all on function private.save_my_staff_profile(text,text) from public, anon;
grant execute on function private.save_my_staff_profile(text,text) to authenticated;
create or replace function public.save_my_staff_profile(p_full_name text, p_avatar_path text default null)
returns jsonb language sql security invoker set search_path=pg_catalog
as $$ select private.save_my_staff_profile(p_full_name,p_avatar_path); $$;
revoke all on function public.save_my_staff_profile(text,text) from public, anon;
grant execute on function public.save_my_staff_profile(text,text) to authenticated;

-- A missing public directory row no longer blocks a private employee photo proposal.
-- Newly created rows are always unpublished and the candidate remains pending approval.
create or replace function private.propose_employee_photo(p_path text, p_consent boolean)
returns void language plpgsql security definer set search_path=pg_catalog
as $$
declare uid uuid := auth.uid(); staff public.staff_profiles%rowtype; branch uuid;
begin
  if uid is null or private.active_staff_role() is null or p_consent is not true then
    raise exception 'Active staff and explicit photo consent required' using errcode='42501';
  end if;
  if p_path !~ ('^' || uid::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')
     or not exists(select 1 from storage.objects where bucket_id='staff-photos' and name=p_path) then
    raise exception 'Upload your own photo first' using errcode='42501';
  end if;
  select * into staff from public.staff_profiles where user_id=uid and is_active;
  if not found then raise exception 'Active staff profile required' using errcode='42501'; end if;
  select branch_id into branch from public.staff_branch_access where user_id=uid order by branch_id limit 1;
  branch := coalesce(branch, public.default_branch_id());
  if branch is null then raise exception 'No active branch is available for the public profile'; end if;
  insert into public.employee_public_profiles(user_id,display_name,job_title,branch_id,is_published,photo_consent)
  values(uid, coalesce(nullif(btrim(staff.full_name),''),'Staff'), '', branch, false, true)
  on conflict(user_id) do nothing;
  update public.employee_public_profiles
     set pending_photo_path=p_path, photo_consent=true, updated_at=clock_timestamp()
   where user_id=uid;
end;
$$;
revoke all on function private.propose_employee_photo(text,boolean) from public, anon;
grant execute on function private.propose_employee_photo(text,boolean) to authenticated;

-- The public API wrapper remains invoker-only.
revoke all on function public.propose_employee_photo(text,boolean) from public, anon;
grant execute on function public.propose_employee_photo(text,boolean) to authenticated;
