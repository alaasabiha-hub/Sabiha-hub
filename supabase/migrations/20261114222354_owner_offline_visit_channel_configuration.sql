begin;
-- Owner-only version metadata; never activates earning or opens spending.
create function private.require_offline_channel_owner()returns uuid language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid:=auth.uid();sid uuid;begin
 begin sid:=(auth.jwt()->>'session_id')::uuid;exception when invalid_text_representation then raise exception 'Current owner session required'using errcode='42501';end;
 if actor is null or sid is null then raise exception 'Current owner session required'using errcode='42501';end if;
 perform 1 from auth.users u join auth.sessions s on s.user_id=u.id where u.id=actor and s.id=sid and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(s.not_after is null or s.not_after>clock_timestamp())for share of u,s;
 if not found then raise exception 'Current owner session required'using errcode='42501';end if;
 perform 1 from public.staff_profiles where user_id=actor and role='owner'and is_active for share;
 if not found then raise exception 'Current owner session required'using errcode='42501';end if;return actor;
end$$;
create function private.get_offline_visit_channel(p_branch uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
begin
 perform private.require_offline_channel_owner();
 if not exists(select 1 from public.business_branches where branch_id=p_branch and is_active)then raise exception 'Actual active branch required'using errcode='22023';end if;
 return jsonb_build_object('branch_id',p_branch,'unit','service_visits','configuration_only',true,'earning_enabled',false,'redemption_enabled',false,
 'current',(select to_jsonb(v)from private.offline_visit_channel_versions v where v.branch_id=p_branch order by v.version_no desc limit 1),
 'history',(select coalesce(jsonb_agg(to_jsonb(x)order by version_no desc),'[]')from(select version_id,version_no,policy_version_id,rules_version_id,enabled,created_by,created_at from private.offline_visit_channel_versions where branch_id=p_branch order by version_no desc limit 50)x));
end$$;
create function private.save_offline_visit_channel(p_request uuid,p_branch uuid,p_policy uuid,p_rules uuid,p_services uuid[],p_audience uuid[],p_enabled boolean)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s'as $$
declare actor uuid;prior private.offline_visit_channel_versions;policy private.loyalty_policy_versions;rules private.loyalty_redemption_rule_versions;services uuid[];audience uuid[];begin
 if current_setting('transaction_isolation')<>'read committed'then raise exception 'Configuration requires READ COMMITTED'using errcode='25001';end if;
 actor:=private.require_offline_channel_owner();
 if p_request is null or p_branch is null or p_policy is null or p_rules is null or p_enabled is null or p_services is null or cardinality(p_services)not between 1 and 100 or array_position(p_services,null)is not null
 or(select count(distinct x)from unnest(p_services)x)<>cardinality(p_services)
 or(p_audience is not null and(cardinality(p_audience)not between 1 and 100 or array_position(p_audience,null)is not null or(select count(distinct x)from unnest(p_audience)x)<>cardinality(p_audience)))then raise exception 'Explicit actual policy, rules, unique services and audience required'using errcode='22023';end if;
 select array_agg(x order by x)into services from unnest(p_services)x;
 if p_audience is not null then select array_agg(x order by x)into audience from unnest(p_audience)x;end if;
 perform pg_advisory_xact_lock(hashtextextended('offline-channel-request:'||p_request::text,0));
 select *into prior from private.offline_visit_channel_versions where version_id=p_request;
 if found then
 if prior.created_by is distinct from actor or prior.branch_id is distinct from p_branch or prior.policy_version_id is distinct from p_policy or prior.rules_version_id is distinct from p_rules or prior.eligible_service_ids is distinct from services or prior.target_offline_profile_ids is distinct from audience or prior.enabled is distinct from p_enabled then raise exception 'Configuration request reused with different terms'using errcode='22023';end if;
 return to_jsonb(prior);end if;
 perform pg_advisory_xact_lock(hashtextextended('loyalty-policy-branch:'||p_branch::text,0));
 perform 1 from public.business_branches where branch_id=p_branch and is_active for share;
 if not found then raise exception 'Actual active branch required'using errcode='22023';end if;
 select *into policy from private.loyalty_policy_versions where version_id=p_policy and branch_id=p_branch;
 select *into rules from private.loyalty_redemption_rule_versions where rules_version_id=p_rules and policy_version_id=p_policy;
 if policy.version_id is null or rules.rules_version_id is null then raise exception 'Actual same-policy rules required'using errcode='22023';end if;
 -- Match existing policy/rules lock order; no activation or financial mutation.
 perform 1 from public.business_offers where offer_id=policy.offer_id for share;
 perform 1 from public.business_catalog_items where item_id=any(services||array[(policy.policy_snapshot->>'reward_item_id')::uuid])order by item_id for share;
 insert into private.offline_visit_channel_versions(version_id,policy_version_id,rules_version_id,branch_id,eligible_service_ids,target_offline_profile_ids,enabled,terms_snapshot,created_by)
 values(p_request,p_policy,p_rules,p_branch,services,audience,p_enabled,jsonb_build_object('unit','service_visits','source_channel','offline_walk_in','eligibility_basis','order_created_time','policy_snapshot',policy.policy_snapshot,'rules',rules.rules,'rules_terms_snapshot',rules.terms_snapshot),actor)returning *into prior;
 return to_jsonb(prior);
end$$;
revoke all on function private.require_offline_channel_owner(),private.get_offline_visit_channel(uuid),private.save_offline_visit_channel(uuid,uuid,uuid,uuid,uuid[],uuid[],boolean)from public,anon,authenticated,service_role;
grant execute on function private.get_offline_visit_channel(uuid),private.save_offline_visit_channel(uuid,uuid,uuid,uuid,uuid[],uuid[],boolean)to authenticated;
create function public.get_offline_visit_channel(p_branch uuid)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.get_offline_visit_channel(p_branch)$$;
create function public.save_offline_visit_channel(p_request uuid,p_branch uuid,p_policy uuid,p_rules uuid,p_services uuid[],p_audience uuid[],p_enabled boolean)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.save_offline_visit_channel(p_request,p_branch,p_policy,p_rules,p_services,p_audience,p_enabled)$$;
revoke all on function public.get_offline_visit_channel(uuid),public.save_offline_visit_channel(uuid,uuid,uuid,uuid,uuid[],uuid[],boolean)from public,anon,service_role;
grant execute on function public.get_offline_visit_channel(uuid),public.save_offline_visit_channel(uuid,uuid,uuid,uuid,uuid[],uuid[],boolean)to authenticated;
commit;
