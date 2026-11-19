begin;
-- Server-only source resolution. No client-supplied prices, classifications or rates.
-- Preparation only: this endpoint does not issue invoices, move stock or earn commission.
create function private.quote_cashier_cart_reviewed(p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare validated jsonb;source jsonb;classification jsonb;operands jsonb:='[]';calculated jsonb;
 classifications jsonb:='{}';row_amount jsonb;outlines jsonb:='[]';workers jsonb;worker jsonb;base numeric;ordinal integer:=0;
begin
 -- Reuse current catalogue, quantity, branch, live-session, worker and discount authorization guards.
 -- Ignore every legacy quote amount, tax rule and commission estimate below.
 validated:=private.quote_cashier_cart(p_branch,p_items,p_discount_mode,p_discount_value);
 for source in select value from jsonb_array_elements(validated->'lines')loop
  classification:=private.resolve_owner_reviewed_tax(p_branch,(source->>'item_id')::uuid);
  if classification is null then raise exception 'Active owner-reviewed item tax classification required'using errcode='55000';end if;
  classifications:=classifications||jsonb_build_object(source->>'ordinal',classification);
  operands:=operands||jsonb_build_array(jsonb_build_object(
   'line_id',lpad(source->>'ordinal',10,'0'),'unit_price',source->'unit_price','quantity',source->'quantity',
   'tax_mode',classification->'tax_mode','tax_rate',classification->'rate_percent',
   'tax_status','verified','legal_basis',classification->'legal_basis',
   'max_discount_percent',100,'allow_invoice_discount',true,'allow_stacking',false));
 end loop;
 -- This endpoint accepts authorized manual invoice discounts only. No implicit offer/coupon stacking.
 calculated:=private.cashier_tax_amounts_core(operands,p_discount_mode,p_discount_value);
 for source in select value from jsonb_array_elements(validated->'lines')loop
  ordinal:=ordinal+1;
  select value into strict row_amount from jsonb_array_elements(calculated->'lines')where value->>'line_id'=lpad(source->>'ordinal',10,'0');
  classification:=classifications->(source->>'ordinal');
  base:=(row_amount->>'base_before_discount_exact')::numeric;
  workers:='[]';
  if source->>'item_type'='service'and private.active_staff_role()='owner'then
   for worker in select value from jsonb_array_elements(coalesce(source->'commission_estimate','[]'))loop
    workers:=workers||jsonb_build_array(jsonb_build_object('staff_id',worker->'staff_id','rate_percent',worker->'rate_percent',
     'estimated_amount',round(base*(worker->>'rate_percent')::numeric/100/jsonb_array_length(source->'staff_ids'),2)));
   end loop;
  end if;
  outlines:=outlines||jsonb_build_array((source-'commission_estimate'-'subtotal'-'tax_rate'-'tax_code'-'discount'-'net_before_tax'-'tax_amount'-'total')||row_amount||jsonb_build_object(
   'classification_id',classification->'classification_id','classification_version',classification->'classification_version',
   'review_id',classification->'review_id','eta_subtype',classification->'eta_subtype',
   'commission_basis_version','service_before_discount_excluding_tax_v1',
   'commission_basis_exact',case when source->>'item_type'='service'then base else 0 end,
   'commission_estimate',case when private.active_staff_role()='owner'then workers else null end));
 end loop;
 return (calculated-'lines')||jsonb_build_object('kind','cashier_cart_reviewed_quote_v2','branch_id',p_branch,
  'as_of',clock_timestamp(),'lines',outlines,'staff_configuration_complete',validated->'staff_configuration_complete',
  'commission_basis_version','service_before_discount_excluding_tax_v1','commission_requires_completed_service',true,
  'discount_source','authorized_manual_invoice_only','promotion_stacking_supported',false,
  'legally_verified_by_software',false,'eta_accepted',false,'can_issue',false,'quote_only',true,'earned_commission',false);
end$$;
create function public.quote_cashier_cart_reviewed(p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)
returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.quote_cashier_cart_reviewed(p_branch,p_items,p_discount_mode,p_discount_value)$$;
revoke all on function private.quote_cashier_cart_reviewed(uuid,jsonb,text,numeric),public.quote_cashier_cart_reviewed(uuid,jsonb,text,numeric)from public,anon,authenticated,service_role;
grant execute on function private.quote_cashier_cart_reviewed(uuid,jsonb,text,numeric),public.quote_cashier_cart_reviewed(uuid,jsonb,text,numeric)to authenticated;

-- Separate storage prevents old exclusive-only prototype readers from opening reviewed snapshots.
create table private.cashier_reviewed_drafts(
 draft_id uuid primary key,actor_id uuid not null references auth.users(id),branch_id uuid not null references public.business_branches(branch_id),
 version integer not null check(version>0),payload jsonb not null,quote jsonb not null,updated_at timestamptz not null default clock_timestamp());
create table private.cashier_reviewed_commands(request_id uuid primary key,actor_id uuid not null,payload jsonb not null,result jsonb not null);
alter table private.cashier_reviewed_drafts enable row level security;
alter table private.cashier_reviewed_commands enable row level security;
revoke all on private.cashier_reviewed_drafts,private.cashier_reviewed_commands from public,anon,authenticated,service_role;
create index cashier_reviewed_drafts_actor on private.cashier_reviewed_drafts(actor_id,updated_at desc,draft_id);
create function private.save_cashier_reviewed_draft(p_request uuid,p_draft uuid,p_expected_version integer,p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$
declare actor uuid;oldrow private.cashier_reviewed_drafts;prior private.cashier_reviewed_commands;payload jsonb;result jsonb;q jsonb;begin
 actor:=private.cashier_cart_actor(p_branch);
 if p_request is null or p_draft is null or p_expected_version is null or p_expected_version<0 then raise exception 'Exact draft and version required'using errcode='22023';end if;
 payload:=jsonb_build_object('draft',p_draft,'version',p_expected_version,'branch',p_branch,'items',p_items,'discount_mode',p_discount_mode,'discount_value',p_discount_value);
 perform pg_advisory_xact_lock(hashtextextended('cashier-reviewed-request:'||p_request,0));select *into prior from private.cashier_reviewed_commands where request_id=p_request;
 if found then if prior.actor_id<>actor then raise exception 'Request unavailable'using errcode='42501';end if;if prior.payload<>payload then raise exception 'Immutable request'using errcode='22023';end if;return prior.result;end if;
 perform pg_advisory_xact_lock(hashtextextended('cashier-reviewed-draft:'||p_draft,0));select *into oldrow from private.cashier_reviewed_drafts where draft_id=p_draft for update;
 if found and(oldrow.actor_id<>actor or oldrow.branch_id<>p_branch)then raise exception 'Draft unavailable'using errcode='42501';end if;
 if coalesce(oldrow.version,0)<>p_expected_version then raise exception 'Draft version conflict'using errcode='40001';end if;
 q:=private.quote_cashier_cart_reviewed(p_branch,p_items,p_discount_mode,p_discount_value);
 result:=jsonb_build_object('draft_id',p_draft,'version',p_expected_version+1,'quote',q);
 insert into private.cashier_reviewed_drafts values(p_draft,actor,p_branch,p_expected_version+1,payload,q,clock_timestamp())on conflict(draft_id)do update set version=excluded.version,payload=excluded.payload,quote=excluded.quote,updated_at=excluded.updated_at;
 insert into private.cashier_reviewed_commands values(p_request,actor,payload,result);
 insert into public.business_audit_log(actor,actor_id,action,entity,entity_id,branch_id,before_data,after_data)values(actor::text,actor,'cashier_reviewed_draft_saved','cashier_reviewed_draft',p_draft::text,p_branch,jsonb_build_object('version',coalesce(oldrow.version,0)),jsonb_build_object('version',p_expected_version+1,'quote_only',true));return result;end$$;
create function private.get_cashier_reviewed_draft(p_branch uuid,p_draft uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare actor uuid;d private.cashier_reviewed_drafts;begin
 actor:=private.cashier_cart_actor(p_branch);
 select *into d from private.cashier_reviewed_drafts where actor_id=actor and branch_id=p_branch and(p_draft is null or draft_id=p_draft)order by updated_at desc,draft_id desc limit 1;
 if not found then return jsonb_build_object('state','absent');end if;
 return jsonb_build_object('state','draft','draft_id',d.draft_id,'version',d.version,'payload',d.payload,'quote',d.quote,'updated_at',d.updated_at,'quote_only',true,'can_issue',false);
end$$;
create function private.get_cashier_reviewed_context(p_branch uuid,p_search text,p_after uuid)returns jsonb language plpgsql volatile security definer set search_path=pg_catalog as $$declare result jsonb;begin
 result:=private.get_cashier_cart_context(p_branch,p_search,p_after);
 return(result-'tax_rules'-'tax_rules_version'-'price_basis')||jsonb_build_object('tax_classification_source','owner_reviewed_versioned','manual_tax_override',false,'quote_only',true,'can_issue',false);end$$;
create function public.save_cashier_reviewed_draft(p_request uuid,p_draft uuid,p_expected_version integer,p_branch uuid,p_items jsonb,p_discount_mode text,p_discount_value numeric)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.save_cashier_reviewed_draft(p_request,p_draft,p_expected_version,p_branch,p_items,p_discount_mode,p_discount_value)$$;
revoke all on function private.save_cashier_reviewed_draft(uuid,uuid,integer,uuid,jsonb,text,numeric)from public,anon,authenticated,service_role;
grant execute on function private.save_cashier_reviewed_draft(uuid,uuid,integer,uuid,jsonb,text,numeric)to authenticated;
revoke all on function public.save_cashier_reviewed_draft(uuid,uuid,integer,uuid,jsonb,text,numeric)from public,anon,authenticated,service_role;
grant execute on function public.save_cashier_reviewed_draft(uuid,uuid,integer,uuid,jsonb,text,numeric)to authenticated;
create function public.get_cashier_reviewed_draft(p_branch uuid,p_draft uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_reviewed_draft(p_branch,p_draft)$$;
revoke all on function private.get_cashier_reviewed_draft(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_reviewed_draft(uuid,uuid)to authenticated;
revoke all on function public.get_cashier_reviewed_draft(uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function public.get_cashier_reviewed_draft(uuid,uuid)to authenticated;
create function public.get_cashier_reviewed_context(p_branch uuid,p_search text default '',p_after uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_reviewed_context(p_branch,p_search,p_after)$$;
revoke all on function private.get_cashier_reviewed_context(uuid,text,uuid)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_reviewed_context(uuid,text,uuid)to authenticated;
revoke all on function public.get_cashier_reviewed_context(uuid,text,uuid)from public,anon,authenticated,service_role;
grant execute on function public.get_cashier_reviewed_context(uuid,text,uuid)to authenticated;

notify pgrst,'reload schema';
commit;
