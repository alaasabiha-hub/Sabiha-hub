begin;
create table private.customer_checkout_retries(
 request_id uuid primary key,customer_id uuid not null references public.customers(id),payload jsonb not null,
 state text not null default 'open' check(state in ('open','succeeded','rejected')),
 created_at timestamptz not null default now(),resolved_at timestamptz,
 check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=32768));
create unique index customer_one_open_checkout_retry on private.customer_checkout_retries(customer_id) where state='open';
alter table private.customer_checkout_retries enable row level security;
revoke all on private.customer_checkout_retries from public,anon,authenticated,service_role;
create function private.get_checkout_retry(p_request uuid default null) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.customer_checkout_retries%rowtype;o public.business_orders%rowtype;begin
 if auth.uid() is null then raise exception 'Customer authentication required' using errcode='42501';end if;
 if p_request is null then select * into d from private.customer_checkout_retries where customer_id=auth.uid() and state='open';
 else select * into d from private.customer_checkout_retries where request_id=p_request;
  if found and d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
 end if;
 if d.request_id is null then return jsonb_build_object('state','absent');end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||d.request_id::text,0));
 select * into o from public.business_orders where customer_id=auth.uid() and customer_request_id=d.request_id;
 if found then
  update private.customer_checkout_retries set state='succeeded',resolved_at=coalesce(resolved_at,now()) where request_id=d.request_id;
  return jsonb_build_object('state','succeeded','request_id',d.request_id,'order',jsonb_build_object('order_id',o.order_id,'order_number',o.order_number,'total',(select total from public.business_invoices where order_id=o.order_id limit 1)));
 end if;
 return jsonb_build_object('state',d.state,'request_id',d.request_id,'payload',case when d.state='open' then d.payload end,'branch_id',(select branch_id from public.business_catalog_items where item_id::text=d.payload->'p_items'->0->>'item_id'));
end;$$;
create function private.prepare_checkout_retry(p_request uuid,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.customer_checkout_retries%rowtype;begin
 if auth.uid() is null or not exists(select 1 from public.customers where id=auth.uid()) then raise exception 'Customer authentication required' using errcode='42501';end if;
 if p_request is null or p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>32768 or p_payload->>'p_request_id' is distinct from p_request::text
 or jsonb_typeof(p_payload->'p_items') is distinct from 'array' or jsonb_array_length(p_payload->'p_items') not between 1 and 50
 or p_payload->>'p_method' not in ('pickup','delivery') or (select count(*) from jsonb_object_keys(p_payload))<>9
 or not p_payload ?& array['p_items','p_request_id','p_method','p_zone','p_address','p_phone','p_note','p_coupon','p_expected_total'] then raise exception 'Invalid checkout draft' using errcode='22023';end if;
 perform 1 from public.customers where id=auth.uid() for update;
 select * into d from private.customer_checkout_retries where request_id=p_request;
 if found then
  if d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
  if d.payload<>p_payload then raise exception 'Checkout payload mismatch' using errcode='22023';end if;
 else
  if exists(select 1 from private.customer_checkout_retries where customer_id=auth.uid() and state='open') then raise exception 'Resolve previous checkout first' using errcode='55000';end if;
  insert into private.customer_checkout_retries(request_id,customer_id,payload) values(p_request,auth.uid(),p_payload);
 end if;
 return private.get_checkout_retry(p_request);
end;$$;
create function private.reject_checkout_retry(p_request uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare d private.customer_checkout_retries%rowtype;result jsonb;begin
 if auth.uid() is null then raise exception 'Customer authentication required' using errcode='42501';end if;
 select * into d from private.customer_checkout_retries where request_id=p_request;
 if not found or d.customer_id<>auth.uid() then raise exception 'Checkout access denied' using errcode='42501';end if;
 -- The same lock as place_product_fulfillment waits for any in-flight transaction.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request::text,0));
 result:=private.get_checkout_retry(p_request);
 if result->>'state'='succeeded' then return result;end if;
 update private.customer_checkout_retries set state='rejected',resolved_at=coalesce(resolved_at,now()) where request_id=p_request;
 return jsonb_build_object('state','rejected','request_id',p_request);
end;$$;
create function public.get_checkout_retry(p_request uuid default null) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_checkout_retry(p_request);$$;
create function public.prepare_checkout_retry(p_request uuid,p_payload jsonb) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.prepare_checkout_retry(p_request,p_payload);$$;
create function public.reject_checkout_retry(p_request uuid) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.reject_checkout_retry(p_request);$$;
revoke all on function private.get_checkout_retry(uuid),public.get_checkout_retry(uuid),private.prepare_checkout_retry(uuid,jsonb),public.prepare_checkout_retry(uuid,jsonb),private.reject_checkout_retry(uuid),public.reject_checkout_retry(uuid) from public,anon;
grant execute on function private.get_checkout_retry(uuid),public.get_checkout_retry(uuid),private.prepare_checkout_retry(uuid,jsonb),public.prepare_checkout_retry(uuid,jsonb),private.reject_checkout_retry(uuid),public.reject_checkout_retry(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
