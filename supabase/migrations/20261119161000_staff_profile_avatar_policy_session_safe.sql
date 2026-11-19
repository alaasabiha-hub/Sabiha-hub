-- Avatar access uses active staff identity, not the live cashier/invoice session
-- guard used by sensitive operational commands.
create or replace function private.can_access_staff_profile_avatar(p_name text, p_action text)
returns boolean
language plpgsql stable security definer set search_path=pg_catalog
as $$
declare uid uuid := auth.uid();
begin
  if uid is null or p_action not in ('read','write') then return false; end if;
  if p_action='read' and exists (
    select 1 from public.staff_profiles s
    where s.user_id=uid and s.is_active and s.role='owner'
  ) then return true; end if;
  return split_part(coalesce(p_name,''), '/', 1)=uid::text
    and exists(select 1 from public.staff_profiles s where s.user_id=uid and s.is_active);
end;
$$;
revoke all on function private.can_access_staff_profile_avatar(text,text) from public, anon;
grant execute on function private.can_access_staff_profile_avatar(text,text) to authenticated;

drop policy if exists "Staff uploads candidate photo" on storage.objects;
create policy "Staff uploads candidate photo"
on storage.objects for insert to authenticated
with check (
  bucket_id='staff-photos'
  and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png)$')
  and (select private.can_access_staff_profile_avatar(name,'write'))
);

drop policy if exists "Staff upload own private profile avatar" on storage.objects;
drop policy if exists "Staff read own private profile avatar" on storage.objects;
drop policy if exists "Staff delete own private profile avatar" on storage.objects;

create policy "Staff upload own private profile avatar"
on storage.objects for insert to authenticated
with check (
  bucket_id='staff-profile-avatars'
  and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')
  and (select private.can_access_staff_profile_avatar(name,'write'))
);

create policy "Staff read own or owner profile avatars"
on storage.objects for select to authenticated
using (
  bucket_id='staff-profile-avatars'
  and (select private.can_access_staff_profile_avatar(name,'read'))
);

create policy "Staff delete own private profile avatar"
on storage.objects for delete to authenticated
using (
  bucket_id='staff-profile-avatars'
  and (select private.can_access_staff_profile_avatar(name,'write'))
);

create or replace function private.propose_employee_photo(p_path text, p_consent boolean)
returns void language plpgsql security definer set search_path=pg_catalog
as $$
declare uid uuid := auth.uid(); staff public.staff_profiles%rowtype; branch uuid;
begin
  if uid is null or p_consent is not true then
    raise exception 'Authentication and explicit photo consent required' using errcode='42501';
  end if;
  select * into staff from public.staff_profiles where user_id=uid and is_active;
  if not found then raise exception 'Active staff profile required' using errcode='42501'; end if;
  if p_path !~ ('^' || uid::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png)$')
     or not exists(select 1 from storage.objects where bucket_id='staff-photos' and name=p_path) then
    raise exception 'Upload your own photo first' using errcode='42501';
  end if;
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
