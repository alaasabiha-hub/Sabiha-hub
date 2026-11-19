begin;
-- Future terms only. Saving can never activate a reward issuer or transfer visits.
create table private.owner_mixed_visit_policy_versions(
 version_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),version_no integer not null check(version_no>0),
 terms jsonb not null,source_terms_hash text not null,actor_id uuid not null references public.staff_profiles(user_id),reason text not null,created_at timestamptz not null default clock_timestamp(),unique(branch_id,rules_version_id,version_no));
create table private.owner_mixed_visit_policy_current(branch_id uuid not null references public.business_branches(branch_id),rules_version_id uuid not null references private.loyalty_redemption_rule_versions(rules_version_id),version_id uuid not null references private.owner_mixed_visit_policy_versions(version_id),primary key(branch_id,rules_version_id));
create table private.owner_mixed_visit_policy_requests(request_id uuid primary key,actor_id uuid not null references public.staff_profiles(user_id),payload jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp());
do $$declare t text;begin foreach t in array array['owner_mixed_visit_policy_versions','owner_mixed_visit_policy_current','owner_mixed_visit_policy_requests']loop execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create trigger immutable_owner_mixed_visit_policy before update or delete on private.owner_mixed_visit_policy_versions for each row execute function private.immutable_loyalty_policy();
create trigger immutable_owner_mixed_visit_request before update or delete on private.owner_mixed_visit_policy_requests for each row execute function private.immutable_loyalty_policy();
create function private.owner_mixed_visit_actor(p_branch uuid,p_rules uuid)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;begin
 actor:=private.cashier_cart_actor(p_branch);
 if private.active_staff_role()is distinct from'owner'then raise exception 'Live owner required'using errcode='42501';end if;
 if not exists(select 1 from private.loyalty_redemption_rule_versions where rules_version_id=p_rules and branch_id=p_branch)then raise exception 'Actual benefit rules in this branch required'using errcode='22023';end if;
 return actor;end$$;
create function private.get_owner_mixed_visit_policy(p_branch uuid,p_rules uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare current_version private.owner_mixed_visit_policy_versions;history jsonb;begin
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 select v.*into current_version from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules;
 select coalesce(jsonb_agg(jsonb_build_object('version_id',v.version_id,'version_no',v.version_no,'terms',v.terms,'reason',v.reason,'actor_id',v.actor_id,'created_at',v.created_at)order by v.version_no desc),'[]'::jsonb)into history from(select *from private.owner_mixed_visit_policy_versions where branch_id=p_branch and rules_version_id=p_rules order by version_no desc limit 20)v;
 return jsonb_build_object('branch_id',p_branch,'rules_version_id',p_rules,'current',case when current_version.version_id is null then null else to_jsonb(current_version)end,'history',history,'history_limit',20,'public_redemption_enabled',(select public_enabled from private.offline_reward_issuer_runtime where singleton),'mixed_invoice_issuer_available',false,'future_terms_only',true,'unit','service_visits');end$$;
create function private.save_owner_mixed_visit_policy(p_request uuid,p_branch uuid,p_rules uuid,p_expected_version integer,p_terms jsonb,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid:=private.owner_mixed_visit_actor(p_branch,p_rules);prior private.owner_mixed_visit_policy_requests;current_version private.owner_mixed_visit_policy_versions;payload jsonb;result jsonb;k text;source_hash text;next_version integer;begin
 if p_request is null or p_expected_version is null or p_expected_version<0 or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact version/request and audit reason required'using errcode='22023';end if;
 if jsonb_typeof(p_terms)is distinct from'object'or not(p_terms?&array['unit','allow_walk_in','tax_treatment','tax_review_reference','allow_manual_discount','maximum_covered_units','minimum_invoice_egp'])or p_terms-array['unit','allow_walk_in','tax_treatment','tax_review_reference','allow_manual_discount','maximum_covered_units','minimum_invoice_egp']<>'{}'::jsonb then raise exception 'Complete explicit mixed-visit terms required'using errcode='22023';end if;
 if p_terms->>'unit'is distinct from'service_visits'or p_terms->>'tax_treatment'is distinct from'commercial_before_tax'or jsonb_typeof(p_terms->'tax_review_reference')is distinct from'string'or length(trim(p_terms->>'tax_review_reference'))not between 10 and 500 then raise exception 'Explicit reviewed tax treatment and reference required; no legal default'using errcode='22023';end if;
 foreach k in array array['allow_walk_in','allow_manual_discount']loop if jsonb_typeof(p_terms->k)is distinct from'boolean'then raise exception 'Explicit permission and stacking choice required'using errcode='22023';end if;end loop;
 foreach k in array array['maximum_covered_units','minimum_invoice_egp']loop if jsonb_typeof(p_terms->k)is distinct from'number'or(p_terms->>k)::numeric<0 then raise exception 'Explicit numeric bounds required'using errcode='22023';end if;end loop;
 if(p_terms->>'maximum_covered_units')::numeric<1 or(p_terms->>'maximum_covered_units')::numeric<>trunc((p_terms->>'maximum_covered_units')::numeric)or(p_terms->>'maximum_covered_units')::numeric>2147483647 or round((p_terms->>'minimum_invoice_egp')::numeric,2)<>(p_terms->>'minimum_invoice_egp')::numeric or(p_terms->>'minimum_invoice_egp')::numeric>9999999999.99 then raise exception 'Exact unit bound and invoice-precision minimum required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'rules',p_rules,'expected_version',p_expected_version,'terms',p_terms,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('owner-mixed-visit-request:'||p_request,0));
 select *into prior from private.owner_mixed_visit_policy_requests where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable policy request'using errcode='22023';end if;return prior.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('owner-mixed-visit-policy:'||p_branch||':'||p_rules,0));
 actor:=private.owner_mixed_visit_actor(p_branch,p_rules);
 select v.*into current_version from private.owner_mixed_visit_policy_current c join private.owner_mixed_visit_policy_versions v using(version_id)where c.branch_id=p_branch and c.rules_version_id=p_rules;
 if coalesce(current_version.version_no,0)<>p_expected_version then raise exception 'Policy changed; reload before saving'using errcode='40001';end if;
 next_version:=p_expected_version+1;
 select encode(extensions.digest(terms_snapshot::text,'sha256'),'hex')into strict source_hash from private.loyalty_redemption_rule_versions where rules_version_id=p_rules;
 insert into private.owner_mixed_visit_policy_versions values(p_request,p_branch,p_rules,next_version,p_terms,source_hash,actor,trim(p_reason),clock_timestamp());
 insert into private.owner_mixed_visit_policy_current values(p_branch,p_rules,p_request)on conflict(branch_id,rules_version_id)do update set version_id=excluded.version_id;
 result:=jsonb_build_object('version_id',p_request,'version_no',next_version,'future_terms_only',true,'unit','service_visits','redemption_activated',false,'prior_invoices_changed',false);
 insert into private.owner_mixed_visit_policy_requests values(p_request,actor,payload,result,clock_timestamp());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'owner_mixed_visit_policy_saved','loyalty_redemption_rule',p_rules::text,p_branch,case when current_version.version_id is null then null else to_jsonb(current_version)end,jsonb_build_object('version_id',p_request,'version_no',next_version,'terms',p_terms,'reason',trim(p_reason),'redemption_activated',false));
 return result;end$$;
create function public.get_owner_mixed_visit_policy(p_branch uuid,p_rules uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_owner_mixed_visit_policy(p_branch,p_rules)$$;
create function public.save_owner_mixed_visit_policy(p_request uuid,p_branch uuid,p_rules uuid,p_expected_version integer,p_terms jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_owner_mixed_visit_policy(p_request,p_branch,p_rules,p_expected_version,p_terms,p_reason)$$;
revoke all on function private.owner_mixed_visit_actor(uuid,uuid),private.get_owner_mixed_visit_policy(uuid,uuid),private.save_owner_mixed_visit_policy(uuid,uuid,uuid,integer,jsonb,text),public.get_owner_mixed_visit_policy(uuid,uuid),public.save_owner_mixed_visit_policy(uuid,uuid,uuid,integer,jsonb,text)from public,anon,authenticated,service_role;
grant execute on function private.get_owner_mixed_visit_policy(uuid,uuid),private.save_owner_mixed_visit_policy(uuid,uuid,uuid,integer,jsonb,text),public.get_owner_mixed_visit_policy(uuid,uuid),public.save_owner_mixed_visit_policy(uuid,uuid,uuid,integer,jsonb,text)to authenticated;
notify pgrst,'reload schema';
commit;
