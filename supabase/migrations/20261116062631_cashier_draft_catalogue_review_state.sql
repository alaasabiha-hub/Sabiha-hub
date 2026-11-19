begin;
create function private.get_cashier_catalogue_review(p_branch uuid,p_draft uuid,p_version integer)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare actor uuid;d private.cashier_reviewed_drafts;current_quote jsonb;changes jsonb;different boolean;begin
 actor:=private.cashier_cart_actor(p_branch);select *into d from private.cashier_reviewed_drafts where draft_id=p_draft and branch_id=p_branch and actor_id=actor;
 if not found then raise exception 'Own draft required'using errcode='42501';end if;
 if d.version<>p_version then raise exception 'Draft version changed'using errcode='40001';end if;
 if exists(select 1 from private.cashier_invoice_postings where draft_id=p_draft)then return jsonb_build_object('needs_review',false,'issued_immutable',true,'changes','[]'::jsonb);end if;
 select coalesce(jsonb_agg(jsonb_build_object('item_id',v->>'item_id','name',v->>'name','name_en',v->>'name_en','previous_price',v->'unit_price','current_price',c.price,'active',coalesce(c.is_active,false))order by v->>'line_id'),'[]')into changes from jsonb_array_elements(d.quote->'lines')v left join public.business_catalog_items c on c.item_id=(v->>'item_id')::uuid and c.branch_id=p_branch where c.item_id is null or not c.is_active or c.price is distinct from(v->>'unit_price')::numeric;
 begin current_quote:=private.quote_cashier_cart_reviewed(p_branch,d.payload->'items',d.payload->>'discount_mode',(d.payload->>'discount_value')::numeric);different:=(current_quote-'as_of')is distinct from(d.quote-'as_of');
 exception when sqlstate'22023'or sqlstate'55000'then different:=true;end;
 return jsonb_build_object('needs_review',different or jsonb_array_length(changes)>0,'changes',changes,'version',d.version);
end$$;
create function public.get_cashier_catalogue_review(p_branch uuid,p_draft uuid,p_version integer)returns jsonb language sql security invoker set search_path=pg_catalog as $$select private.get_cashier_catalogue_review(p_branch,p_draft,p_version)$$;
revoke all on function private.get_cashier_catalogue_review(uuid,uuid,integer),public.get_cashier_catalogue_review(uuid,uuid,integer)from public,anon,authenticated,service_role;
grant execute on function private.get_cashier_catalogue_review(uuid,uuid,integer),public.get_cashier_catalogue_review(uuid,uuid,integer)to authenticated;
CREATE OR REPLACE FUNCTION private.get_cashier_reviewed_context(p_branch uuid, p_search text, p_after uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;spec jsonb;items jsonb;categories jsonb;begin
 result:=private.get_cashier_cart_context(p_branch,p_search,p_after);
 select x.spec into spec from private.owner_pos_catalog_layouts x where branch_id=p_branch order by version desc limit 1;
 select coalesce(jsonb_agg(x order by(x->>'sort_order')::numeric,x->>'category_id'),'[]')into categories from jsonb_array_elements(coalesce(spec->'categories','[]'))x where x->'enabled'='true'::jsonb;
 select coalesce(jsonb_agg(item||jsonb_build_object('pos_category_id',case when exists(select 1 from jsonb_array_elements(categories)c where c->>'category_id'=layout->>'category_id')then layout->'category_id'else'null'::jsonb end,'pos_sort_order',coalesce(layout->'sort_order','0'::jsonb),'pos_featured',coalesce(layout->'featured','false'::jsonb))order by item->>'item_id'),'[]')into items from jsonb_array_elements(result->'items')item left join lateral(select x from jsonb_array_elements(coalesce(spec->'items','[]'))x where x->>'item_id'=item->>'item_id')q(layout)on true;
 return(result-'tax_rules'-'tax_rules_version'-'price_basis')||jsonb_build_object('items',items,'pos_categories',categories,'pos_layout_version',coalesce((select version from private.owner_pos_catalog_layouts where branch_id=p_branch order by version desc limit 1),0),'catalogue_review_supported',true,'tax_classification_source','owner_reviewed_versioned','manual_tax_override',false,'quote_only',true,'can_issue',false);end$function$;
notify pgrst,'reload schema';commit;
