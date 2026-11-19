begin;
-- Future-only, append-only owner rules. This migration does not rewrite or
-- activate a replacement for any existing earned commission/payroll record.
create table private.owner_service_commission_policies(
 policy_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),item_id uuid not null references public.business_catalog_items(item_id),
 version integer not null check(version>0),enabled boolean not null,mode text not null check(mode in('percentage','fixed')),
 value numeric(18,5)not null check(value>=0 and value::text not in('NaN','Infinity','-Infinity')and(mode<>'percentage'or value<=100)),
 split_mode text not null check(split_mode in('equal','configured')),shares jsonb not null,
 reason text not null,actor_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),unique(branch_id,item_id,version));
create table private.owner_service_commission_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['owner_service_commission_policies','owner_service_commission_commands']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_owner_commission_history before update or delete on private.%I for each row execute function private.owner_tax_immutable()',t);end loop;end$$;
create function private.save_owner_service_commission(p_request uuid,p_branch uuid,p_item uuid,p_expected_version integer,p_enabled boolean,p_mode text,p_value numeric,p_split_mode text,p_shares jsonb,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
 result:=jsonb_build_object('policy_id',pid,'version',p_expected_version+1,'future_only',true,'work_adapter_enabled',false);
 insert into private.owner_service_commission_commands values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'owner_service_commission_policy_saved','service_commission_policy',p_item::text,p_branch,to_jsonb(latest),payload||result);
 return result;end$$;
create function private.preview_owner_service_commission(p_branch uuid,p_item uuid,p_base numeric,p_staff uuid[])returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare policy private.owner_service_commission_policies;total numeric;remaining numeric;amount numeric;worker uuid;weight numeric;allocations jsonb:='[]';n integer;idx integer:=0;begin
 perform private.require_owner_tax_branch(p_branch);
 if p_base is null or p_base<0 or p_base::text in('NaN','Infinity','-Infinity')or cardinality(p_staff)is null or cardinality(p_staff)=0 or array_position(p_staff,null)is not null or(select count(distinct x)from unnest(p_staff)x)<>cardinality(p_staff)then raise exception 'Valid pretax base and unique crew required'using errcode='22023';end if;
 select *into policy from private.owner_service_commission_policies where branch_id=p_branch and item_id=p_item order by version desc limit 1;
 if not found then return jsonb_build_object('configured',false,'work_adapter_enabled',false);end if;
 if policy.split_mode='configured'and(select array_agg((x->>'staff_id')::uuid order by(x->>'staff_id')::uuid)from jsonb_array_elements(policy.shares)x)is distinct from(select array_agg(x order by x)from unnest(p_staff)x)then raise exception 'Crew must match the owner configured shares'using errcode='22023';end if;
 total:=case when not policy.enabled then 0 when policy.mode='percentage'then round(p_base*policy.value/100,2)else round(policy.value,2)end;
 if total>p_base then raise exception 'Commission exceeds service pretax base'using errcode='22023';end if;
 remaining:=total;n:=cardinality(p_staff);
 for worker in select x from unnest(p_staff)x order by x loop
 idx:=idx+1;weight:=case when policy.split_mode='equal'then 100::numeric/n else(select(x->>'percent')::numeric from jsonb_array_elements(policy.shares)x where(x->>'staff_id')::uuid=worker)end;
 amount:=case when idx=n then remaining else trunc(total*weight/100,2)end;remaining:=remaining-amount;
 allocations:=allocations||jsonb_build_array(jsonb_build_object('staff_id',worker,'share_percent',weight,'amount',amount));end loop;
 return jsonb_build_object('configured',true,'policy_id',policy.policy_id,'version',policy.version,'base_before_discount_ex_tax',p_base,'total_commission',total,'allocations',allocations,'work_adapter_enabled',false);end$$;
create function public.save_owner_service_commission(p_request uuid,p_branch uuid,p_item uuid,p_expected_version integer,p_enabled boolean,p_mode text,p_value numeric,p_split_mode text,p_shares jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_service_commission(p_request,p_branch,p_item,p_expected_version,p_enabled,p_mode,p_value,p_split_mode,p_shares,p_reason)$$;
create function public.preview_owner_service_commission(p_branch uuid,p_item uuid,p_base numeric,p_staff uuid[])returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.preview_owner_service_commission(p_branch,p_item,p_base,p_staff)$$;
revoke all on function private.save_owner_service_commission(uuid,uuid,uuid,integer,boolean,text,numeric,text,jsonb,text),public.save_owner_service_commission(uuid,uuid,uuid,integer,boolean,text,numeric,text,jsonb,text),private.preview_owner_service_commission(uuid,uuid,numeric,uuid[]),public.preview_owner_service_commission(uuid,uuid,numeric,uuid[])from public,anon,authenticated,service_role;
grant execute on function private.save_owner_service_commission(uuid,uuid,uuid,integer,boolean,text,numeric,text,jsonb,text),public.save_owner_service_commission(uuid,uuid,uuid,integer,boolean,text,numeric,text,jsonb,text),private.preview_owner_service_commission(uuid,uuid,numeric,uuid[]),public.preview_owner_service_commission(uuid,uuid,numeric,uuid[])to authenticated;
notify pgrst,'reload schema';
commit;
