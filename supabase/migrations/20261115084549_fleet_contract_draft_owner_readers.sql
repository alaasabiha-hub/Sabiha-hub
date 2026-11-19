begin;
create function private.fleet_contract_draft_context(p_party uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare company private.fleet_parties;branch public.business_branches;services jsonb;default_count integer;begin
 perform private.fleet_contract_owner();select *into company from private.fleet_parties where party_id=p_party for share;
 if not found then raise exception 'Company unavailable'using errcode='42501';end if;
 select count(*)into default_count from public.business_branches where is_default and is_active;
 if default_count=1 then select *into branch from public.business_branches where is_default and is_active for share;end if;
 if branch.branch_id is not null then
 select coalesce(jsonb_agg(jsonb_build_object('service_id',i.item_id,'name_ar',i.name,'name_en',i.name_en,'catalogue_price_egp',i.price)order by i.name,i.item_id),'[]'::jsonb)into services
 from public.business_catalog_items i where i.branch_id=branch.branch_id and i.item_type='service'and i.is_active;
 else services:='[]'::jsonb;end if;
 return jsonb_build_object('module','fleet_contract_drafts_v1','party_id',company.party_id,'company_name',coalesce(company.terms->>'trading_name',company.terms->>'legal_name'),
 'company_active',not company.archived,'can_manage_drafts',not company.archived and branch.branch_id is not null,'draft_only',true,
 'branch',case when branch.branch_id is null then null else jsonb_build_object('branch_id',branch.branch_id,'name_ar',branch.name_ar,'name_en',branch.name_en)end,
 'services',services,'currency','EGP','contract_activation_available',false,'pricing_active',false,'billing_enabled',false,'eta_submission_enabled',false);
end$$;
create function private.fleet_contract_draft_history(p_contract uuid,p_before_version integer,p_limit integer)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare items jsonb;begin
 perform private.fleet_contract_owner();if p_limit is null or p_limit not between 1 and 50 or(p_before_version is not null and p_before_version<1)then raise exception 'Bounded version cursor required'using errcode='22023';end if;
 if not exists(select 1 from private.fleet_contracts where contract_id=p_contract)then raise exception 'Contract unavailable'using errcode='42501';end if;
 select coalesce(jsonb_agg(row_data order by version desc),'[]'::jsonb)into items from(select v.version,jsonb_build_object('version',v.version,'request_id',v.request_id,'actor_id',v.actor_id,'reason',v.reason,'created_at',v.created_at,'before',v.before_snapshot,'after',v.after_snapshot)row_data from private.fleet_contract_versions v where v.contract_id=p_contract and(p_before_version is null or v.version<p_before_version)order by v.version desc limit p_limit)rows;
 return jsonb_build_object('contract_id',p_contract,'items',items,'draft_only',true);
end$$;
create function public.get_fleet_contract_draft_context(p_party uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.fleet_contract_draft_context(p_party)$$;
create function public.get_fleet_contract_draft_history(p_contract uuid,p_before_version integer default null,p_limit integer default 25)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.fleet_contract_draft_history(p_contract,p_before_version,p_limit)$$;
revoke all on function private.fleet_contract_draft_context(uuid),private.fleet_contract_draft_history(uuid,integer,integer),public.get_fleet_contract_draft_context(uuid),public.get_fleet_contract_draft_history(uuid,integer,integer)from public,anon,authenticated,service_role;
grant execute on function private.fleet_contract_draft_context(uuid),private.fleet_contract_draft_history(uuid,integer,integer),public.get_fleet_contract_draft_context(uuid),public.get_fleet_contract_draft_history(uuid,integer,integer)to authenticated;
notify pgrst,'reload schema';
commit;
