begin;
-- Deliberate expansion of the proven session boundary to every invoice document.
-- The original authorization and document projection remain the exact installed body.
create or replace function private.invoice_document_data(p_token uuid,p_allow_revoked boolean) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare invoice_branch uuid;
begin
 select branch_id into invoice_branch from public.business_invoices where document_token=p_token;
 perform private.require_typed_reward_document_session(invoice_branch);
 return private.invoice_document_data_before_typed_session_guard(p_token,p_allow_revoked);
end $$;
revoke all on function private.invoice_document_data(uuid,boolean) from public,anon,authenticated,service_role;
-- Explicitly reparse both direct readers while preserving their OIDs and ACLs.
create or replace function private.resolve_invoice_document(p_token uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog
as $$select private.invoice_document_data(p_token,false)$$;
create or replace function private.claim_invoice_print(p_job uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare j public.business_print_jobs%rowtype;v_lease uuid:=gen_random_uuid();i public.business_invoices%rowtype;p public.business_printers%rowtype;begin
 select * into strict j from public.business_print_jobs where job_id=p_job for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(j.branch_id),false) then raise exception 'Print access denied';end if;
 if j.status='submitted' or j.status='processing' and j.lease_until>now() then raise exception 'Print job already submitted or leased';end if;
 select * into strict p from public.business_printers where printer_id=j.printer_id and is_active and branch_id=j.branch_id;
 select * into strict i from public.business_invoices where invoice_id=j.invoice_id;
 update public.business_print_jobs set status='processing',lease_token=v_lease,lease_until=now()+interval '2 minutes',leased_by=auth.uid(),attempt_count=attempt_count+1,
 is_reprint=is_reprint or attempt_count>0 or status='processing' or exists(select 1 from public.business_print_jobs other where other.invoice_id=j.invoice_id and other.job_id<>j.job_id and other.status in ('processing','submitted')) where job_id=p_job returning * into j;
 insert into public.business_print_attempts(job_id,attempt_number,actor_id) values(p_job,j.attempt_count,auth.uid());
 return jsonb_build_object('job_id',j.job_id,'lease_token',v_lease,'is_reprint',j.is_reprint,'paper',p.paper,'transport',p.transport,'device_identifier',p.device_identifier,'invoice',private.invoice_document_data(i.document_token,true));
end; $$;
notify pgrst,'reload schema';
commit;
