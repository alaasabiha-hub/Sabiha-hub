begin;
-- Read-only predicate for direct Data API reads. This grants no invoice authorization.
create function private.has_live_invoice_session() returns boolean
language plpgsql stable security definer set search_path=pg_catalog as $$
declare actor uuid:=auth.uid();sid uuid;
begin
 begin sid:=(auth.jwt()->>'session_id')::uuid;
 exception when invalid_text_representation then return false;end;
 if actor is null or sid is null then return false;end if;
 return exists(select 1 from auth.users u join auth.sessions sess on sess.user_id=u.id
 where u.id=actor and sess.id=sid and u.email_confirmed_at is not null and u.deleted_at is null
 and(u.banned_until is null or u.banned_until<=statement_timestamp())
 and(sess.not_after is null or sess.not_after>statement_timestamp()));
end $$;
revoke all on function private.has_live_invoice_session() from public,anon,authenticated,service_role;
grant execute on function private.has_live_invoice_session() to authenticated;
create policy "Current session required for invoice artifacts" on public.business_invoices
 as restrictive for all to authenticated using((select private.has_live_invoice_session()))
 with check((select private.has_live_invoice_session()));
create policy "Current session required for invoice artifacts" on public.business_printers
 as restrictive for all to authenticated using((select private.has_live_invoice_session()))
 with check((select private.has_live_invoice_session()));
create policy "Current session required for invoice artifacts" on public.business_print_jobs
 as restrictive for all to authenticated using((select private.has_live_invoice_session()))
 with check((select private.has_live_invoice_session()));
create policy "Current session required for invoice artifacts" on public.business_print_attempts
 as restrictive for all to authenticated using((select private.has_live_invoice_session()))
 with check((select private.has_live_invoice_session()));
create or replace function private.list_invoice_documents() returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select coalesce(jsonb_agg(to_jsonb(x) order by x.issued_at desc),'[]'::jsonb) from (select i.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,i.document_token,i.issued_at,i.total,i.status,i.document_link_enabled,i.branch_id from public.business_invoices i where private.has_live_invoice_session() and private.can_read_invoice(i.invoice_id) order by i.issued_at desc limit 200) x;
$$;
create or replace function private.request_invoice_print(p_request uuid,p_invoice text,p_printer uuid) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare i public.business_invoices%rowtype;p public.business_printers%rowtype;j public.business_print_jobs%rowtype;begin
 perform private.require_typed_reward_document_session(null);
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(i.branch_id),false) then raise exception 'Cashier access required' using errcode='42501';end if;
 if p_request is null then raise exception 'Request ID required';end if;
 select * into j from public.business_print_jobs where job_id=p_request;
 if found then if j.invoice_id<>p_invoice or j.printer_id is distinct from p_printer or j.purpose<>'manual' then raise exception 'Print request already used';end if;return j.job_id;end if;
 select * into strict p from public.business_printers where printer_id=p_printer and is_active and branch_id=i.branch_id;
 insert into public.business_print_jobs(job_id,invoice_id,branch_id,printer_id,purpose,requested_by,is_reprint) values(p_request,p_invoice,i.branch_id,p.printer_id,'manual',auth.uid(),exists(select 1 from public.business_print_jobs where invoice_id=p_invoice and status in ('submitted','processing')));
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
 is_reprint=is_reprint or attempt_count>0 or status='processing' or exists(select 1 from public.business_print_jobs other where other.invoice_id=j.invoice_id and other.job_id<>j.job_id and other.status in ('processing','submitted')) where job_id=p_job returning * into j;
 insert into public.business_print_attempts(job_id,attempt_number,actor_id) values(p_job,j.attempt_count,auth.uid());
 return jsonb_build_object('job_id',j.job_id,'lease_token',v_lease,'is_reprint',j.is_reprint,'paper',p.paper,'transport',p.transport,'device_identifier',p.device_identifier,'invoice',private.invoice_document_data(i.document_token,true));
end; $$;
create or replace function private.finish_invoice_print(p_job uuid,p_lease uuid,p_outcome text,p_error text default null) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare j public.business_print_jobs%rowtype;begin
 perform private.require_typed_reward_document_session(null);
 select * into strict j from public.business_print_jobs where job_id=p_job for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(j.branch_id),false) or j.leased_by<>auth.uid() or j.lease_token is distinct from p_lease or j.status<>'processing' or j.lease_until<now() then raise exception 'Print lease invalid';end if;
 if p_outcome not in ('submitted','failed') or length(coalesce(p_error,''))>500 then raise exception 'Invalid print outcome';end if;
 update public.business_print_jobs set status=p_outcome,last_error=case when p_outcome='failed' then left(coalesce(p_error,'printer_unavailable'),500) end,lease_until=null where job_id=p_job;
 update public.business_print_attempts set finished_at=now(),outcome=p_outcome,error_code=case when p_outcome='failed' then left(coalesce(p_error,'printer_unavailable'),500) end where job_id=p_job and attempt_number=j.attempt_count;
end; $$;
create or replace function public.list_invoice_documents() returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.list_invoice_documents(); $$;
create or replace function public.request_invoice_print(p_request uuid,p_invoice text,p_printer uuid) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.request_invoice_print(p_request,p_invoice,p_printer); $$;
create or replace function public.claim_invoice_print(p_job uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.claim_invoice_print(p_job); $$;
create or replace function public.finish_invoice_print(p_job uuid,p_lease uuid,p_outcome text,p_error text default null) returns void language sql security invoker set search_path=pg_catalog as $$ select private.finish_invoice_print(p_job,p_lease,p_outcome,p_error); $$;
notify pgrst,'reload schema';
commit;
