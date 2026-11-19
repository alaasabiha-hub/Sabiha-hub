begin;
create table public.business_payment_policies (
 version_id uuid primary key default gen_random_uuid(),branch_id uuid not null references public.business_branches(branch_id),
 method text not null check(method in ('cash','card')),created_at timestamptz not null default clock_timestamp(),created_by uuid not null references auth.users(id),
 gateway_percent numeric check(gateway_percent between 0 and 100),gateway_fixed numeric check(gateway_fixed between 0 and 100000),
 proposed_mode text not null default 'equal' check(proposed_mode in ('equal','percent','fixed','service')),
 proposed_value numeric not null default 0 check(proposed_value between 0 and 100000),service_prices jsonb not null default '{}' check(jsonb_typeof(service_prices)='object'),
 merchant_absorbs_fee boolean not null default true check(merchant_absorbs_fee),
 customer_surcharge_enabled boolean not null default false check(not customer_surcharge_enabled)
);
alter table public.business_payment_policies enable row level security;
revoke all on public.business_payment_policies from public,anon,authenticated;
grant select on public.business_payment_policies to authenticated;
create policy "Owner reads payment policies" on public.business_payment_policies for select to authenticated using((select private.active_staff_role())='owner');
create function private.get_payment_policy_context() returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare b uuid;begin
 if private.active_staff_role() is distinct from 'owner' then raise exception 'Active owner required' using errcode='42501';end if;
 select branch_id into b from public.business_branches where is_default and is_active;
 return jsonb_build_object('branch_id',b,'policies',coalesce((select jsonb_agg(to_jsonb(x)) from(select distinct on(method) * from public.business_payment_policies where branch_id=b order by method,created_at desc,version_id desc)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(to_jsonb(x)) from(select p.*,s.full_name owner_name from public.business_payment_policies p left join public.staff_profiles s on s.user_id=p.created_by where p.branch_id=b order by p.created_at desc limit 50)x),'[]'::jsonb),
 'services',coalesce((select jsonb_agg(jsonb_build_object('item_id',item_id,'name',name,'price',price)) from public.business_catalog_items where branch_id=b and item_type='service' and is_active),'[]'::jsonb),
 'surcharge_activation','blocked_pending_legal_network_and_acquirer_approval');
end;$$;
create function private.save_payment_policy(p_request uuid,p_method text,p_previous uuid,p_policy jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
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
create function private.payment_policy_snapshot(p_branch uuid,p_amount numeric) returns jsonb language sql stable security definer set search_path=pg_catalog as $$
 select jsonb_build_object('base_amount',p_amount,'currency','EGP','customer_fee',0,'cash_total',p_amount,'card_total',p_amount,'merchant_absorbs_fee',true,
 'versions',coalesce((select jsonb_object_agg(method,to_jsonb(x)) from(select distinct on(method) version_id,method,gateway_percent,gateway_fixed from public.business_payment_policies where branch_id=p_branch order by method,created_at desc,version_id desc)x),'{}'::jsonb));
$$;
revoke all on function private.payment_policy_snapshot(uuid,numeric) from public,anon,authenticated;
alter table public.business_invoices add column payment_policy_snapshot jsonb;
create function private.capture_invoice_payment_policy() returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_op='UPDATE' then if new.payment_policy_snapshot is distinct from old.payment_policy_snapshot then raise exception 'Invoice payment policy snapshot is immutable';end if;
 else new.payment_policy_snapshot:=private.payment_policy_snapshot(coalesce((select branch_id from public.business_orders where order_id=new.order_id),new.branch_id),new.total);end if;return new;end;$$;
revoke all on function private.capture_invoice_payment_policy() from public,anon,authenticated;
create trigger capture_invoice_payment_policy before insert or update of payment_policy_snapshot on public.business_invoices for each row execute function private.capture_invoice_payment_policy();
create function private.invoice_payment_quote(p_invoice text) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare i public.business_invoices%rowtype;begin
 if not coalesce(private.can_read_invoice(p_invoice),false) then raise exception 'Invoice access denied' using errcode='42501';end if;
 select * into strict i from public.business_invoices where invoice_id=p_invoice;
 return jsonb_build_object('invoice_id',i.invoice_id,'invoice_number',coalesce(i.display_number,i.invoice_id),'base_amount',i.total,'customer_fee',0,'cash_total',i.total,'card_total',i.total,'currency','EGP','policy',case when i.payment_policy_snapshot is null then null else jsonb_build_object('base_amount',i.total,'currency','EGP','customer_fee',0,'cash_total',i.total,'card_total',i.total,'merchant_absorbs_fee',true,'versions',coalesce((select jsonb_object_agg(key,jsonb_build_object('version_id',value->>'version_id')) from jsonb_each(i.payment_policy_snapshot->'versions')),'{}'::jsonb)) end,'live_enabled',false,'sandbox_only',true);
end;$$;
create function public.get_payment_policy_context() returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_payment_policy_context();$$;
create function public.save_payment_policy(p_request uuid,p_method text,p_previous uuid,p_policy jsonb) returns uuid language sql security invoker set search_path=pg_catalog as $$select private.save_payment_policy(p_request,p_method,p_previous,p_policy);$$;
create function public.invoice_payment_quote(p_invoice text) returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.invoice_payment_quote(p_invoice);$$;
revoke all on function private.get_payment_policy_context(),public.get_payment_policy_context(),private.save_payment_policy(uuid,text,uuid,jsonb),public.save_payment_policy(uuid,text,uuid,jsonb),private.invoice_payment_quote(text),public.invoice_payment_quote(text) from public,anon;
grant execute on function private.get_payment_policy_context(),public.get_payment_policy_context(),private.save_payment_policy(uuid,text,uuid,jsonb),public.save_payment_policy(uuid,text,uuid,jsonb),private.invoice_payment_quote(text),public.invoice_payment_quote(text) to authenticated;
notify pgrst,'reload schema';
commit;
