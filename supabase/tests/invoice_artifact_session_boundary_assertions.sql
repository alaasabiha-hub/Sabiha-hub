-- Clone-only helpers. Root executes in outer ROLLBACK; no author execution.
-- This helper is read-only and can be invoked in an actual READ ONLY transaction.
-- Raw invoice SELECT already lacks authenticated ACL: preserve/report that denial.
-- Actual reachable surfaces are the definer summary and the other three granted tables;
-- the invoice restrictive policy adds defense in depth, not a proven raw-snapshot bypass fix.
create function pg_temp.assert_invoice_artifact_read_boundary() returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims');claims jsonb:=original_claims::jsonb;
 baseline_summary jsonb;result_summary jsonb;t text;before_rows jsonb;after_rows jsonb;baseline jsonb:='{}'::jsonb;
 n bigint;variant jsonb;cases integer:=0;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 set local role authenticated;
 if not private.has_live_invoice_session() then raise exception 'Actual current session required';end if;
 baseline_summary:=public.list_invoice_documents();
 foreach t in array array['business_invoices','business_printers','business_print_jobs','business_print_attempts']loop
  begin
   execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]''::jsonb) from public.%I x',t)into before_rows;
  exception when insufficient_privilege then
   if t<>'business_invoices' then raise;end if;
   before_rows:='{"protection":"existing_acl_denial"}'::jsonb;
  end;
  baseline:=baseline||jsonb_build_object(t,before_rows);
 end loop;
 reset role;
 for variant in select x from jsonb_array_elements(jsonb_build_array(claims-'session_id',
 jsonb_set(claims,'{session_id}','"malformed"'::jsonb),
 jsonb_set(claims,'{session_id}',to_jsonb(gen_random_uuid()::text))))x loop
  perform set_config('request.jwt.claims',variant::text,true);
  set local role authenticated;
  if private.has_live_invoice_session()then raise exception 'Invalid session predicate accepted';end if;
  foreach t in array array['business_invoices','business_printers','business_print_jobs','business_print_attempts']loop
   begin
    -- Compare the SAME projection as baseline: count(*) may require no denied
    -- columns and its success is not evidence of full-row privilege expansion.
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]''::jsonb) from public.%I x',t)into after_rows;
    if baseline->t='{"protection":"existing_acl_denial"}'::jsonb then
     raise exception 'Existing invoice full-row ACL unexpectedly became readable';end if;
    if after_rows is distinct from '[]'::jsonb then raise exception 'Stale session exposed %',t;end if;
   exception when insufficient_privilege then
    if t<>'business_invoices' or baseline->t is distinct from '{"protection":"existing_acl_denial"}'::jsonb then raise;end if;
   end;
   begin
    execute format('select count(*) from public.%I',t)into n;
    if n<>0 then raise exception 'Stale session counted rows in %',t;end if;
   exception when insufficient_privilege then
    if t<>'business_invoices' then raise;end if;
   end;
  end loop;
  result_summary:=public.list_invoice_documents();
  if result_summary is distinct from '[]'::jsonb then raise exception 'Stale summary exposed documents';end if;
  reset role;cases:=cases+1;
 end loop;
 perform set_config('request.jwt.claims',original_claims,true);
 set local role authenticated;
 if public.list_invoice_documents()is distinct from baseline_summary then raise exception 'Valid document summary changed';end if;
 foreach t in array array['business_invoices','business_printers','business_print_jobs','business_print_attempts']loop
  begin
   execute format('select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]''::jsonb) from public.%I x',t)into after_rows;
  exception when insufficient_privilege then
   if t<>'business_invoices' then raise;end if;
   after_rows:='{"protection":"existing_acl_denial"}'::jsonb;
  end;
  if after_rows is distinct from baseline->t then raise exception 'Valid artifact projection changed %',t;end if;
 end loop;
 reset role;
 return jsonb_build_object('invalid_read_cases',cases,'valid_projections_unchanged',true,'invoice_acl_denial_preserved',baseline->'business_invoices'='{"protection":"existing_acl_denial"}'::jsonb,'live_summary_count',jsonb_array_length(baseline_summary));
end $$;

-- Supply an actual QA printer and invoice authorized for this current owner/cashier.
-- No success print is produced. Invalid calls must leave all jobs/attempts untouched.
create function pg_temp.assert_invoice_artifact_write_boundary(p_printer uuid,p_invoice text,p_job uuid,p_lease uuid)
returns jsonb language plpgsql as $$
declare original_claims text:=current_setting('request.jwt.claims');claims jsonb:=original_claims::jsonb;
 before_printer jsonb;after_printer jsonb;before_jobs jsonb;after_jobs jsonb;before_attempts jsonb;after_attempts jsonb;
 affected bigint;denied integer:=0;
begin
 if current_user<>'postgres' or left(current_database(),length('qa_typed_reward_'))<>'qa_typed_reward_' then raise exception 'QA clone required';end if;
 select to_jsonb(p)into strict before_printer from public.business_printers p where printer_id=p_printer;
 select coalesce(jsonb_agg(to_jsonb(j)order by job_id),'[]'::jsonb)into before_jobs from public.business_print_jobs j;
 select coalesce(jsonb_agg(to_jsonb(a)order by attempt_id),'[]'::jsonb)into before_attempts from public.business_print_attempts a;
 perform set_config('request.jwt.claims',(claims-'session_id')::text,true);
 set local role authenticated;
 -- If deployment grants raw printer UPDATE, restrictive USING must yield zero.
 -- A deployment without that grant must continue denying at ACL; never grant for testing.
 begin
  update public.business_printers set name=name where printer_id=p_printer;
  get diagnostics affected=row_count;
  if affected<>0 then raise exception 'Stale raw printer update accepted';end if;
 exception when insufficient_privilege then null;end;
 begin perform public.request_invoice_print(gen_random_uuid(),p_invoice,p_printer);
  raise exception 'Stale request accepted';
 exception when insufficient_privilege then denied:=denied+1;end;
 begin perform public.claim_invoice_print(p_job);
  raise exception 'Stale claim accepted';
 exception when insufficient_privilege then denied:=denied+1;end;
 begin perform public.finish_invoice_print(p_job,p_lease,'failed',null);
  raise exception 'Stale finish accepted';
 exception when insufficient_privilege then denied:=denied+1;end;
 reset role;
 -- Restore current claims BEFORE any RLS-scoped inspection.
 perform set_config('request.jwt.claims',original_claims,true);
 select to_jsonb(p)into strict after_printer from public.business_printers p where printer_id=p_printer;
 select coalesce(jsonb_agg(to_jsonb(j)order by job_id),'[]'::jsonb)into after_jobs from public.business_print_jobs j;
 select coalesce(jsonb_agg(to_jsonb(a)order by attempt_id),'[]'::jsonb)into after_attempts from public.business_print_attempts a;
 if before_printer is distinct from after_printer or before_jobs is distinct from after_jobs or before_attempts is distinct from after_attempts then raise exception 'Stale printer mutation persisted';end if;
 return jsonb_build_object('stale_mutations_denied',denied,'printer_jobs_attempts_unchanged',true);
end $$;
