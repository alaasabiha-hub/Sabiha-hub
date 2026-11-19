-- SOURCE-ONLY; root executes on isolated clone inside an outer BEGIN/ROLLBACK.
-- Inputs are actual current owner claims (including session_id), an existing
-- legacy invoice ID and its QA branch. Never prints claims/document contents.
-- Existing owner-authorized printer table API is used: no printer-create RPC
-- exists. Supply p_printer only for a NEW dedicated inactive/default-false fixture.
create or replace function pg_temp.probe_invoice_print_live_session(
 p_owner_claims jsonb,p_invoice text,p_branch uuid,p_printer uuid default null
) returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare
 v_owner uuid:=(p_owner_claims->>'sub')::uuid;
 v_session uuid:=(p_owner_claims->>'session_id')::uuid;
 v_printer uuid:=coalesce(p_printer,gen_random_uuid());
 v_job uuid:=gen_random_uuid();v_invalid jsonb;v_claim jsonb;v_document jsonb;
 v_before jsonb;v_denied boolean:=false;v_created boolean:=p_printer is null;
 v_old_claims text:=current_setting('request.jwt.claims',true);
 v_old_sub text:=current_setting('request.jwt.claim.sub',true);
 v_old_role text:=current_setting('request.jwt.claim.role',true);
 v_role name:=current_user;
begin
 if left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'Explicit isolated QA clone required';end if;
 if v_role not in ('postgres','supabase_admin') then raise exception 'Isolated privileged test runner required';end if;
 if v_owner is null or v_session is null or p_branch is null or p_invoice is null then raise exception 'Exact fixture inputs required';end if;
 if not exists(select 1 from auth.sessions where id=v_session and user_id=v_owner)
 or not exists(select 1 from public.staff_profiles where user_id=v_owner and role='owner' and is_active)
 then raise exception 'Actual current owner session required';end if;
 select to_jsonb(i) into strict v_before from public.business_invoices i where invoice_id=p_invoice and branch_id=p_branch;
 if not coalesce((v_before->>'document_link_enabled')::boolean,false) then raise exception 'Enabled legacy QA document required';end if;
 if coalesce(v_before->>'commission_model','legacy_scalar')<>'legacy_scalar' then raise exception 'Legacy invoice fixture required';end if;
 perform set_config('request.jwt.claims',p_owner_claims::text,true);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform set_config('request.jwt.claim.role','authenticated',true);
 set local role authenticated;
 if v_created then
  insert into public.business_printers(printer_id,branch_id,name,paper,transport,device_identifier,is_default,is_active,auto_print)
  values(v_printer,p_branch,'QA live-session print probe','A4','system','',false,true,false);
 else
  if not exists(select 1 from public.business_printers where printer_id=v_printer and branch_id=p_branch and not is_default and not auto_print and is_active)
  or exists(select 1 from public.business_print_jobs where printer_id=v_printer) then raise exception 'Dedicated unused printer required';end if;
 end if;
 if public.request_invoice_print(v_job,p_invoice,v_printer) is distinct from v_job then raise exception 'Unexpected job receipt';end if;
 -- Same real actor, nonexistent session: current-session checks must reject
 -- BEFORE leasing, and an exception subtransaction must retain queued state.
 v_invalid:=jsonb_set(p_owner_claims,'{session_id}',to_jsonb(gen_random_uuid()::text));
 perform set_config('request.jwt.claims',v_invalid::text,true);
 begin
  perform public.claim_invoice_print(v_job);
 exception when insufficient_privilege then v_denied:=true;
 end;
 if not v_denied then raise exception 'Stale session unexpectedly claimed print job';end if;
 if not exists(select 1 from public.business_print_jobs where job_id=v_job and status='pending' and lease_token is null and lease_until is null and leased_by is null and attempt_count=0)
 or exists(select 1 from public.business_print_attempts where job_id=v_job) then raise exception 'Denied claim changed queued job';end if;
 perform set_config('request.jwt.claims',p_owner_claims::text,true);
 v_document:=public.resolve_invoice_document((v_before->>'document_token')::uuid);
 v_claim:=public.claim_invoice_print(v_job);
 if v_claim->>'job_id' is distinct from v_job::text or v_claim->>'lease_token' is null
 or v_claim->'invoice' is distinct from v_document then raise exception 'Current claim document/lease mismatch';end if;
 -- No physical submission: canonical finish API records simulated unavailable.
 perform public.finish_invoice_print(v_job,(v_claim->>'lease_token')::uuid,'failed','isolated_no_printer_connected');
 if not exists(select 1 from public.business_print_jobs where job_id=v_job and status='failed' and lease_until is null and attempt_count=1)
 or not exists(select 1 from public.business_print_attempts where job_id=v_job and attempt_number=1 and outcome='failed' and finished_at is not null)
 then raise exception 'Canonical finish failed';end if;
 if v_created then update public.business_printers set is_active=false where printer_id=v_printer;end if;
 reset role;
 if (select to_jsonb(i) from public.business_invoices i where invoice_id=p_invoice) is distinct from v_before then raise exception 'Invoice mutated';end if;
 perform set_config('request.jwt.claims',coalesce(v_old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(v_old_sub,''),true);
 perform set_config('request.jwt.claim.role',coalesce(v_old_role,''),true);
 return jsonb_build_object('all_passed',true,'invalid_session_sqlstate','42501','denied_job_unleased',true,'current_session_document_unchanged',true,'canonical_finish_failed_no_printer',true,'invoice_unchanged',true,'requires_outer_rollback',true);
exception when others then
 reset role;
 perform set_config('request.jwt.claims',coalesce(v_old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(v_old_sub,''),true);
 perform set_config('request.jwt.claim.role',coalesce(v_old_role,''),true);
 raise;
end;$$;
-- Invocation in root's private runner (never echo claims):
-- BEGIN; \i <this file>
-- SELECT pg_temp.probe_invoice_print_live_session(<claims jsonb>,<invoice text>,<branch uuid>);
-- ROLLBACK;
