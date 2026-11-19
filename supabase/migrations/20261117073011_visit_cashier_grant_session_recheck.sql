begin;
-- Revalidate live owner authority after lock waits, including idempotent recovery.
CREATE OR REPLACE FUNCTION private.save_owner_visit_cashier_grant(p_request uuid, p_branch uuid, p_rules uuid, p_staff uuid, p_expected_version integer, p_allowed boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
 SET lock_timeout TO '20s'
AS $function$
declare actor uuid:=private.owner_mixed_visit_actor(p_branch,p_rules);old private.mixed_visit_cashier_grant_requests;v private.mixed_visit_cashier_grant_versions;payload jsonb;result jsonb;begin
 if p_request is null or p_staff is null or p_expected_version is null or p_expected_version<0 or p_expected_version=2147483647 or p_allowed is null or length(trim(coalesce(p_reason,'')))not between 10 and 500 then raise exception 'Exact grant version/request and audit reason required'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'rules',p_rules,'staff',p_staff,'expected',p_expected_version,'allowed',p_allowed,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('visit-cashier-grant-request:'||p_request,0));
 actor:=private.owner_mixed_visit_actor(p_branch,p_rules);
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
 perform private.owner_mixed_visit_actor(p_branch,p_rules);
 return result;
end$function$;
commit;
