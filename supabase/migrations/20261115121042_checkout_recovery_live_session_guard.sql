-- Require an active confirmed Auth session before private checkout recovery or writes.
-- Existing ownership, idempotency, financial calculations and grants are preserved.

CREATE OR REPLACE FUNCTION private.get_checkout_retry(p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare d private.customer_checkout_retries%rowtype;o public.business_orders%rowtype;f public.business_order_fulfillments%rowtype;begin
 if not private.has_live_invoice_session() then
  raise exception 'Live customer session required' using errcode='42501';
 end if;
 if auth.uid() is null then raise exception 'Customer authentication required' using errcode='42501';end if;
 if p_request is null then select * into d from private.customer_checkout_retries where customer_id=auth.uid() and (state='open' or (state='succeeded' and acknowledged_at is null)) order by created_at,request_id limit 1;
 else select * into d from private.customer_checkout_retries where request_id=p_request;
  if found and d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
 end if;
 if d.request_id is null then return jsonb_build_object('state','absent');end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||d.request_id::text,0));
 select * into d from private.customer_checkout_retries where request_id=d.request_id;
 select bo.* into o from public.business_orders bo join public.business_order_fulfillments bf on bf.order_id=bo.order_id and bf.customer_id=bo.customer_id where bo.customer_id=auth.uid() and bo.customer_request_id=d.request_id and bo.order_type='product';
 if found then
  select * into strict f from public.business_order_fulfillments where order_id=o.order_id and customer_id=auth.uid();
  update private.customer_checkout_retries set state='succeeded',resolved_at=coalesce(resolved_at,now()) where request_id=d.request_id;
  return jsonb_build_object('state','succeeded','request_id',d.request_id,'acknowledged',d.acknowledged_at is not null,'order',jsonb_build_object('order_id',o.order_id,'order_number',o.order_number,'total',f.total));
 end if;
 if d.state='succeeded' then raise exception 'Committed checkout fulfillment unavailable' using errcode='55000';end if;
 return jsonb_build_object('state',d.state,'request_id',d.request_id,'payload',case when d.state='open' then d.payload end,'branch_id',(select branch_id from public.business_catalog_items where item_id::text=d.payload->'p_items'->0->>'item_id'));
end;$function$;

CREATE OR REPLACE FUNCTION private.prepare_checkout_retry(p_request uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare d private.customer_checkout_retries%rowtype;begin
 if not private.has_live_invoice_session() then
  raise exception 'Live customer session required' using errcode='42501';
 end if;
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer authentication required' using errcode='42501';end if;
 if p_request is null or p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>32768 or p_payload->>'p_request_id' is distinct from p_request::text
 or jsonb_typeof(p_payload->'p_items') is distinct from 'array' or jsonb_array_length(p_payload->'p_items') not between 1 and 50
 or coalesce(p_payload->>'p_method','') not in ('pickup','delivery') or (select count(*) from jsonb_object_keys(p_payload))<>9
 or not p_payload ?& array['p_items','p_request_id','p_method','p_zone','p_address','p_phone','p_note','p_coupon','p_expected_total'] then raise exception 'Invalid checkout draft' using errcode='22023';end if;
 perform 1 from public.customers where id=auth.uid() for no key update;
 select * into d from private.customer_checkout_retries where request_id=p_request;
 if found then
  if d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
  if d.payload<>p_payload then raise exception 'Checkout payload mismatch' using errcode='22023';end if;
 else
  if exists(select 1 from private.customer_checkout_retries where customer_id=auth.uid() and (state='open' or (state='succeeded' and acknowledged_at is null))) then raise exception 'Resolve previous checkout first' using errcode='55000';end if;
  insert into private.customer_checkout_retries(request_id,customer_id,payload) values(p_request,auth.uid(),p_payload);
 end if;
 return private.get_checkout_retry(p_request);
end;$function$;

CREATE OR REPLACE FUNCTION private.acknowledge_checkout_retry(p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;begin
 if not private.has_live_invoice_session() then
  raise exception 'Live customer session required' using errcode='42501';
 end if;
 if p_request is null then raise exception 'Request required' using errcode='22023';end if;
 result:=private.get_checkout_retry(p_request);
 if result->>'state' is distinct from 'succeeded' then raise exception 'Only a committed own fulfillment may be acknowledged' using errcode='55000';end if;
 update private.customer_checkout_retries set acknowledged_at=coalesce(acknowledged_at,now()) where request_id=p_request and customer_id=auth.uid();
 return result||jsonb_build_object('acknowledged',true);
end;$function$;

CREATE OR REPLACE FUNCTION private.reject_checkout_retry(p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare d private.customer_checkout_retries%rowtype;result jsonb;begin
 if not private.has_live_invoice_session() then
  raise exception 'Live customer session required' using errcode='42501';
 end if;
 if auth.uid() is null then raise exception 'Customer authentication required' using errcode='42501';end if;
 select * into d from private.customer_checkout_retries where request_id=p_request;
 if not found or d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
 -- The same lock as place_product_fulfillment waits for any in-flight transaction.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request::text,0));
 result:=private.get_checkout_retry(p_request);
 if result->>'state'='succeeded' then return result;end if;
 update private.customer_checkout_retries set state='rejected',resolved_at=coalesce(resolved_at,now()) where request_id=p_request;
 return jsonb_build_object('state','rejected','request_id',p_request);
end;$function$;

CREATE OR REPLACE FUNCTION private.place_product_fulfillment(p_items jsonb, p_request_id uuid, p_method text, p_zone uuid, p_address text, p_phone text, p_note text, p_coupon text, p_expected_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_existing public.business_order_fulfillments%rowtype; v_order record; v_quote jsonb; v_request jsonb;d private.customer_checkout_retries%rowtype;
begin
 if not private.has_live_invoice_session() then
  raise exception 'Live customer session required' using errcode='42501';
 end if;
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer authentication required'; end if;
 if p_request_id is null then raise exception 'Request id required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 select * into d from private.customer_checkout_retries where request_id=p_request_id;
 if found then
  if d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
  if d.payload<>jsonb_build_object('p_items',p_items,'p_request_id',p_request_id,'p_method',p_method,'p_zone',p_zone,'p_address',p_address,'p_phone',p_phone,'p_note',p_note,'p_coupon',p_coupon,'p_expected_total',p_expected_total) then raise exception 'Checkout payload mismatch' using errcode='22023';end if;
 end if;
 select f.* into v_existing from public.business_order_fulfillments f join public.business_orders o using(order_id)
 where o.customer_id=auth.uid() and f.customer_id=auth.uid() and o.customer_request_id=p_request_id;
 if found then
  if v_existing.fulfillment_method is distinct from p_method or v_existing.zone_id is distinct from (case when p_method='delivery' then p_zone end)
   or coalesce(v_existing.address,'')<>coalesce(trim(p_address),'') or coalesce(v_existing.phone,'')<>coalesce(trim(p_phone),'')
   or coalesce(v_existing.delivery_note,'')<>coalesce(trim(p_note),'') then raise exception 'Request id already used for different delivery details'; end if;
  if d.request_id is not null then return jsonb_build_object('order_id',v_existing.order_id,'order_number',(select order_number from public.business_orders where order_id=v_existing.order_id),'total',v_existing.total);end if;
  -- Reuse the established cart/coupon retry validator, without reserving stock again.
  select * into v_order from public.place_customer_product_order(p_items,p_request_id,p_note,p_coupon);
  return jsonb_build_object('order_id',v_existing.order_id,'order_number',v_order.order_number,'total',v_existing.total);
 end if;
 if d.request_id is not null and d.state<>'open' then raise exception 'Checkout draft is closed; delayed placement rejected' using errcode='55000';end if;
 if exists(select 1 from public.business_orders where customer_id=auth.uid() and customer_request_id=p_request_id) then raise exception 'Request id belongs to a legacy order'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Delivery note too long'; end if;
 if p_method='delivery' and (length(trim(coalesce(p_address,''))) not between 10 and 700 or coalesce(p_phone,'') !~ '^\+[1-9][0-9]{7,14}$') then raise exception 'Detailed address and international phone required'; end if;
 -- Lock configuration and cart rows until checkout completes, so the preview and charge use one price snapshot.
 perform 1 from public.business_contact_delivery_settings where id for share;
 perform 1 from public.business_delivery_zones where zone_id=p_zone for share;
 perform 1 from public.business_catalog_items where item_id in (select item_id from jsonb_to_recordset(p_items) x(item_id uuid,quantity integer)) order by item_id for update;
 v_quote:=private.product_fulfillment_quote(p_items,p_method,p_zone,p_coupon);
 if p_expected_total is null or p_expected_total<>(v_quote->>'total')::numeric then raise exception 'Price changed; review the server quote again'; end if;
 select * into v_order from public.place_customer_product_order(p_items,p_request_id,p_note,p_coupon);
 insert into public.business_order_fulfillments(order_id,customer_id,fulfillment_method,zone_id,zone_name,address,phone,delivery_note,delivery_fee,subtotal,discount,total)
 values(v_order.order_id,auth.uid(),p_method,case when p_method='delivery' then p_zone end,v_quote->>'zone_name',nullif(trim(p_address),''),nullif(trim(p_phone),''),nullif(trim(p_note),''),
 (v_quote->>'delivery_fee')::numeric,(v_quote->>'subtotal')::numeric,(v_quote->>'discount')::numeric,(v_quote->>'total')::numeric);
 insert into public.customer_order_notifications(customer_id,order_id,status) values(auth.uid(),v_order.order_id,'new');
 return jsonb_build_object('order_id',v_order.order_id,'order_number',v_order.order_number,'total',v_quote->'total');
end; $function$;
