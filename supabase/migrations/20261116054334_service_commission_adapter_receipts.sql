begin;
-- New receipts describe the installed adapter. Prior immutable receipts retain their original state.
CREATE OR REPLACE FUNCTION private.save_owner_service_commission(p_request uuid, p_branch uuid, p_item uuid, p_expected_version integer, p_enabled boolean, p_mode text, p_value numeric, p_split_mode text, p_shares jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare actor uuid;payload jsonb;prior private.owner_service_commission_commands;latest private.owner_service_commission_policies;result jsonb;pid uuid:=gen_random_uuid();begin
 actor:=private.require_owner_tax_branch(p_branch);
 if p_request is null or p_item is null or p_expected_version is null or p_expected_version<0 or p_enabled is null or p_mode is null or p_mode not in('percentage','fixed')or p_value is null or p_value::text in('NaN','Infinity','-Infinity')or p_value<0 or(p_mode='percentage'and p_value>100)or p_split_mode is null or p_split_mode not in('equal','configured')or jsonb_typeof(p_shares)is distinct from'array'or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit valid commission policy required'using errcode='22023';end if;
 if not exists(select 1 from public.business_catalog_items where item_id=p_item and branch_id=p_branch and item_type='service')then raise exception 'Eligible service required'using errcode='42501';end if;
 if(p_split_mode='equal'and jsonb_array_length(p_shares)<>0)or(p_split_mode='configured'and(jsonb_array_length(p_shares)=0 or exists(select 1 from jsonb_array_elements(p_shares)x where jsonb_typeof(x)is distinct from'object'or(select count(*)from jsonb_object_keys(x))<>2 or not(x?'staff_id'and x?'percent')or jsonb_typeof(x->'percent')is distinct from'number'or(x->>'percent')::numeric<=0 or(x->>'percent')::numeric>100)or(select sum((x->>'percent')::numeric)from jsonb_array_elements(p_shares)x)<>100 or(select count(distinct x->>'staff_id')from jsonb_array_elements(p_shares)x)<>jsonb_array_length(p_shares)))then raise exception 'Configured shares must be unique and total exactly 100 percent'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_shares)x where not exists(select 1 from public.staff_profiles s where s.user_id=(x->>'staff_id')::uuid and s.is_active and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=p_branch))))then raise exception 'Active eligible workers required'using errcode='42501';end if;
 payload:=jsonb_build_object('branch',p_branch,'item',p_item,'version',p_expected_version,'enabled',p_enabled,'mode',p_mode,'value',p_value,'split_mode',p_split_mode,'shares',p_shares,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('owner-service-commission-request:'||p_request,0));
 select *into prior from private.owner_service_commission_commands where request_id=p_request;
 if found then if prior.actor_id<>actor or prior.payload<>payload then raise exception 'Request payload mismatch'using errcode='22023';end if;return prior.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('owner-service-commission:'||p_branch||':'||p_item,0));
 select *into latest from private.owner_service_commission_policies where branch_id=p_branch and item_id=p_item order by version desc limit 1;
 if coalesce(latest.version,0)<>p_expected_version then raise exception 'Commission version changed'using errcode='40001';end if;
 insert into private.owner_service_commission_policies values(pid,p_branch,p_item,p_expected_version+1,p_enabled,p_mode,p_value,p_split_mode,p_shares,trim(p_reason),actor,clock_timestamp());
 result:=jsonb_build_object('policy_id',pid,'version',p_expected_version+1,'future_only',true,'work_adapter_enabled',true);
 insert into private.owner_service_commission_commands values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'owner_service_commission_policy_saved','service_commission_policy',p_item::text,p_branch,to_jsonb(latest),payload||result);
 return result;end$function$;
commit;
