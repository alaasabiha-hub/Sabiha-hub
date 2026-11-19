begin;
-- Preserve every accepted aggregation; add authoritative current-session access.
create function private.owner_business_insights_live(p_from date,p_to date)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$begin
 perform private.require_offline_channel_owner(); -- shared current owner/session proof, no channel mutation
 return private.owner_business_insights(p_from,p_to);
end$$;
revoke all on function private.owner_business_insights(date,date)from public,anon,authenticated,service_role;
revoke all on function private.owner_business_insights_live(date,date)from public,anon,authenticated,service_role;
grant execute on function private.owner_business_insights_live(date,date)to authenticated;
create or replace function public.get_owner_business_insights(p_from date,p_to date)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_business_insights_live(p_from,p_to)$$;
revoke all on function public.get_owner_business_insights(date,date)from public,anon,service_role;
grant execute on function public.get_owner_business_insights(date,date)to authenticated;
notify pgrst,'reload schema';
commit;
