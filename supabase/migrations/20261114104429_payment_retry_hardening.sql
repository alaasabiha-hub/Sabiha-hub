-- Retain document numbers on retries and bind policy retry requests to method and branch.
begin;
create or replace function private.assign_document_number() returns trigger language plpgsql security definer set search_path=pg_catalog as $$
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
create or replace function private.save_payment_policy(p_request uuid,p_method text,p_previous uuid,p_policy jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare b uuid;old public.business_payment_policies%rowtype;v uuid;item record;begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 if p_request is null or p_method is null or p_policy is null or p_method not in ('cash','card') or jsonb_typeof(p_policy)<>'object' or length(p_policy::text)>20000 then raise exception 'Invalid policy';end if;
 if coalesce((p_policy->>'customer_surcharge_enabled')::boolean,false) or not coalesce((p_policy->>'merchant_absorbs_fee')::boolean,true) then raise exception 'Customer surcharges are blocked pending independent approval' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_default and is_active;
 perform pg_advisory_xact_lock(hashtextextended('payment-policy:'||b::text||p_method,0));
 if exists(select 1 from public.business_payment_policies where version_id=p_request) then
  if exists(select 1 from public.business_payment_policies where version_id=p_request and branch_id=b and method=p_method) and exists(select 1 from public.business_audit_log where entity='business_payment_policies' and entity_id=p_request::text and actor_id=auth.uid() and after_data->'submitted'=p_policy) then return p_request;end if;
  raise exception 'Policy request mismatch';end if;
 select * into old from public.business_payment_policies where branch_id=b and method=p_method order by created_at desc,version_id desc limit 1;
 if old.version_id is distinct from p_previous then raise exception 'Policy changed; refresh' using errcode='40001';end if;
 for item in select key,value from jsonb_each(coalesce(p_policy->'service_prices','{}')) loop
  if jsonb_typeof(item.value)<>'number' or (item.value::text)::numeric<0 or round((item.value::text)::numeric,2)<>(item.value::text)::numeric or not exists(select 1 from public.business_catalog_items where item_id=item.key::uuid and branch_id=b and item_type='service') then raise exception 'Invalid service price';end if;
 end loop;
 insert into public.business_payment_policies(version_id,branch_id,method,created_by,gateway_percent,gateway_fixed,proposed_mode,proposed_value,service_prices)
 values(p_request,b,p_method,auth.uid(),nullif(p_policy->>'gateway_percent','')::numeric,nullif(p_policy->>'gateway_fixed','')::numeric,coalesce(p_policy->>'proposed_mode','equal'),coalesce((p_policy->>'proposed_value')::numeric,0),coalesce(p_policy->'service_prices','{}')) returning version_id into v;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data) values(auth.uid()::text,auth.uid(),'payment_policy_changed','business_payment_policies',v::text,b,to_jsonb(old),jsonb_build_object('submitted',p_policy,'saved',(select to_jsonb(p) from public.business_payment_policies p where version_id=v)));
 return v;
end;$$;
commit;
