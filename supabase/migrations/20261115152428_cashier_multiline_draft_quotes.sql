begin;
-- Preparation only: never creates an invoice, payment, stock movement or earning.
create table private.cashier_tax_rules(
 branch_id uuid primary key references public.business_branches(branch_id),version integer not null check(version>0),
 rules jsonb not null,reason text not null,actor_id uuid not null references auth.users(id),updated_at timestamptz not null default clock_timestamp());
create table private.cashier_tax_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null);
create table private.cashier_cart_drafts(
 draft_id uuid primary key,actor_id uuid not null references auth.users(id),branch_id uuid not null references public.business_branches(branch_id),
 version integer not null check(version>0),payload jsonb not null,quote jsonb not null,updated_at timestamptz not null default clock_timestamp());
create table private.cashier_cart_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null);
do $$declare t text;begin foreach t in array array['cashier_tax_rules','cashier_tax_commands','cashier_cart_drafts','cashier_cart_commands']loop
 execute format('alter table private.%I enable row level security',t);execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);end loop;end$$;
create index cashier_cart_drafts_actor on private.cashier_cart_drafts(actor_id,updated_at desc,draft_id);
create function private.cashier_cart_actor(p_branch uuid)returns uuid language plpgsql volatile security definer set search_path=pg_catalog as $$begin
 if not coalesce(private.has_live_invoice_session(),false)or not coalesce(private.can_cashier_branch(p_branch),false)then raise exception 'Current authorized cashier session required'using errcode='42501';end if;
 if not exists(select 1 from public.business_branches where branch_id=p_branch and is_active)then raise exception 'Active branch required'using errcode='22023';end if;return auth.uid();end$$;
create function private.save_cashier_tax_rules(p_request uuid,p_branch uuid,p_expected_version integer,p_rules jsonb,p_reason text)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;oldrow private.cashier_tax_rules;prior private.cashier_tax_commands;entry jsonb;payload jsonb;result jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if private.active_staff_role()is distinct from'owner'then raise exception 'Owner required'using errcode='42501';end if;
 if p_request is null or p_expected_version is null or p_expected_version<0 or jsonb_typeof(p_rules)is distinct from'array'or octet_length(p_rules::text)>1048576 or length(trim(coalesce(p_reason,'')))not between 5 and 500 then raise exception 'Explicit version, tax rules and reason required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_rules)loop
 if jsonb_typeof(entry)is distinct from'object'or (select count(*)from jsonb_object_keys(entry))<>3 or not(entry?&array['item_id','rate_percent','code'])or jsonb_typeof(entry->'rate_percent')is distinct from'number'or (entry->>'rate_percent')::numeric not between 0 and 100 or round((entry->>'rate_percent')::numeric,4)<>(entry->>'rate_percent')::numeric or jsonb_typeof(entry->'code')is distinct from'string'or length(trim(coalesce(entry->>'code','')))not between 1 and 50 or not exists(select 1 from public.business_catalog_items where item_id=(entry->>'item_id')::uuid and branch_id=p_branch)then raise exception 'Actual item and explicit exclusive tax rate/code required'using errcode='22023';end if;end loop;
 if(select count(*)from jsonb_array_elements(p_rules))<>(select count(distinct (value->>'item_id')::uuid)from jsonb_array_elements(p_rules))then raise exception 'Duplicate tax item'using errcode='22023';end if;
 payload:=jsonb_build_object('branch',p_branch,'expected_version',p_expected_version,'rules',p_rules,'reason',trim(p_reason));
 perform pg_advisory_xact_lock(hashtextextended('cashier-tax-request:'||p_request,0));select *into prior from private.cashier_tax_commands where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable request'using errcode='22023';end if;return prior.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('cashier-tax-branch:'||p_branch,0));select *into oldrow from private.cashier_tax_rules where branch_id=p_branch for update;
 if coalesce(oldrow.version,0)<>p_expected_version then raise exception 'Tax version conflict'using errcode='40001';end if;
 insert into private.cashier_tax_rules values(p_branch,p_expected_version+1,p_rules,trim(p_reason),actor,clock_timestamp())on conflict(branch_id)do update set version=excluded.version,rules=excluded.rules,reason=excluded.reason,actor_id=excluded.actor_id,updated_at=excluded.updated_at;
 result:=jsonb_build_object('version',p_expected_version+1,'branch_id',p_branch,'price_basis','exclusive','rules',p_rules);
 insert into private.cashier_tax_commands values(p_request,actor,payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,reason,before_data,after_data)values(actor::text,actor,'cashier_tax_rules_saved','cashier_tax_rules',p_branch::text,p_branch,trim(p_reason),to_jsonb(oldrow),result);return result;end$$;
create function private.quote_cashier_cart(p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;item jsonb;ci public.business_catalog_items;rules private.cashier_tax_rules;tax jsonb;prepared jsonb:='[]';subtotal numeric:=0;discount numeric;line_gross numeric;staff uuid[];sid uuid;rate numeric;comm numeric;workers jsonb;v_ordinal integer:=0;missing integer:=0;staff_missing boolean:=false;outlines jsonb;tax_total numeric;result jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if jsonb_typeof(p_items)is distinct from'array'or jsonb_array_length(p_items)=0 or octet_length(p_items::text)>2097152 or p_discount_mode is null or p_discount_mode not in('fixed','percentage')or p_discount_value is null or p_discount_value::text in('NaN','Infinity','-Infinity')or p_discount_value<0 or round(p_discount_value,2)<>p_discount_value or(p_discount_mode='percentage'and p_discount_value>100)then raise exception 'Valid items and explicit discount required'using errcode='22023';end if;
 if p_discount_value>0 and private.active_staff_role()not in('owner','manager')and not exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'invoice_discount'='true')then raise exception 'Discount authorization required'using errcode='42501';end if;
 select *into rules from private.cashier_tax_rules where branch_id=p_branch;
 for item in select value from jsonb_array_elements(p_items)loop
 v_ordinal:=v_ordinal+1;
 if jsonb_typeof(item)is distinct from'object'or not(item?&array['item_id','quantity','staff_ids'])or(select count(*)from jsonb_object_keys(item))<>3 or jsonb_typeof(item->'quantity')is distinct from'number'or(item->>'quantity')!~'^[1-9][0-9]{0,8}$'or jsonb_typeof(item->'staff_ids')is distinct from'array'then raise exception 'Item identity, integer quantity and staff only; client prices are forbidden'using errcode='22023';end if;
 select *into ci from public.business_catalog_items where item_id=(item->>'item_id')::uuid and branch_id=p_branch and is_active;
 if not found or ci.price::text in('NaN','Infinity','-Infinity')or ci.price<0 then raise exception 'Current catalogue item unavailable'using errcode='22023';end if;
 select coalesce(array_agg(value::uuid order by value::uuid),'{}')into staff from jsonb_array_elements_text(item->'staff_ids');
 if cardinality(staff)<>(select count(distinct x)from unnest(staff)x)or(ci.item_type='product'and cardinality(staff)>0)then raise exception 'Distinct service workers only'using errcode='22023';end if;
 if ci.item_type='service'and cardinality(staff)=0 then staff_missing:=true;end if;
 workers:='[]';line_gross:=ci.price*(item->>'quantity')::integer;
 for sid in select unnest(staff)loop
 select e.commission_percent into rate from private.hr_employment e join public.staff_profiles s on s.user_id=e.staff_id where e.staff_id=sid and s.is_active and e.currency='EGP'and e.starts_on<=current_date and(e.ends_on is null or e.ends_on>=current_date)and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=sid and a.branch_id=p_branch));
 if not found then raise exception 'Actual active worker and EGP commission rule required'using errcode='22023';end if;
 comm:=round(line_gross*rate/100/cardinality(staff),2);workers:=workers||jsonb_build_array(jsonb_build_object('staff_id',sid,'rate_percent',rate,'estimated_amount',comm));end loop;
 select value into tax from jsonb_array_elements(coalesce(rules.rules,'[]'))where(value->>'item_id')::uuid=ci.item_id;
 if tax is null then missing:=missing+1;end if;
 prepared:=prepared||jsonb_build_array(jsonb_build_object('ordinal',v_ordinal,'item_id',ci.item_id,'name',ci.name,'name_en',ci.name_en,'item_type',ci.item_type,'quantity',(item->>'quantity')::integer,'unit_price',ci.price,'subtotal',line_gross,'tax_rate',tax->'rate_percent','tax_code',tax->'code','staff_ids',to_jsonb(staff),'commission_estimate',case when private.active_staff_role()='owner'then workers else null end));subtotal:=subtotal+line_gross;
 end loop;
 if exists(select 1 from jsonb_array_elements(p_items)x join public.business_catalog_items c on c.item_id=(x->>'item_id')::uuid where c.item_type='product' group by c.item_id,c.stock_quantity having sum((x->>'quantity')::integer)>c.stock_quantity)then raise exception 'Insufficient actual stock'using errcode='55000';end if;
 discount:=case when p_discount_mode='percentage'then round(subtotal*p_discount_value/100,2)else p_discount_value end;
 if discount>subtotal then raise exception 'Discount exceeds subtotal'using errcode='22023';end if;
 with base as(select value j,(value->>'ordinal')::integer ordinal,(value->>'subtotal')::numeric gross from jsonb_array_elements(prepared)),shares as(select *,case when subtotal=0 then 0 else discount*100*gross/subtotal end exact_cents from base),ranked as(select *,floor(exact_cents)whole,row_number()over(order by exact_cents-floor(exact_cents)desc,ordinal)priority,sum(floor(exact_cents))over()allocated from shares),calculated as(select *, (whole+case when priority<=discount*100-allocated then 1 else 0 end)/100 line_discount from ranked),taxed as(select *,round((gross-line_discount)*(j->>'tax_rate')::numeric/100,2)line_tax from calculated)
 select jsonb_agg(j||jsonb_build_object('discount',line_discount,'net_before_tax',gross-line_discount,'tax_amount',line_tax,'total',case when line_tax is null then null else gross-line_discount+line_tax end)order by ordinal),sum(line_tax)into outlines,tax_total from taxed;
 result:=jsonb_build_object('kind','cashier_cart_quote_v1','branch_id',p_branch,'currency','EGP','as_of',clock_timestamp(),'price_basis','exclusive','subtotal',subtotal,'discount',discount,'tax_amount',case when missing=0 then tax_total else null end,'total',case when missing=0 then subtotal-discount+tax_total else null end,'tax_rules_version',coalesce(rules.version,0),'unconfigured_tax_items',missing,'staff_configuration_complete',not staff_missing,'lines',outlines,'quote_only',true,'can_issue',false,'earned_commission',false);
 return result;end$$;
create function private.save_cashier_cart_draft(p_request uuid,p_draft uuid,p_expected_version integer,p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;oldrow private.cashier_cart_drafts;prior private.cashier_cart_commands;payload jsonb;result jsonb;q jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_version is null or p_expected_version<0 then raise exception 'Exact draft and version required'using errcode='22023';end if;
 payload:=jsonb_build_object('draft',p_draft,'version',p_expected_version,'branch',p_branch,'items',p_items,'discount_mode',p_discount_mode,'discount_value',p_discount_value);
 perform pg_advisory_xact_lock(hashtextextended('cashier-cart-request:'||p_request,0));select *into prior from private.cashier_cart_commands where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable request'using errcode='22023';end if;return prior.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('cashier-cart-draft:'||p_draft,0));select *into oldrow from private.cashier_cart_drafts where draft_id=p_draft for update;
 if found and(oldrow.actor_id<>actor or oldrow.branch_id<>p_branch)then raise exception 'Draft unavailable'using errcode='42501';end if;
 if coalesce(oldrow.version,0)<>p_expected_version then raise exception 'Draft version conflict'using errcode='40001';end if;
 q:=private.quote_cashier_cart(p_branch,p_items,p_discount_mode,p_discount_value);
 result:=jsonb_build_object('draft_id',p_draft,'version',p_expected_version+1,'quote',q);
 insert into private.cashier_cart_drafts values(p_draft,actor,p_branch,p_expected_version+1,payload,q,clock_timestamp())on conflict(draft_id)do update set version=excluded.version,payload=excluded.payload,quote=excluded.quote,updated_at=excluded.updated_at;
 insert into private.cashier_cart_commands values(p_request,actor,payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'cashier_cart_draft_saved','cashier_cart_draft',p_draft::text,p_branch,jsonb_build_object('version',coalesce(oldrow.version,0)),jsonb_build_object('version',p_expected_version+1,'quote_only',true));return result;end$$;
create function public.quote_cashier_cart(p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.quote_cashier_cart(p_branch,p_items,p_discount_mode,p_discount_value)$$;
create function public.save_cashier_cart_draft(p_request uuid,p_draft uuid,p_expected_version integer,p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_cashier_cart_draft(p_request,p_draft,p_expected_version,p_branch,p_items,p_discount_mode,p_discount_value)$$;
create function public.save_cashier_tax_rules(p_request uuid,p_branch uuid,p_expected_version integer,p_rules jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_cashier_tax_rules(p_request,p_branch,p_expected_version,p_rules,p_reason)$$;
revoke all on function private.cashier_cart_actor(uuid),private.quote_cashier_cart(uuid,jsonb,text,numeric),private.save_cashier_cart_draft(uuid,uuid,integer,uuid,jsonb,text,numeric),private.save_cashier_tax_rules(uuid,uuid,integer,jsonb,text),public.quote_cashier_cart(uuid,jsonb,text,numeric),public.save_cashier_cart_draft(uuid,uuid,integer,uuid,jsonb,text,numeric),public.save_cashier_tax_rules(uuid,uuid,integer,jsonb,text)from public,anon,authenticated,service_role;
grant execute on function private.quote_cashier_cart(uuid,jsonb,text,numeric),private.save_cashier_cart_draft(uuid,uuid,integer,uuid,jsonb,text,numeric),private.save_cashier_tax_rules(uuid,uuid,integer,jsonb,text),public.quote_cashier_cart(uuid,jsonb,text,numeric),public.save_cashier_cart_draft(uuid,uuid,integer,uuid,jsonb,text,numeric),public.save_cashier_tax_rules(uuid,uuid,integer,jsonb,text)to authenticated;

create function private.get_cashier_cart_context(p_branch uuid,p_search text,p_after uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;items jsonb;staff jsonb;rules private.cashier_tax_rules;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_search is null or length(p_search)>120 then raise exception 'Valid search required'using errcode='22023';end if;
 select *into rules from private.cashier_tax_rules where branch_id=p_branch;
 select coalesce(jsonb_agg(to_jsonb(x)order by item_id),'[]')into items from(select item_id,item_type,name,name_en,price,stock_quantity from public.business_catalog_items where branch_id=p_branch and is_active and(p_after is null or item_id>p_after)and(name ilike'%'||p_search||'%'or name_en ilike'%'||p_search||'%')order by item_id limit 101)x;
 select coalesce(jsonb_agg(jsonb_build_object('staff_id',s.user_id,'name',s.full_name)order by s.full_name,s.user_id),'[]')into staff from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and e.currency='EGP'and e.starts_on<=current_date and(e.ends_on is null or e.ends_on>=current_date)and(s.role='owner'or exists(select 1 from public.staff_branch_access a where a.user_id=s.user_id and a.branch_id=p_branch));
 return jsonb_build_object('items',case when jsonb_array_length(items)>100 then items-100 else items end,'has_more',jsonb_array_length(items)>100,'staff',staff,'tax_rules',coalesce(rules.rules,'[]'),'tax_rules_version',coalesce(rules.version,0),'owner',private.active_staff_role()='owner','can_discount',private.active_staff_role()in('owner','manager')or exists(select 1 from public.staff_profiles where user_id=actor and is_active and permissions->>'invoice_discount'='true'),'price_basis','exclusive','quote_only',true,'can_issue',false);
end$$;
create function private.get_cashier_cart_draft(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;d private.cashier_cart_drafts;begin
 actor:=private.cashier_cart_actor(p_branch);
 select *into d from private.cashier_cart_drafts where actor_id=actor and branch_id=p_branch and(p_draft is null or draft_id=p_draft)order by updated_at desc,draft_id desc limit 1;
 if not found then return jsonb_build_object('state','absent');end if;
 return jsonb_build_object('state','draft','draft_id',d.draft_id,'version',d.version,'payload',d.payload,'quote',d.quote,'updated_at',d.updated_at,'quote_only',true,'can_issue',false);
end$$;
create function public.get_cashier_cart_context(p_branch uuid,p_search text default '',p_after uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_cart_context(p_branch,p_search,p_after)$$;
create function public.get_cashier_cart_draft(p_branch uuid,p_draft uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_cart_draft(p_branch,p_draft)$$;
revoke all on function private.get_cashier_cart_context(uuid,text,uuid),private.get_cashier_cart_draft(uuid,uuid),public.get_cashier_cart_context(uuid,text,uuid),public.get_cashier_cart_draft(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_cart_context(uuid,text,uuid),private.get_cashier_cart_draft(uuid,uuid),public.get_cashier_cart_context(uuid,text,uuid),public.get_cashier_cart_draft(uuid,uuid)to authenticated;

notify pgrst,'reload schema';
commit;
