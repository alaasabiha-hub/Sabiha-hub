begin;
-- Preserve UUID pagination and authoritative prices. Display sorting occurs only
-- after fetching a page; p_after must continue using the original UUID order.
create or replace function private.get_cashier_reviewed_context(p_branch uuid,p_search text,p_after uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb;spec jsonb;items jsonb;categories jsonb;begin
 result:=private.get_cashier_cart_context(p_branch,p_search,p_after);
 select x.spec into spec from private.owner_pos_catalog_layouts x where branch_id=p_branch order by version desc limit 1;
 select coalesce(jsonb_agg(x order by(x->>'sort_order')::numeric,x->>'category_id'),'[]')into categories from jsonb_array_elements(coalesce(spec->'categories','[]'))x where x->'enabled'='true'::jsonb;
 select coalesce(jsonb_agg(item||jsonb_build_object('pos_category_id',case when exists(select 1 from jsonb_array_elements(categories)c where c->>'category_id'=layout->>'category_id')then layout->'category_id'else'null'::jsonb end,'pos_sort_order',coalesce(layout->'sort_order','0'::jsonb),'pos_featured',coalesce(layout->'featured','false'::jsonb))order by item->>'item_id'),'[]')into items from jsonb_array_elements(result->'items')item left join lateral(select x from jsonb_array_elements(coalesce(spec->'items','[]'))x where x->>'item_id'=item->>'item_id')q(layout)on true;
 return(result-'tax_rules'-'tax_rules_version'-'price_basis')||jsonb_build_object('items',items,'pos_categories',categories,'pos_layout_version',coalesce((select version from private.owner_pos_catalog_layouts where branch_id=p_branch order by version desc limit 1),0),'tax_classification_source','owner_reviewed_versioned','manual_tax_override',false,'quote_only',true,'can_issue',false);end$$;
notify pgrst,'reload schema';commit;
