begin;
-- Explicit future point-program terms; no conversion of legacy visits or balances.
create table private.mixed_points_policy_versions(
 version_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),
 version integer not null check(version>0),rules jsonb not null,reason text not null,
 actor_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 unique(branch_id,version)
);
create table private.mixed_points_policy_current(
 branch_id uuid primary key references public.business_branches(branch_id),
 version_id uuid not null unique references private.mixed_points_policy_versions(version_id),version integer not null check(version>0)
);
create table private.mixed_points_policy_commands(
 request_id uuid primary key,actor_id uuid not null references auth.users(id),payload jsonb not null,result jsonb not null
);
do $$declare n text;begin foreach n in array array['mixed_points_policy_versions','mixed_points_policy_current','mixed_points_policy_commands']loop
 execute format('alter table private.%I enable row level security',n);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',n);
 end loop;end$$;
create trigger immutable_mixed_points_policy_version before update or delete on private.mixed_points_policy_versions for each row execute function private.immutable_loyalty_policy();
create trigger immutable_mixed_points_policy_command before update or delete on private.mixed_points_policy_commands for each row execute function private.immutable_loyalty_policy();

create function private.validate_mixed_points_rules(p_branch uuid,p_rules jsonb)returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare k text;entry jsonb;id uuid;ids uuid[]:='{}';rates uuid[]:='{}';
 fields text[]:=array['unit','point_value_egp','minimum_points','maximum_points','minimum_invoice_egp','maximum_discount_egp','maximum_discount_percent','allow_walk_in','allow_booking','allow_coupon','allow_offer','allow_manual_discount','eligible_item_ids','earning_rates','cancellation','refunded_contribution'];
begin
 if p_rules is null or jsonb_typeof(p_rules)<>'object'or octet_length(p_rules::text)>65536
 or not(p_rules?&fields)or(select count(*)from jsonb_object_keys(p_rules))<>cardinality(fields)
 or p_rules->>'unit' is distinct from'reward_points_v1' then raise exception 'Complete explicit future points rules required; legacy conversion is forbidden'using errcode='22023';end if;
 foreach k in array array['point_value_egp','minimum_points','maximum_points','minimum_invoice_egp','maximum_discount_egp','maximum_discount_percent']loop
 if jsonb_typeof(p_rules->k)<>'number'or length(p_rules->>k)>24 or (p_rules->>k)::numeric<0 then raise exception 'Nonnegative bounded numeric points terms required'using errcode='22023';end if;end loop;
 if(p_rules->>'point_value_egp')::numeric<=0 or(p_rules->>'point_value_egp')::numeric>1000000 or round((p_rules->>'point_value_egp')::numeric,4)<>(p_rules->>'point_value_egp')::numeric
 or(p_rules->>'minimum_points')!~'^[1-9][0-9]{0,8}$'or(p_rules->>'maximum_points')!~'^[1-9][0-9]{0,8}$'or(p_rules->>'maximum_points')::numeric<(p_rules->>'minimum_points')::numeric
 or(p_rules->>'maximum_discount_percent')::numeric>100 or round((p_rules->>'maximum_discount_percent')::numeric,4)<>(p_rules->>'maximum_discount_percent')::numeric then raise exception 'Explicit valid point value, integer range and discount ceiling required'using errcode='22023';end if;
 foreach k in array array['minimum_invoice_egp','maximum_discount_egp']loop
 if(p_rules->>k)::numeric>1000000000 or round((p_rules->>k)::numeric,2)<>(p_rules->>k)::numeric then raise exception 'EGP thresholds require cents precision and bounded values'using errcode='22023';end if;end loop;
 foreach k in array array['allow_walk_in','allow_booking','allow_coupon','allow_offer','allow_manual_discount']loop
 if jsonb_typeof(p_rules->k)<>'boolean'then raise exception 'Explicit channel and stacking choices required'using errcode='22023';end if;end loop;
 if not((p_rules->>'allow_walk_in')::boolean or(p_rules->>'allow_booking')::boolean)
 or coalesce(p_rules->>'cancellation','')not in('restore_points','forfeit_points')
 or coalesce(p_rules->>'refunded_contribution','')not in('offset_future_points','freeze_for_owner_review')then raise exception 'Explicit supported channel/cancellation/refund choices required'using errcode='22023';end if;
 if jsonb_typeof(p_rules->'eligible_item_ids')<>'array'or jsonb_array_length(p_rules->'eligible_item_ids')not between 1 and 1000
 or jsonb_typeof(p_rules->'earning_rates')<>'array'or jsonb_array_length(p_rules->'earning_rates')not between 1 and 1000 then raise exception 'Actual eligible items and service earning rates required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_rules->'eligible_item_ids')loop
 if jsonb_typeof(entry)<>'string'or entry#>>'{}'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then raise exception 'Actual item UUID required'using errcode='22023';end if;
 id:=(entry#>>'{}')::uuid;
 if id=any(ids)or not exists(select 1 from public.business_catalog_items where item_id=id and branch_id=p_branch and item_type in('service','product'))then raise exception 'Distinct same-branch eligible items required'using errcode='22023';end if;ids:=array_append(ids,id);
 end loop;
 for entry in select value from jsonb_array_elements(p_rules->'earning_rates')loop
 if jsonb_typeof(entry)<>'object'or not(entry?&array['item_id','points_per_completed_unit'])or(select count(*)from jsonb_object_keys(entry))<>2
 or jsonb_typeof(entry->'item_id')<>'string'or entry->>'item_id'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or jsonb_typeof(entry->'points_per_completed_unit')<>'number'or entry->>'points_per_completed_unit'!~'^(0|[1-9][0-9]{0,5}|1000000)$'then raise exception 'Explicit service earning rate required'using errcode='22023';end if;
 id:=(entry->>'item_id')::uuid;
 if id=any(rates)or not exists(select 1 from public.business_catalog_items where item_id=id and branch_id=p_branch and item_type='service')then raise exception 'Distinct same-branch service rates required'using errcode='22023';end if;rates:=array_append(rates,id);
 end loop;
 return(p_rules-'eligible_item_ids'-'earning_rates')||jsonb_build_object('eligible_item_ids',(select jsonb_agg(x::text order by x)from unnest(ids)x),'earning_rates',(select jsonb_agg(jsonb_build_object('item_id',e->>'item_id','points_per_completed_unit',e->'points_per_completed_unit')order by e->>'item_id')from jsonb_array_elements(p_rules->'earning_rates')e));
end$$;

create function private.save_owner_mixed_points_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_rules jsonb,p_reason text)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid;old private.mixed_points_policy_current;command private.mixed_points_policy_commands;payload jsonb;rules jsonb;result jsonb;id uuid:=gen_random_uuid();begin
 actor:=private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Owner only'using errcode='42501';end if;
 if p_request is null or p_expected_version is null or p_expected_version<0 or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Exact version and change reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'expected_version',p_expected_version,'rules',p_rules,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-policy-command:'||p_request,0));select *into command from private.mixed_points_policy_commands where request_id=p_request;
 if found then if command.actor_id<>actor then raise exception 'Policy request unavailable'using errcode='42501';end if;if command.payload<>payload then raise exception 'Immutable policy request'using errcode='22023';end if;return command.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('mixed-points-policy-branch:'||p_branch,0));select *into old from private.mixed_points_policy_current where branch_id=p_branch for update;
 if coalesce(old.version,0)<>p_expected_version then raise exception 'Points policy version conflict'using errcode='40001';end if;
 rules:=private.validate_mixed_points_rules(p_branch,p_rules);
 -- A permission change while waiting cannot authorize a new policy.
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Current owner required'using errcode='42501';end if;
 insert into private.mixed_points_policy_versions(version_id,branch_id,version,rules,reason,actor_id)values(id,p_branch,p_expected_version+1,rules,trim(p_reason),actor);
 insert into private.mixed_points_policy_current values(p_branch,id,p_expected_version+1)on conflict(branch_id)do update set version_id=excluded.version_id,version=excluded.version;
 result:=jsonb_build_object('version_id',id,'version',p_expected_version+1,'future_rules_saved',true,'earning_enabled',false,'redemption_enabled',false,'legacy_balances_imported',false);
 insert into private.mixed_points_policy_commands values(p_request,actor,payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'owner_mixed_points_policy_saved','mixed_points_policy',id::text,p_branch,(select to_jsonb(v)from private.mixed_points_policy_versions v where v.version_id=old.version_id),jsonb_build_object('version_id',id,'version',p_expected_version+1,'rules',rules,'reason',trim(p_reason),'earning_enabled',false,'redemption_enabled',false));return result;
end$$;
create function private.get_owner_mixed_points_policy(p_branch uuid)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 perform private.cashier_cart_actor(p_branch);if private.active_staff_role()is distinct from'owner'then raise exception 'Owner only'using errcode='42501';end if;
 return jsonb_build_object('version',coalesce((select version from private.mixed_points_policy_current where branch_id=p_branch),0),'current',(select to_jsonb(v)from private.mixed_points_policy_current c join private.mixed_points_policy_versions v on v.version_id=c.version_id where c.branch_id=p_branch),
 'history',coalesce((select jsonb_agg(to_jsonb(x)order by x.version desc)from(select *from private.mixed_points_policy_versions where branch_id=p_branch order by version desc limit 50)x),'[]'),
 'catalog',coalesce((select jsonb_agg(jsonb_build_object('item_id',item_id,'name',name,'name_en',name_en,'item_type',item_type,'category',category,'is_active',is_active)order by name,item_id)from public.business_catalog_items where branch_id=p_branch and item_type in('service','product')),'[]'),
 'earning_enabled',false,'redemption_enabled',false,'legacy_balance_conversion_supported',false,'service_completion_and_verified_payment_required',true);
end$$;
create function public.save_owner_mixed_points_policy(p_request uuid,p_branch uuid,p_expected_version integer,p_rules jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_mixed_points_policy(p_request,p_branch,p_expected_version,p_rules,p_reason)$$;
create function public.get_owner_mixed_points_policy(p_branch uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_mixed_points_policy(p_branch)$$;
revoke all on function private.validate_mixed_points_rules(uuid,jsonb),private.save_owner_mixed_points_policy(uuid,uuid,integer,jsonb,text),private.get_owner_mixed_points_policy(uuid),public.save_owner_mixed_points_policy(uuid,uuid,integer,jsonb,text),public.get_owner_mixed_points_policy(uuid)from public,anon,authenticated,service_role;
grant execute on function private.save_owner_mixed_points_policy(uuid,uuid,integer,jsonb,text),private.get_owner_mixed_points_policy(uuid),public.save_owner_mixed_points_policy(uuid,uuid,integer,jsonb,text),public.get_owner_mixed_points_policy(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
