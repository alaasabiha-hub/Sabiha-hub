-- Additive local-only invoice identity + durable print outbox. No printer/network I/O
-- occurs in payment transactions; printing cannot invoke any payment function.
alter table public.business_invoices add column document_token uuid not null default gen_random_uuid(),add column document_link_enabled boolean not null default true,add column document_snapshot jsonb,add column document_origin text not null default '';
create unique index invoice_document_token_unique on public.business_invoices(document_token);
create table public.business_invoice_portal_settings(id boolean primary key default true check(id),public_origin text not null default '' check(public_origin='' or public_origin ~ '^https://[a-zA-Z0-9.-]+(:[0-9]+)?$' or public_origin ~ '^http://(localhost|127\.0\.0\.1):[0-9]+$'));
insert into public.business_invoice_portal_settings values(true,'');
alter table public.business_invoice_portal_settings enable row level security;
revoke all on public.business_invoice_portal_settings from anon,authenticated;
grant select on public.business_invoice_portal_settings to authenticated;
grant update(public_origin) on public.business_invoice_portal_settings to authenticated;
grant all on public.business_invoice_portal_settings to service_role;
create policy "Invoice portal read" on public.business_invoice_portal_settings for select to authenticated using(true);
create policy "Owner configures invoice domain" on public.business_invoice_portal_settings for update to authenticated using((select private.active_staff_role())='owner') with check((select private.active_staff_role())='owner');
create function private.invoice_snapshot(p_invoice text) returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('branch',jsonb_build_object('name_ar',b.name_ar,'name_en',b.name_en,'address_ar',b.address_ar,'address_en',b.address_en),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('name',x.item_name,'quantity',x.quantity,'unit_price',x.unit_price,'subtotal',x.subtotal) order by x.created_at,x.order_item_id) from public.business_order_items x where x.order_id=i.order_id),jsonb_build_array(jsonb_build_object('name',i.service_name,'quantity',1,'unit_price',i.total+i.discount,'subtotal',i.total+i.discount))),
 'currency','EGP','discount',i.discount,'total',i.total,'tax_amount',null,'tax_configuration','not_recorded_in_legacy_invoice',
 'delivery_fee',(select delivery_fee from public.business_order_fulfillments f where f.order_id=i.order_id))
 from public.business_invoices i join public.business_branches b using(branch_id) where i.invoice_id=p_invoice;
$$;
revoke all on function private.invoice_snapshot(text) from public;
update public.business_invoices i set document_snapshot=private.invoice_snapshot(i.invoice_id);
create function private.stamp_invoice_document() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 if tg_op='INSERT' then update public.business_invoices set document_snapshot=private.invoice_snapshot(new.invoice_id),document_origin=(select public_origin from public.business_invoice_portal_settings where id) where invoice_id=new.invoice_id;return new;end if;
 if old.document_origin<>'' and new.document_origin is distinct from old.document_origin then raise exception 'Invoice QR origin is immutable';end if;
 if old.document_snapshot is not null and (new.document_snapshot is distinct from old.document_snapshot or new.document_token is distinct from old.document_token or new.branch_id is distinct from old.branch_id or new.order_id is distinct from old.order_id) then raise exception 'Invoice document identity and snapshot are immutable';end if;
 if new.total is distinct from old.total or new.discount is distinct from old.discount then
 -- Existing server loyalty finalization can adjust an unpaid invoice; the paid
 -- ledger guard rejects financial changes after collection. Keep the QR stable.
 new.document_snapshot:=old.document_snapshot||jsonb_build_object('total',new.total,'discount',new.discount);end if;return new;end; $$;
revoke all on function private.stamp_invoice_document() from public;
create trigger invoice_document_snapshot after insert on public.business_invoices for each row execute function private.stamp_invoice_document();
create trigger invoice_document_immutable before update on public.business_invoices for each row execute function private.stamp_invoice_document();
create function private.bind_unconfigured_invoice_origins() returns trigger language plpgsql security definer set search_path=pg_catalog as $$ begin
 if new.public_origin<>'' then update public.business_invoices set document_origin=new.public_origin where document_origin='';end if;return new;end; $$;
revoke all on function private.bind_unconfigured_invoice_origins() from public;
create trigger bind_invoice_origins after update of public_origin on public.business_invoice_portal_settings for each row execute function private.bind_unconfigured_invoice_origins();
create function private.can_read_invoice(p_invoice text) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select auth.uid() is not null and exists(select 1 from public.business_invoices i left join public.business_orders o on o.order_id=i.order_id where i.invoice_id=p_invoice and (o.customer_id=auth.uid() or private.can_cashier_branch(i.branch_id)));
$$;
revoke all on function private.can_read_invoice(text) from public,anon;
grant execute on function private.can_read_invoice(text) to authenticated;
-- Restricts legacy permissive manager invoice policies to the authorized branch.
create policy "Invoice branch boundary" on public.business_invoices as restrictive for select to authenticated using((select private.can_read_invoice(invoice_id)));
create function private.invoice_document_data(p_token uuid,p_allow_revoked boolean) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare i public.business_invoices%rowtype;o public.business_orders%rowtype;b public.bookings%rowtype;v_origin text;v_paid boolean;begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 select * into i from public.business_invoices where document_token=p_token and (document_link_enabled or p_allow_revoked);
 if not found or not coalesce(private.can_read_invoice(i.invoice_id),false) then raise exception 'Invoice unavailable or not authorized' using errcode='42501';end if;
 select * into o from public.business_orders where order_id=i.order_id;
 select * into b from public.bookings where id=o.booking_id;
 v_origin:=i.document_origin;
 select exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale') into v_paid;
 return jsonb_build_object('invoice_id',i.invoice_id,'document_token',i.document_token,'issued_at',i.issued_at,'branch_id',i.branch_id,'snapshot',i.document_snapshot,
 'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when v_paid then 'paid' else 'unpaid' end,
 'payment_method',i.payment_method,'order_id',i.order_id,'booking_id',o.booking_id,'vehicle_id',b.vehicle_id,'service_status',coalesce(b.status,o.status),'portal_origin',v_origin);
end; $$;
revoke all on function private.invoice_document_data(uuid,boolean) from public,anon,authenticated;
create function private.resolve_invoice_document(p_token uuid) returns jsonb language sql stable security definer set search_path=pg_catalog as $$ select private.invoice_document_data(p_token,false); $$;
create function private.list_invoice_documents() returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select coalesce(jsonb_agg(to_jsonb(x) order by x.issued_at desc),'[]'::jsonb) from (select i.invoice_id,i.document_token,i.issued_at,i.total,i.status,i.document_link_enabled,i.branch_id from public.business_invoices i where private.can_read_invoice(i.invoice_id) order by i.issued_at desc limit 200) x;
$$;
create function private.set_invoice_link(p_invoice text,p_enabled boolean) returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if private.active_staff_role() is distinct from 'owner' or p_enabled is null then raise exception 'Owner required';end if;
 update public.business_invoices set document_link_enabled=p_enabled where invoice_id=p_invoice;if not found then raise exception 'Invoice unavailable';end if;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,after_data) values(auth.uid()::text,auth.uid(),'invoice_link_setting','business_invoices',p_invoice,jsonb_build_object('enabled',p_enabled));end; $$;
create table public.business_printers(
 printer_id uuid primary key default gen_random_uuid(),branch_id uuid not null references public.business_branches(branch_id),name text not null check(length(trim(name)) between 2 and 100),
 paper text not null check(paper in ('A4','58','80')),transport text not null check(transport in ('system','usb','bluetooth','network','wifi')),
 device_identifier text not null default '' check(length(device_identifier)<=300),is_default boolean not null default false,is_active boolean not null default true,auto_print boolean not null default false);
create unique index printer_default_branch on public.business_printers(branch_id) where is_default;
create table public.business_print_jobs(
 job_id uuid primary key,invoice_id text not null references public.business_invoices(invoice_id),branch_id uuid not null references public.business_branches(branch_id),printer_id uuid references public.business_printers(printer_id),
 payment_id uuid references public.business_payment_events(payment_id),purpose text not null check(purpose in ('automatic','manual')),is_reprint boolean not null default false,
 status text not null default 'pending' check(status in ('pending','processing','submitted','failed')),requested_by uuid,created_at timestamptz not null default now(),
 lease_token uuid,lease_until timestamptz,leased_by uuid,attempt_count integer not null default 0,last_error text,
 unique(payment_id,purpose));
create index print_jobs_branch_state on public.business_print_jobs(branch_id,status,created_at);
create table public.business_print_attempts(attempt_id uuid primary key default gen_random_uuid(),job_id uuid not null references public.business_print_jobs(job_id),attempt_number integer not null,actor_id uuid not null,
 started_at timestamptz not null default now(),finished_at timestamptz,outcome text check(outcome in ('submitted','failed')),error_code text check(length(error_code)<=500),unique(job_id,attempt_number));
alter table public.business_printers enable row level security;
alter table public.business_print_jobs enable row level security;
alter table public.business_print_attempts enable row level security;
revoke all on public.business_printers,public.business_print_jobs,public.business_print_attempts from anon,authenticated;
grant select on public.business_printers,public.business_print_jobs,public.business_print_attempts to authenticated;
grant insert,update on public.business_printers to authenticated;
grant all on public.business_printers,public.business_print_jobs,public.business_print_attempts to service_role;
create policy "Authorized printer reads" on public.business_printers for select to authenticated using((select private.can_cashier_branch(branch_id)));
create policy "Owner manages branch printers" on public.business_printers for all to authenticated using((select private.active_staff_role())='owner') with check((select private.active_staff_role())='owner');
create policy "Authorized print queue reads" on public.business_print_jobs for select to authenticated using((select private.can_cashier_branch(branch_id)));
create policy "Authorized print attempt reads" on public.business_print_attempts for select to authenticated using(exists(select 1 from public.business_print_jobs j where j.job_id=business_print_attempts.job_id));
create function private.enqueue_payment_receipt() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare p public.business_printers%rowtype;v_branch uuid;begin
 select branch_id into v_branch from public.business_invoices where invoice_id=new.invoice_id;
 select * into p from public.business_printers where branch_id=v_branch and is_default and is_active and auto_print;
 if found then insert into public.business_print_jobs(job_id,invoice_id,branch_id,printer_id,payment_id,purpose,requested_by,is_reprint)
 values(gen_random_uuid(),new.invoice_id,v_branch,p.printer_id,new.payment_id,'automatic',new.actor_id,new.event_type='refund') on conflict(payment_id,purpose) do nothing;end if;return new;end; $$;
revoke all on function private.enqueue_payment_receipt() from public;
create trigger payment_receipt_outbox after insert on public.business_payment_events for each row execute function private.enqueue_payment_receipt();
create function private.request_invoice_print(p_request uuid,p_invoice text,p_printer uuid) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare i public.business_invoices%rowtype;p public.business_printers%rowtype;j public.business_print_jobs%rowtype;begin
 select * into strict i from public.business_invoices where invoice_id=p_invoice for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(i.branch_id),false) then raise exception 'Cashier access required' using errcode='42501';end if;
 if p_request is null then raise exception 'Request ID required';end if;
 select * into j from public.business_print_jobs where job_id=p_request;
 if found then if j.invoice_id<>p_invoice or j.printer_id is distinct from p_printer or j.purpose<>'manual' then raise exception 'Print request already used';end if;return j.job_id;end if;
 select * into strict p from public.business_printers where printer_id=p_printer and is_active and branch_id=i.branch_id;
 insert into public.business_print_jobs(job_id,invoice_id,branch_id,printer_id,purpose,requested_by,is_reprint) values(p_request,p_invoice,i.branch_id,p.printer_id,'manual',auth.uid(),exists(select 1 from public.business_print_jobs where invoice_id=p_invoice and status in ('submitted','processing')));
 return p_request;end; $$;
create function private.claim_invoice_print(p_job uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
create function private.finish_invoice_print(p_job uuid,p_lease uuid,p_outcome text,p_error text default null) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare j public.business_print_jobs%rowtype;begin
 select * into strict j from public.business_print_jobs where job_id=p_job for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(j.branch_id),false) or j.leased_by<>auth.uid() or j.lease_token is distinct from p_lease or j.status<>'processing' or j.lease_until<now() then raise exception 'Print lease invalid';end if;
 if p_outcome not in ('submitted','failed') or length(coalesce(p_error,''))>500 then raise exception 'Invalid print outcome';end if;
 update public.business_print_jobs set status=p_outcome,last_error=case when p_outcome='failed' then left(coalesce(p_error,'printer_unavailable'),500) end,lease_until=null where job_id=p_job;
 update public.business_print_attempts set finished_at=now(),outcome=p_outcome,error_code=case when p_outcome='failed' then left(coalesce(p_error,'printer_unavailable'),500) end where job_id=p_job and attempt_number=j.attempt_count;
end; $$;

revoke all on function private.resolve_invoice_document(uuid) from public,anon;
grant execute on function private.resolve_invoice_document(uuid) to authenticated;
create function public.resolve_invoice_document(p_token uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.resolve_invoice_document(p_token); $$;
revoke all on function public.resolve_invoice_document(uuid) from public,anon;
grant execute on function public.resolve_invoice_document(uuid) to authenticated;

revoke all on function private.list_invoice_documents() from public,anon;
grant execute on function private.list_invoice_documents() to authenticated;
create function public.list_invoice_documents() returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.list_invoice_documents(); $$;
revoke all on function public.list_invoice_documents() from public,anon;
grant execute on function public.list_invoice_documents() to authenticated;

revoke all on function private.set_invoice_link(text,boolean) from public,anon;
grant execute on function private.set_invoice_link(text,boolean) to authenticated;
create function public.set_invoice_link(p_invoice text,p_enabled boolean) returns void language sql security invoker set search_path=pg_catalog as $$ select private.set_invoice_link(p_invoice,p_enabled); $$;
revoke all on function public.set_invoice_link(text,boolean) from public,anon;
grant execute on function public.set_invoice_link(text,boolean) to authenticated;

revoke all on function private.request_invoice_print(uuid,text,uuid) from public,anon;
grant execute on function private.request_invoice_print(uuid,text,uuid) to authenticated;
create function public.request_invoice_print(p_request uuid,p_invoice text,p_printer uuid) returns uuid language sql security invoker set search_path=pg_catalog as $$ select private.request_invoice_print(p_request,p_invoice,p_printer); $$;
revoke all on function public.request_invoice_print(uuid,text,uuid) from public,anon;
grant execute on function public.request_invoice_print(uuid,text,uuid) to authenticated;

revoke all on function private.claim_invoice_print(uuid) from public,anon;
grant execute on function private.claim_invoice_print(uuid) to authenticated;
create function public.claim_invoice_print(p_job uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$ select private.claim_invoice_print(p_job); $$;
revoke all on function public.claim_invoice_print(uuid) from public,anon;
grant execute on function public.claim_invoice_print(uuid) to authenticated;

revoke all on function private.finish_invoice_print(uuid,uuid,text,text) from public,anon;
grant execute on function private.finish_invoice_print(uuid,uuid,text,text) to authenticated;
create function public.finish_invoice_print(p_job uuid,p_lease uuid,p_outcome text,p_error text default null) returns void language sql security invoker set search_path=pg_catalog as $$ select private.finish_invoice_print(p_job,p_lease,p_outcome,p_error); $$;
revoke all on function public.finish_invoice_print(uuid,uuid,text,text) from public,anon;
grant execute on function public.finish_invoice_print(uuid,uuid,text,text) to authenticated;
notify pgrst,'reload schema';

create function private.retry_invoice_print(p_job uuid) returns void language plpgsql security definer set search_path=pg_catalog as $$
declare j public.business_print_jobs%rowtype;begin
 select * into strict j from public.business_print_jobs where job_id=p_job for update;
 if auth.uid() is null or not coalesce(private.can_cashier_branch(j.branch_id),false) then raise exception 'Print access denied';end if;
 if j.status='pending' then return;end if;
 if j.status<>'failed' then raise exception 'Only a failed print can be retried';end if;
 update public.business_print_jobs set status='pending',lease_token=null,lease_until=null,leased_by=null,is_reprint=true where job_id=p_job;
end; $$;
revoke all on function private.retry_invoice_print(uuid) from public,anon;
grant execute on function private.retry_invoice_print(uuid) to authenticated;
create function public.retry_invoice_print(p_job uuid) returns void language sql security invoker set search_path=pg_catalog as $$ select private.retry_invoice_print(p_job); $$;
revoke all on function public.retry_invoice_print(uuid) from public,anon;
grant execute on function public.retry_invoice_print(uuid) to authenticated;
notify pgrst,'reload schema';
