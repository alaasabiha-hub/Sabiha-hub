-- Additive purchasing ledger. Prepared locally; no historical inventory is rewritten.
create function private.can_inventory_branch(p_branch uuid) returns boolean language sql stable security definer set search_path=pg_catalog as $$
 select private.active_staff_role()='owner' or (private.active_staff_role()='manager' and private.can_access_branch(p_branch) and exists(select 1 from public.staff_profiles where user_id=auth.uid() and is_active and permissions->>'inventory'='true'));
$$;
revoke all on function private.can_inventory_branch(uuid) from public,anon;grant execute on function private.can_inventory_branch(uuid) to authenticated;
create table public.business_suppliers(
 supplier_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),name text not null check(length(trim(name)) between 2 and 120),phone text not null default '' check(length(phone)<=60),tax_reference text not null default '' check(length(tax_reference)<=100),is_active boolean not null default true,created_by uuid not null,created_at timestamptz not null default now()
);
create unique index suppliers_branch_name_unique on public.business_suppliers(branch_id,lower(name));
create table public.business_purchase_orders(
 purchase_id uuid primary key,branch_id uuid not null references public.business_branches(branch_id),supplier_id uuid not null references public.business_suppliers(supplier_id),invoice_reference text not null default '' check(length(invoice_reference)<=120),status text not null default 'draft' check(status in ('draft','received','cancelled')),total_cost numeric(18,2) not null check(total_cost>=0),request_payload jsonb not null,created_by uuid not null,created_at timestamptz not null default now(),received_at timestamptz,cancel_request uuid unique,cancelled_at timestamptz,cancel_reason text
);
create unique index supplier_invoice_unique on public.business_purchase_orders(supplier_id,lower(invoice_reference)) where invoice_reference<>'' and status<>'cancelled';
create index purchase_branch_created on public.business_purchase_orders(branch_id,created_at desc);
create table public.business_purchase_lines(
 purchase_id uuid not null references public.business_purchase_orders(purchase_id),item_id uuid not null references public.business_catalog_items(item_id),item_name text not null,quantity integer not null check(quantity between 1 and 100000),unit_cost numeric(12,2) not null check(unit_cost>=0),primary key(purchase_id,item_id)
);
create table public.business_inventory_receipts(
 receipt_id uuid primary key,purchase_id uuid not null unique references public.business_purchase_orders(purchase_id),branch_id uuid not null references public.business_branches(branch_id),received_by uuid not null,received_at timestamptz not null default now()
);
create table public.business_inventory_movements(
 movement_id uuid primary key default gen_random_uuid(),request_id uuid not null,branch_id uuid not null references public.business_branches(branch_id),item_id uuid not null references public.business_catalog_items(item_id),event_type text not null check(event_type in ('count','purchase_receipt')),before_quantity integer,after_quantity integer not null check(after_quantity>=0),purchase_id uuid references public.business_purchase_orders(purchase_id),reason text not null,actor_id uuid not null,created_at timestamptz not null default now(),unique(request_id,item_id)
);
create unique index one_stock_count_request on public.business_inventory_movements(request_id) where event_type='count';
create index inventory_movement_branch_created on public.business_inventory_movements(branch_id,created_at desc);
do $$declare tab text;begin
 foreach tab in array array['business_suppliers','business_purchase_orders','business_purchase_lines','business_inventory_receipts','business_inventory_movements'] loop
  execute format('alter table public.%I enable row level security',tab);
  execute format('revoke all on public.%I from public,anon,authenticated',tab);
  execute format('grant select on public.%I to authenticated',tab);
  execute format('grant all on public.%I to service_role',tab);
  if tab='business_purchase_lines' then execute 'create policy "Scoped inventory reads" on public.business_purchase_lines for select to authenticated using(exists(select 1 from public.business_purchase_orders p where p.purchase_id=business_purchase_lines.purchase_id))';
  else execute format('create policy "Scoped inventory reads" on public.%I for select to authenticated using((select private.can_inventory_branch(branch_id)))',tab);end if;
 end loop;
end$$;
create function private.save_inventory_supplier(p_request uuid,p_branch uuid,p_name text,p_phone text,p_tax text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare old public.business_suppliers%rowtype;begin
 if auth.uid() is null or not coalesce(private.can_inventory_branch(p_branch),false) then raise exception 'Inventory branch access required' using errcode='42501';end if;
 if p_request is null or p_name is null or length(trim(p_name)) not between 2 and 120 or length(coalesce(p_phone,''))>60 or length(coalesce(p_tax,''))>100 then raise exception 'Invalid supplier';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into old from public.business_suppliers where supplier_id=p_request;
 if found then if old.branch_id<>p_branch or old.name<>trim(p_name) or old.phone<>trim(coalesce(p_phone,'')) or old.tax_reference<>trim(coalesce(p_tax,'')) then raise exception 'Request already used for different supplier';end if;return old.supplier_id;end if;
 insert into public.business_suppliers(supplier_id,branch_id,name,phone,tax_reference,created_by) values(p_request,p_branch,trim(p_name),trim(coalesce(p_phone,'')),trim(coalesce(p_tax,'')),auth.uid());
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id) values(auth.uid()::text,auth.uid(),'create_supplier','business_suppliers',p_request::text,p_branch);return p_request;
end$$;
create function private.create_inventory_purchase(p_request uuid,p_branch uuid,p_supplier uuid,p_reference text,p_lines jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare line jsonb;item public.business_catalog_items%rowtype;old public.business_purchase_orders%rowtype;quantity numeric;cost numeric;total numeric:=0;normalized jsonb;payload jsonb;
begin
 if auth.uid() is null or not coalesce(private.can_inventory_branch(p_branch),false) then raise exception 'Inventory branch access required' using errcode='42501';end if;
 if p_request is null or p_reference is null or length(trim(p_reference)) not between 1 and 120 or jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Invalid purchase request';end if;
 if jsonb_array_length(p_lines) not between 1 and 50 then raise exception 'Choose 1 to 50 purchase lines';end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x group by x->>'item_id' having count(*)>1) then raise exception 'Duplicate product lines';end if;
 for line in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(line) is distinct from 'object' or jsonb_typeof(line->'quantity') is distinct from 'number' or jsonb_typeof(line->'unit_cost') is distinct from 'number' then raise exception 'Numeric quantity and unit cost required';end if;
  quantity:=(line->>'quantity')::numeric;cost:=(line->>'unit_cost')::numeric;
  if quantity<>trunc(quantity) or quantity not between 1 and 100000 or cost not between 0 and 99999999.99 or cost<>round(cost,2) then raise exception 'Invalid quantity or unit cost';end if;
  total:=total+quantity*cost;
 end loop;
 select jsonb_agg(jsonb_build_object('item_id',(x->>'item_id')::uuid,'quantity',(x->>'quantity')::int,'unit_cost',(x->>'unit_cost')::numeric) order by (x->>'item_id')::uuid) into normalized from jsonb_array_elements(p_lines) x;
 payload:=jsonb_build_object('branch',p_branch,'supplier',p_supplier,'reference',trim(p_reference),'lines',normalized);
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));select * into old from public.business_purchase_orders where purchase_id=p_request;
 if found then if old.request_payload<>payload then raise exception 'Request already used for different purchase';end if;return old.purchase_id;end if;
 if not exists(select 1 from public.business_suppliers where supplier_id=p_supplier and branch_id=p_branch and is_active) then raise exception 'Active supplier in the same branch required';end if;
 -- Lock products in stable order. Draft creation never changes stock.
 for line in select value from jsonb_array_elements(normalized) loop
  select * into item from public.business_catalog_items where item_id=(line->>'item_id')::uuid for share;
  if not found or item.branch_id<>p_branch or item.item_type<>'product' or not item.is_active or item.stock_quantity is null then raise exception 'Active counted product in the same branch required';end if;
 end loop;
 insert into public.business_purchase_orders(purchase_id,branch_id,supplier_id,invoice_reference,total_cost,request_payload,created_by) values(p_request,p_branch,p_supplier,trim(p_reference),total,payload,auth.uid());
 for line in select value from jsonb_array_elements(normalized) loop
  insert into public.business_purchase_lines(purchase_id,item_id,item_name,quantity,unit_cost) select p_request,item_id,name,(line->>'quantity')::int,(line->>'unit_cost')::numeric from public.business_catalog_items where item_id=(line->>'item_id')::uuid;
 end loop;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'create_purchase','business_purchase_orders',p_request::text,p_branch,jsonb_build_object('total_cost_egp',total));return p_request;
end$$;
create function private.receive_inventory_purchase(p_request uuid,p_purchase uuid) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare purchase public.business_purchase_orders%rowtype;receipt public.business_inventory_receipts%rowtype;line record;before_q integer;after_q integer;
begin
 if auth.uid() is null or p_request is null then raise exception 'Authenticated receipt request required' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into purchase from public.business_purchase_orders where purchase_id=p_purchase for update;
 if not found or not coalesce(private.can_inventory_branch(purchase.branch_id),false) then raise exception 'Inventory branch access required' using errcode='42501';end if;
 select * into receipt from public.business_inventory_receipts where receipt_id=p_request;
 if found and receipt.purchase_id<>p_purchase then raise exception 'Receipt request used for another purchase';end if;
 select * into receipt from public.business_inventory_receipts where purchase_id=p_purchase;
 if found then return receipt.receipt_id;end if;
 if purchase.status<>'draft' then raise exception 'Draft purchase required';end if;
 insert into public.business_inventory_receipts(receipt_id,purchase_id,branch_id,received_by) values(p_request,p_purchase,purchase.branch_id,auth.uid());
 for line in select * from public.business_purchase_lines where purchase_id=p_purchase order by item_id loop
  select stock_quantity into before_q from public.business_catalog_items where item_id=line.item_id and branch_id=purchase.branch_id and item_type='product' for update;
  if not found or before_q is null then raise exception 'Counted product required before receipt';end if;
  after_q:=before_q+line.quantity;
  update public.business_catalog_items set stock_quantity=after_q,updated_at=now() where item_id=line.item_id;
  insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,purchase_id,reason,actor_id) values(p_request,purchase.branch_id,line.item_id,'purchase_receipt',before_q,after_q,p_purchase,'Purchase receipt',auth.uid());
 end loop;
 update public.business_purchase_orders set status='received',received_at=now() where purchase_id=p_purchase;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,after_data) values(auth.uid()::text,auth.uid(),'receive_purchase','business_purchase_orders',p_purchase::text,purchase.branch_id,jsonb_build_object('receipt',p_request));return p_request;
end$$;
create function private.count_inventory_stock(p_request uuid,p_item uuid,p_count integer,p_reason text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare item public.business_catalog_items%rowtype;old public.business_inventory_movements%rowtype;result uuid;
begin
 if auth.uid() is null or p_request is null or p_count is null or p_count not between 0 and 10000000 or p_reason is null or length(trim(p_reason)) not between 5 and 300 then raise exception 'Valid counted stock and reason required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));select * into item from public.business_catalog_items where item_id=p_item for update;
 if not found or item.item_type<>'product' or not coalesce(private.can_inventory_branch(item.branch_id),false) then raise exception 'Inventory branch access required' using errcode='42501';end if;
 select * into old from public.business_inventory_movements where request_id=p_request and event_type='count';
 if found then if old.item_id<>p_item or old.after_quantity<>p_count or old.reason<>trim(p_reason) then raise exception 'Count request already used';end if;return old.movement_id;end if;
 update public.business_catalog_items set stock_quantity=p_count,updated_at=now() where item_id=p_item;
 insert into public.business_inventory_movements(request_id,branch_id,item_id,event_type,before_quantity,after_quantity,reason,actor_id) values(p_request,item.branch_id,p_item,'count',item.stock_quantity,p_count,trim(p_reason),auth.uid()) returning movement_id into result;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data,reason) values(auth.uid()::text,auth.uid(),'inventory_count','business_catalog_items',p_item::text,item.branch_id,jsonb_build_object('quantity',item.stock_quantity),jsonb_build_object('quantity',p_count),trim(p_reason));return result;
end$$;
create function private.inventory_context(p_branch uuid) returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare selected uuid;branches jsonb;products jsonb;suppliers jsonb;purchases jsonb;movements jsonb;
begin
 if auth.uid() is null then raise exception 'Inventory access required' using errcode='42501';end if;
 select branch_id into selected from public.business_branches where private.can_inventory_branch(branch_id) and (p_branch is null or branch_id=p_branch) order by is_default desc,name_ar limit 1;
 if selected is null then raise exception 'Inventory branch access required' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('branch_id',branch_id,'name_ar',name_ar,'name_en',name_en) order by is_default desc,name_ar),'[]') into branches from public.business_branches where private.can_inventory_branch(branch_id);
 select coalesce(jsonb_agg(jsonb_build_object('item_id',item_id,'name',name,'stock_quantity',stock_quantity,'is_active',is_active) order by name),'[]') into products from public.business_catalog_items where branch_id=selected and item_type='product';
 select coalesce(jsonb_agg(jsonb_build_object('supplier_id',supplier_id,'name',name,'phone',phone,'tax_reference',tax_reference,'is_active',is_active) order by name),'[]') into suppliers from public.business_suppliers where branch_id=selected;
 select coalesce(jsonb_agg(to_jsonb(p) order by created_at desc),'[]') into purchases from(select p.purchase_id,p.invoice_reference,p.status,p.total_cost,p.created_at,p.received_at,p.cancelled_at,p.cancel_reason,s.name supplier_name,(select jsonb_agg(jsonb_build_object('name',item_name,'quantity',quantity,'unit_cost',unit_cost) order by item_name) from public.business_purchase_lines l where l.purchase_id=p.purchase_id) lines from public.business_purchase_orders p join public.business_suppliers s using(supplier_id) where p.branch_id=selected order by p.created_at desc limit 100) p;
 select coalesce(jsonb_agg(to_jsonb(m) order by created_at desc),'[]') into movements from(select m.movement_id,m.event_type,m.before_quantity,m.after_quantity,m.reason,m.created_at,c.name from public.business_inventory_movements m join public.business_catalog_items c using(item_id) where m.branch_id=selected order by m.created_at desc limit 100) m;
 return jsonb_build_object('branch_id',selected,'branches',branches,'products',products,'suppliers',suppliers,'purchases',purchases,'movements',movements,'history_limit',100,'currency','EGP');
end$$;
create function private.cancel_inventory_purchase(p_request uuid,p_purchase uuid,p_reason text) returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare purchase public.business_purchase_orders%rowtype;begin
 if auth.uid() is null or p_request is null then raise exception 'Authenticated cancellation required' using errcode='42501';end if;
 if p_reason is null or length(trim(p_reason)) not between 5 and 300 then raise exception 'Cancellation reason required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));select * into purchase from public.business_purchase_orders where purchase_id=p_purchase for update;
 if not found or not coalesce(private.can_inventory_branch(purchase.branch_id),false) then raise exception 'Inventory branch access required' using errcode='42501';end if;
 if exists(select 1 from public.business_purchase_orders where cancel_request=p_request and purchase_id<>p_purchase) then raise exception 'Cancellation request already used';end if;
 if purchase.status='cancelled' then return p_purchase;end if;
 if purchase.status<>'draft' then raise exception 'Received purchase cannot be cancelled';end if;
 update public.business_purchase_orders set status='cancelled',cancel_request=p_request,cancelled_at=now(),cancel_reason=trim(p_reason) where purchase_id=p_purchase;
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason) values(auth.uid()::text,auth.uid(),'cancel_purchase','business_purchase_orders',p_purchase::text,purchase.branch_id,trim(p_reason));return p_purchase;
end$$;
create function public.cancel_inventory_purchase(p_request uuid,p_purchase uuid,p_reason text) returns uuid language sql security invoker set search_path=pg_catalog as $$select private.cancel_inventory_purchase(p_request,p_purchase,p_reason);$$;
revoke all on function private.cancel_inventory_purchase(uuid,uuid,text),public.cancel_inventory_purchase(uuid,uuid,text) from public,anon;
grant execute on function private.cancel_inventory_purchase(uuid,uuid,text),public.cancel_inventory_purchase(uuid,uuid,text) to authenticated;

-- Public wrappers are invokers; implementations remain in the non-exposed private schema.
create function public.save_inventory_supplier(p_request uuid,p_branch uuid,p_name text,p_phone text default '',p_tax text default '') returns uuid language sql security invoker set search_path=pg_catalog as $$select private.save_inventory_supplier(p_request,p_branch,p_name,p_phone,p_tax);$$;
create function public.create_inventory_purchase(p_request uuid,p_branch uuid,p_supplier uuid,p_reference text,p_lines jsonb) returns uuid language sql security invoker set search_path=pg_catalog as $$select private.create_inventory_purchase(p_request,p_branch,p_supplier,p_reference,p_lines);$$;
create function public.receive_inventory_purchase(p_request uuid,p_purchase uuid) returns uuid language sql security invoker set search_path=pg_catalog as $$select private.receive_inventory_purchase(p_request,p_purchase);$$;
create function public.count_inventory_stock(p_request uuid,p_item uuid,p_count integer,p_reason text) returns uuid language sql security invoker set search_path=pg_catalog as $$select private.count_inventory_stock(p_request,p_item,p_count,p_reason);$$;
create function public.get_inventory_context(p_branch uuid default null) returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select private.inventory_context(p_branch);$$;
revoke all on function private.save_inventory_supplier(uuid,uuid,text,text,text),private.create_inventory_purchase(uuid,uuid,uuid,text,jsonb),private.receive_inventory_purchase(uuid,uuid),private.count_inventory_stock(uuid,uuid,integer,text),private.inventory_context(uuid),public.save_inventory_supplier(uuid,uuid,text,text,text),public.create_inventory_purchase(uuid,uuid,uuid,text,jsonb),public.receive_inventory_purchase(uuid,uuid),public.count_inventory_stock(uuid,uuid,integer,text),public.get_inventory_context(uuid) from public,anon;
grant execute on function private.save_inventory_supplier(uuid,uuid,text,text,text),private.create_inventory_purchase(uuid,uuid,uuid,text,jsonb),private.receive_inventory_purchase(uuid,uuid),private.count_inventory_stock(uuid,uuid,integer,text),private.inventory_context(uuid),public.save_inventory_supplier(uuid,uuid,text,text,text),public.create_inventory_purchase(uuid,uuid,uuid,text,jsonb),public.receive_inventory_purchase(uuid,uuid),public.count_inventory_stock(uuid,uuid,integer,text),public.get_inventory_context(uuid) to authenticated;

notify pgrst,'reload schema';
