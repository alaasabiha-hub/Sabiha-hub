begin;
-- Owner API reuses the reviewed private issuer; no runtime flag is changed.
create function private.owner_reward_issuer_actor() returns uuid
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 if not private.has_live_invoice_session() then
  raise exception 'Current confirmed owner session required' using errcode='42501';
 end if;
 return private.require_offline_reservation_operator();
end $$;
create function private.owner_reward_issuer_context() returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare ready boolean; installed boolean;
begin
 perform private.owner_reward_issuer_actor();
 select kernel_installed,public_enabled into installed,ready
 from private.offline_reward_issuer_runtime where singleton;
 return jsonb_build_object('module','owner_reward_issuer_v1','owner_only',true,
  'kernel_installed',coalesce(installed,false),'spending_enabled',coalesce(ready,false),
  'can_prepare',coalesce(installed and ready,false),'can_issue',coalesce(installed and ready,false),
  'activation_available',false,'currency','EGP','unit','service_visits');
end $$;
create function private.owner_reward_issuer_write_guard() returns void
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 perform private.owner_reward_issuer_actor();
 if not exists(select 1 from private.offline_reward_issuer_runtime where singleton and kernel_installed and public_enabled) then
  raise exception 'Reward issuance remains disabled' using errcode='55000';
 end if;
end $$;
create function private.owner_reward_issue_read(p_request uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 perform private.owner_reward_issuer_actor();
 return private.get_offline_reward_issue(p_request);
end $$;
create function private.owner_reward_issue_prepare(p_request uuid,p_preparation uuid,p_consent uuid,p_registration uuid,p_staff uuid[]) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 perform private.owner_reward_issuer_write_guard();
 return private.prepare_offline_reward_issue(p_request,p_preparation,p_consent,p_registration,p_staff);
end $$;
create function private.owner_reward_issue_place(p_request uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 perform private.owner_reward_issuer_write_guard();
 return private.place_offline_reward_issue(p_request);
end $$;
create function public.get_owner_reward_issuer_context() returns jsonb
language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_reward_issuer_context()$$;
create function public.get_owner_reward_issue(p_request uuid) returns jsonb
language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_reward_issue_read(p_request)$$;
create function public.prepare_owner_reward_issue(p_request uuid,p_preparation uuid,p_consent uuid,p_registration uuid,p_staff uuid[]) returns jsonb
language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_reward_issue_prepare(p_request,p_preparation,p_consent,p_registration,p_staff)$$;
create function public.place_owner_reward_issue(p_request uuid) returns jsonb
language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_reward_issue_place(p_request)$$;
revoke all on function private.owner_reward_issuer_actor(),private.owner_reward_issuer_context(),private.owner_reward_issuer_write_guard(),private.owner_reward_issue_read(uuid),private.owner_reward_issue_prepare(uuid,uuid,uuid,uuid,uuid[]),private.owner_reward_issue_place(uuid),public.get_owner_reward_issuer_context(),public.get_owner_reward_issue(uuid),public.prepare_owner_reward_issue(uuid,uuid,uuid,uuid,uuid[]),public.place_owner_reward_issue(uuid) from public,anon,authenticated,service_role;
grant execute on function private.owner_reward_issuer_context(),private.owner_reward_issue_read(uuid),private.owner_reward_issue_prepare(uuid,uuid,uuid,uuid,uuid[]),private.owner_reward_issue_place(uuid),public.get_owner_reward_issuer_context(),public.get_owner_reward_issue(uuid),public.prepare_owner_reward_issue(uuid,uuid,uuid,uuid,uuid[]),public.place_owner_reward_issue(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
