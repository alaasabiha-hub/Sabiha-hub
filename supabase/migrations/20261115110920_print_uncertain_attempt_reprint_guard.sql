begin;
-- Any earlier device attempt may have reached a spooler, including a failed/unknown
-- acknowledgement. Subsequent requests/claims are conservatively marked reprints.
-- No invoice, payment, old job, ACL or session guard is rewritten.
create or replace function private.request_invoice_print(p_request uuid,p_invoice text,p_printer uuid) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare i public.business_invoices%rowtype;p public.business_printers%rowtype;j public.business_print_jobs%rowtype;begin
 perform private.require_typed_reward_document_session(null);
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(i.branch_id),false) then raise exception 'Cashier access required' using errcode='42501';end if;
 if p_request is null then raise exception 'Request ID required';end if;
 select * into j from public.business_print_jobs where job_id=p_request;
 if found then if j.invoice_id<>p_invoice or j.printer_id is distinct from p_printer or j.purpose<>'manual' then raise exception 'Print request already used';end if;return j.job_id;end if;
 select * into strict p from public.business_printers where printer_id=p_printer and is_active and branch_id=i.branch_id;
 insert into public.business_print_jobs(job_id,invoice_id,branch_id,printer_id,purpose,requested_by,is_reprint) values(p_request,p_invoice,i.branch_id,p.printer_id,'manual',auth.uid(),exists(select 1 from public.business_print_jobs where invoice_id=p_invoice and (status in ('submitted','processing') or attempt_count>0)));
 return p_request;end; $$;
create or replace function private.claim_invoice_print(p_job uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare j public.business_print_jobs%rowtype;v_lease uuid:=gen_random_uuid();i public.business_invoices%rowtype;p public.business_printers%rowtype;begin
 perform private.require_typed_reward_document_session(null);
 select * into strict j from public.business_print_jobs where job_id=p_job for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(j.branch_id),false) then raise exception 'Print access denied';end if;
 if j.status='submitted' or j.status='processing' and j.lease_until>now() then raise exception 'Print job already submitted or leased';end if;
 select * into strict p from public.business_printers where printer_id=j.printer_id and is_active and branch_id=j.branch_id;
 select * into strict i from public.business_invoices where invoice_id=j.invoice_id;
 update public.business_print_jobs set status='processing',lease_token=v_lease,lease_until=now()+interval '2 minutes',leased_by=auth.uid(),attempt_count=attempt_count+1,
 is_reprint=is_reprint or attempt_count>0 or status='processing' or exists(select 1 from public.business_print_jobs other where other.invoice_id=j.invoice_id and other.job_id<>j.job_id and (other.status in ('processing','submitted') or other.attempt_count>0)) where job_id=p_job returning * into j;
 insert into public.business_print_attempts(job_id,attempt_number,actor_id) values(p_job,j.attempt_count,auth.uid());
 return jsonb_build_object('job_id',j.job_id,'lease_token',v_lease,'is_reprint',j.is_reprint,'paper',p.paper,'transport',p.transport,'device_identifier',p.device_identifier,'invoice',private.invoice_document_data(i.document_token,true));
end; $$;
notify pgrst,'reload schema';
commit;
