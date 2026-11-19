begin;
create or replace function private.invoice_payment_quote(p_invoice text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare i public.business_invoices%rowtype;begin
 if not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 return jsonb_build_object('invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'base_amount',i.total,'customer_fee',0,'cash_total',i.total,'card_total',i.total,'currency','EGP','policy',case when i.payment_policy_snapshot is null then null else jsonb_build_object('base_amount',i.total,'currency','EGP','customer_fee',0,'cash_total',i.total,'card_total',i.total,'merchant_absorbs_fee',true,'versions',coalesce((select jsonb_object_agg(key,jsonb_build_object('version_id',value->>'version_id')) from jsonb_each(i.payment_policy_snapshot->'versions')),'{}'::jsonb)) end,'live_enabled',false,'sandbox_only',true);
end;$$;
commit;
