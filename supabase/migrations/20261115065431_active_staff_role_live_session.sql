begin;
-- NULL remains unauthenticated/valid-nonstaff only: stale staff must not enter
-- existing customer policies that intentionally test active_staff_role() IS NULL.
create or replace function private.active_staff_role() returns text language plpgsql stable security definer
set search_path = pg_catalog as $$
declare result_role text;
begin
 if auth.uid() is null then return null;end if;
 if not private.has_live_invoice_session() then
  raise exception 'Current authenticated session required' using errcode='42501';
 end if;
 select sp.role into result_role from public.staff_profiles sp
 where sp.user_id=auth.uid() and sp.is_active;
 return result_role;
end $$;
notify pgrst,'reload schema';
commit;
