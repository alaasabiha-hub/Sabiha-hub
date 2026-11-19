-- Own-customer history with explicit field whitelist, no new data or tables.
begin;
create or replace function private.get_customer_booking_history() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.booking_date desc,h.booking_time desc,h.id) from (
    select b.id,b.service_name,b.booking_date,b.booking_time,b.status,b.quoted_price,b.notes,b.vehicle_id,
      case when v.id is not null then jsonb_build_object('brand',v.brand,'model',v.model,'year',v.year,'plate_number',v.plate_number) end vehicle,
      i.invoice_id,i.document_token invoice_token,
      case when i.invoice_id is null then 'not_recorded' when i.status='void' then 'cancelled'
        when i.status='refunded' then 'refunded'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='cash') then 'paid'
        when exists(select 1 from public.business_payment_events e where e.invoice_id=i.invoice_id and e.event_type='sale' and e.method='electronic') then 'verification_required'
        else 'unpaid' end payment_status,
      i.payment_method
    from public.bookings b
    left join public.vehicles v on v.id=b.vehicle_id and v.customer_id=b.customer_id
    left join lateral (
      select x.invoice_id,x.document_token,x.status,x.payment_method from public.business_orders o
      join public.business_invoices x on x.order_id=o.order_id and x.branch_id=b.branch_id
      where o.booking_id=b.id and o.customer_id=b.customer_id and o.branch_id=b.branch_id
      order by x.issued_at desc,x.invoice_id limit 1
    ) i on true
    where b.customer_id=auth.uid()
  ) h),'[]'::jsonb);
end;$$;
create or replace function public.get_customer_booking_history() returns jsonb
language sql stable security invoker set search_path=pg_catalog as $$ select private.get_customer_booking_history(); $$;
revoke all on function private.get_customer_booking_history(),public.get_customer_booking_history() from public,anon;
grant execute on function private.get_customer_booking_history(),public.get_customer_booking_history() to authenticated;

-- Legacy manual electronic entries are retained, but are not gateway proof.
create or replace function private.invoice_document_data(p_token uuid,p_allow_revoked boolean) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog as $$
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
 'payment_method',i.payment_method,'order_id',i.order_id,'booking_id',o.booking_id,'vehicle_id',b.vehicle_id,'service_status',coalesce(b.status,o.status),'portal_origin',i.document_origin);
end;$$;
revoke all on function private.invoice_document_data(uuid,boolean) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
