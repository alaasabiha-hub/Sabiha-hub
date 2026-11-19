-- Future rows only. Internal identifiers and every legacy row remain untouched.
begin;
create table private.document_number_counters(kind text primary key check(kind in ('BKG','INV')), last_value bigint not null check(last_value>=0));
alter table private.document_number_counters enable row level security;
revoke all on private.document_number_counters from public,anon,authenticated,service_role;
insert into private.document_number_counters values('BKG',0),('INV',0);
alter table public.bookings add column display_number text unique;
alter table public.business_invoices add column display_number text unique;
create function private.assign_document_number() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare k text; n bigint; existing_number text;
begin
 if tg_op='UPDATE' then
  if new.display_number is distinct from old.display_number then raise exception 'Document display number is immutable';end if;
  return new;
 end if;
 -- Preserve the existing number during an idempotent INSERT ON CONFLICT retry.
 if tg_table_name='bookings' then
  select display_number into existing_number from public.bookings where id=new.id;
 else
  select display_number into existing_number from public.business_invoices where invoice_id=new.invoice_id;
 end if;
 if found then new.display_number:=existing_number;return new;end if;
 k:=case when tg_table_name='bookings' then 'BKG' else 'INV' end;
 update private.document_number_counters set last_value=last_value+1 where kind=k returning last_value into n;
 if n is null then raise exception 'Document numbering is not configured';end if;
 new.display_number:='SH-'||k||'-'||lpad(n::text,greatest(6,length(n::text)),'0');
 return new;
end;$$;
revoke all on function private.assign_document_number() from public,anon,authenticated;
create trigger assign_booking_number before insert or update of display_number on public.bookings for each row execute function private.assign_document_number();
create trigger assign_invoice_number before insert or update of display_number on public.business_invoices for each row execute function private.assign_document_number();
grant select(display_number) on public.bookings,public.business_invoices to authenticated;

create function private.search_invoice_documents(p_query text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 if length(coalesce(p_query,''))>100 then raise exception 'Search too long';end if;
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
 select i.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,i.document_token,i.total,i.issued_at,i.status
 from public.business_invoices i left join public.business_orders o on o.order_id=i.order_id left join public.customers c on c.id=o.customer_id
 where private.can_read_invoice(i.invoice_id) and (coalesce(trim(p_query),'')='' or
 strpos(lower(coalesce(i.display_number,i.invoice_id)),lower(trim(p_query)))>0 or
 (length(regexp_replace(p_query,'[^0-9]','','g'))>=4 and strpos(regexp_replace(coalesce(c.phone,o.customer_phone,''),'[^0-9]','','g'),regexp_replace(p_query,'[^0-9]','','g'))>0))
 order by i.issued_at desc limit 200) q),'[]'::jsonb);
end;$$;
create function public.search_invoice_documents(p_query text default '') returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.search_invoice_documents(p_query);$$;
revoke all on function private.search_invoice_documents(text),public.search_invoice_documents(text) from public,anon;
grant execute on function private.search_invoice_documents(text),public.search_invoice_documents(text) to authenticated;

CREATE OR REPLACE FUNCTION private.invoice_document_data(p_token uuid, p_allow_revoked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare i public.business_invoices%rowtype;o public.business_orders%rowtype;b public.bookings%rowtype;v_paid boolean;v_unverified boolean;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 select * into i from public.business_invoices where document_token=p_token and (document_link_enabled or p_allow_revoked);
 if not found or not coalesce(private.can_read_invoice(i.invoice_id),false) then raise exception 'Invoice unavailable or not authorized' using errcode='42501';end if;
 select * into o from public.business_orders where order_id=i.order_id;
 select * into b from public.bookings where id=o.booking_id;
 select exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='cash') into v_paid;
 select exists(select 1 from public.business_payment_events where invoice_id=i.invoice_id and event_type='sale' and method='electronic') into v_unverified;
 return jsonb_build_object('invoice_id',i.invoice_id,'document_token',i.document_token,'issued_at',i.issued_at,'branch_id',i.branch_id,'snapshot',i.document_snapshot,
 'payment_status',case when i.status='void' then 'cancelled' when i.status='refunded' then 'refunded' when v_paid then 'paid' when v_unverified then 'verification_required' else 'unpaid' end,
 'payment_method',i.payment_method,'order_id',i.order_id,'booking_id',o.booking_id,'vehicle_id',b.vehicle_id,'service_status',coalesce(b.status,o.status),'portal_origin',i.document_origin,'invoice_number',coalesce(i.display_number,i.invoice_id),'booking_number',coalesce(b.display_number,b.id::text),'issued_at_cairo',to_char(i.issued_at at time zone 'Africa/Cairo','YYYY-MM-DD"T"HH24:MI:SS'));
end;$function$;


CREATE OR REPLACE FUNCTION private.get_customer_booking_history()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.booking_date desc,h.booking_time desc,h.id) from (
    select b.id,coalesce(b.display_number,b.id::text) booking_number,b.service_name,b.booking_date,b.booking_time,b.status,b.quoted_price,b.notes,b.vehicle_id,
      case when v.id is not null then jsonb_build_object('brand',v.brand,'model',v.model,'year',v.year,'plate_number',v.plate_number) end vehicle,
      i.invoice_id,i.invoice_number,i.document_token invoice_token,
      case when i.invoice_id is null then 'not_recorded' when i.status='void' then 'cancelled'
        when i.status='refunded' then 'refunded'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='cash') then 'paid'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='electronic') then 'verification_required'
        else 'unpaid' end payment_status,
      i.payment_method
    from public.bookings b
    left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
    left join lateral (
      select x.invoice_id,coalesce(x.display_number,x.invoice_id) invoice_number,x.document_token,x.status,x.payment_method from public.business_orders o
      join public.business_invoices x on x.order_id=o.order_id and x.branch_id=b.branch_id
      where o.booking_id=b.id and o.customer_id=b.customer_id and o.branch_id=b.branch_id
      order by x.issued_at desc,x.invoice_id limit 1
    ) i on true
    where b.customer_id=auth.uid()
  ) h),'[]'::jsonb);
end;$function$;


CREATE OR REPLACE FUNCTION private.list_invoice_documents()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 select coalesce(jsonb_agg(to_jsonb(x) order by x.issued_at desc),'[]'::jsonb) from (select i.invoice_id,coalesce(i.display_number,i.invoice_id) invoice_number,i.document_token,i.issued_at,i.total,i.status,i.document_link_enabled,i.branch_id from public.business_invoices i where private.can_read_invoice(i.invoice_id) order by i.issued_at desc limit 200) x;
$function$;


CREATE OR REPLACE FUNCTION private.shift_invoice_options(p_branch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;begin
 if not coalesce(private.can_cashier_branch(p_branch),false) then raise exception 'Cashier branch permission required';end if;
 select coalesce(jsonb_agg(jsonb_build_object('invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'total',i.total,'status',i.status,'paid',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='sale'),'refunded',exists(select 1 from public.business_payment_events p where p.invoice_id=i.invoice_id and p.event_type='refund'))),'[]') into result from (select * from public.business_invoices where branch_id=p_branch and status<>'void' order by issued_at desc limit 200) i;return result;
end; $function$;


notify pgrst,'reload schema';
commit;
