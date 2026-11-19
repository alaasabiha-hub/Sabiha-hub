begin;
-- Explicit future cashier delegation. This policy alone never enables spending.
create table private.mixed_visit_cashier_grant_versions(
 version_id uuid primary key,branch_id uuid not null references public.business_branches,
 rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),
 staff_id uuid not null references public.staff_profiles(user_id),version_no integer not null check(version_no>0),
 allowed boolean not null,actor_id uuid not null references public.staff_profiles(user_id),reason text not null,
 created_at timestamptz not null default clock_timestamp(),unique(branch_id,rules_version_id,staff_id,version_no));
create table private.mixed_visit_cashier_grant_current(
 branch_id uuid not null references public.business_branches,rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),
 staff_id uuid not null references public.staff_profiles(user_id),version_id uuid not null references private.mixed_visit_cashier_grant_versions(version_id),
 primary key(branch_id,rules_version_id,staff_id));
create table private.mixed_visit_cashier_grant_requests(
 request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),payload jsonb not null,result jsonb not null,
 created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['mixed_visit_cashier_grant_versions','mixed_visit_cashier_grant_current','mixed_visit_cashier_grant_requests']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_visit_cashier_grant before update or delete on private.mixed_visit_cashier_grant_versions for each row execute function private.immutable_loyalty_policy();
create trigger immutable_visit_cashier_grant_request before update or delete on private.mixed_visit_cashier_grant_requests for each row execute function private.immutable_loyalty_policy();
create function private.visit_cashier_eligible(p_staff uuid,p_branch uuid)returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select exists(select 1 from public.staff_profiles s join public.staff_branch_access b on b.user_id=s.user_id
 where s.user_id=p_staff and b.branch_id=p_branch and s.is_active and(s.role='manager'or s.role='employee'and s.permissions->>'cashier'='true'));
$$;
create function private.get_owner_visit_cashier_grants(p_branch uuid,p_rules uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare result jsonb;begin
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.user_id,'name',s.full_name,'eligible',private.visit_cashier_eligible(s.user_id,p_branch),
 'allowed',coalesce(v.allowed,false),'version_no',coalesce(v.version_no,0),'version_id',v.version_id,'changed_at',v.created_at,'changed_by',v.actor_id,'reason',v.reason)order by s.full_name,s.user_id),'[]'::jsonb)into result
 from public.staff_profiles s left join private.mixed_visit_cashier_grant_current c on c.staff_id=s.user_id and c.branch_id=p_branch and c.rules_version_id=p_rules
 left join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id
 where private.visit_cashier_eligible(s.user_id,p_branch)or c.staff_id is not null;
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 return jsonb_build_object('staff',result,'default_allowed',false,'runtime_enabled',(select enabled from private.mixed_visit_pos_runtime where singleton),'allocator_delegation_ready',false,'financial_operation',false);
end$$;
create function private.save_owner_visit_cashier_grant(p_request uuid,p_branch uuid,p_rules uuid,p_staff uuid,p_expected_version integer,p_allowed boolean,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare actor uuid:=private.owner_mixed_visit_actor(p_branch,p_rules);old private.mixed_visit_cashier_grant_requests;v private.mixed_visit_cashier_grant_versions;payload jsonb;result jsonb;begin
 if p_request is null or p_staff is null or p_expected_version is null or p_expected_version<0 or p_expected_version=2147483647 or p_allowed is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact grant version/request and audit reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'rules',p_rules,'staff',p_staff,'expected',p_expected_version,'allowed',p_allowed,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('visit-cashier-grant-request:'||p_request,0));
 select *into old from private.mixed_visit_cashier_grant_requests where request_id=p_request;
 if found then if old.actor_id<>actor then raise exception 'Grant request unavailable'using errcode='42501';end if;if old.payload<>payload then raise exception 'Grant request is immutable'using errcode='22023';end if;return old.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('visit-cashier-grant:'||p_branch||':'||p_rules||':'||p_staff,0));
 actor:=private.owner_mixed_visit_actor(p_branch,p_rules);
 perform 1 from public.staff_profiles where user_id=p_staff for share;
 perform 1 from public.staff_branch_access where user_id=p_staff and branch_id=p_branch for share;
 if p_allowed and not private.visit_cashier_eligible(p_staff,p_branch)then raise exception 'Current branch cashier required'using errcode='42501';end if;
 select x.*into v from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions x on x.version_id=c.version_id
 where c.branch_id=p_branch and c.rules_version_id=p_rules and c.staff_id=p_staff;
 if coalesce(v.version_no,0)<>p_expected_version then raise exception 'Grant changed; refresh before saving'using errcode='40001';end if;
 if not p_allowed and v.version_id is null and not private.visit_cashier_eligible(p_staff,p_branch)then raise exception 'Existing grant or eligible branch cashier required'using errcode='42501';end if;
 insert into private.mixed_visit_cashier_grant_versions values(p_request,p_branch,p_rules,p_staff,p_expected_version+1,p_allowed,actor,trim(p_reason),clock_timestamp());
 insert into private.mixed_visit_cashier_grant_current values(p_branch,p_rules,p_staff,p_request)on conflict(branch_id,rules_version_id,staff_id)do update set version_id=excluded.version_id;
 result:=jsonb_build_object('version_id',p_request,'version_no',p_expected_version+1,'allowed',p_allowed,'redemption_activated',false,'prior_invoices_changed',false);
 insert into private.mixed_visit_cashier_grant_requests values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)
 values(actor::text,actor,'mixed_visit_cashier_grant_saved','staff_profiles',p_staff::text,p_branch,case when v.version_id is null then null else to_jsonb(v)end,
 jsonb_build_object('rules_version_id',p_rules,'version_id',p_request,'allowed',p_allowed,'reason',trim(p_reason),'redemption_activated',false));
 return result;
end$$;
-- Reserved for a separately verified allocator adapter, not a new public debit route.
create function private.visit_cashier_granted(p_branch uuid,p_rules uuid)returns boolean language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.cashier_cart_actor(p_branch);allowed boolean;begin
 select v.allowed into allowed from private.mixed_visit_cashier_grant_current c join private.mixed_visit_cashier_grant_versions v on v.version_id=c.version_id
 where c.branch_id=p_branch and c.rules_version_id=p_rules and c.staff_id=actor for share of c;
 perform private.cashier_cart_actor(p_branch);
 return coalesce(allowed,false)and private.visit_cashier_eligible(actor,p_branch);
end$$;
create function public.get_owner_visit_cashier_grants(p_branch uuid,p_rules uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_visit_cashier_grants(p_branch,p_rules)$$;
create function public.save_owner_visit_cashier_grant(p_request uuid,p_branch uuid,p_rules uuid,p_staff uuid,p_expected_version integer,p_allowed boolean,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_visit_cashier_grant(p_request,p_branch,p_rules,p_staff,p_expected_version,p_allowed,p_reason)$$;
revoke all on function private.visit_cashier_eligible(uuid,uuid),private.visit_cashier_granted(uuid,uuid),private.get_owner_visit_cashier_grants(uuid,uuid),private.save_owner_visit_cashier_grant(uuid,uuid,uuid,uuid,integer,boolean,text),public.get_owner_visit_cashier_grants(uuid,uuid),public.save_owner_visit_cashier_grant(uuid,uuid,uuid,uuid,integer,boolean,text)from public,anon,authenticated,service_role;
grant execute on function private.get_owner_visit_cashier_grants(uuid,uuid),private.save_owner_visit_cashier_grant(uuid,uuid,uuid,uuid,integer,boolean,text),public.get_owner_visit_cashier_grants(uuid,uuid),public.save_owner_visit_cashier_grant(uuid,uuid,uuid,uuid,integer,boolean,text)to authenticated;
notify pgrst,'reload schema';
commit;
