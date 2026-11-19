begin;
-- Resolve the owner's order before limiting a page, so a configured item is
-- not stranded on a later UUID page. The cursor remains the last returned UUID.
create or replace function private.get_cashier_reviewed_context(p_branch uuid,p_search text,p_after uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb;spec jsonb;items jsonb;categories jsonb;anchor_order numeric;begin
 result:=private.get_cashier_cart_context(p_branch,p_search,p_after);
 select x.spec into spec from private.owner_pos_catalog_layouts x where branch_id=p_branch order by version desc limit 1;
 select coalesce(jsonb_agg(x order by(x->>'sort_order')::numeric,x->>'category_id'),'[]')into categories from jsonb_array_elements(coalesce(spec->'categories','[]'))x where x->'enabled'='true'::jsonb;
 select coalesce((select(x->>'sort_order')::numeric from jsonb_array_elements(coalesce(spec->'items','[]'))x where(x->>'item_id')::uuid=p_after),2147483647)into anchor_order;
 with layout as materialized(select *from jsonb_to_recordset(coalesce(spec->'items','[]'))as x(item_id uuid,category_id uuid,sort_order numeric,featured boolean)),page as(
 select c.item_id,c.item_type,c.name,c.name_en,c.price,c.stock_quantity,c.image_url,
 case when exists(select 1 from jsonb_array_elements(categories)x where(x->>'category_id')::uuid=l.category_id)then l.category_id end pos_category_id,
 coalesce(l.sort_order,2147483647)pos_sort_order,coalesce(l.featured,false)pos_featured
 from public.business_catalog_items c left join layout l on l.item_id=c.item_id
 where c.branch_id=p_branch and c.is_active and(c.name ilike'%'||p_search||'%'or c.name_en ilike'%'||p_search||'%')and(p_after is null or(coalesce(l.sort_order,2147483647),c.item_id)>(anchor_order,p_after))
 order by coalesce(l.sort_order,2147483647),c.item_id limit 101)
 select coalesce(jsonb_agg(to_jsonb(x)order by pos_sort_order,item_id),'[]')into items from page x;
 return(result-'tax_rules'-'tax_rules_version'-'price_basis')||jsonb_build_object('items',case when jsonb_array_length(items)>100 then items-100 else items end,'has_more',jsonb_array_length(items)>100,'pos_categories',categories,'pos_layout_version',coalesce((select version from private.owner_pos_catalog_layouts where branch_id=p_branch order by version desc limit 1),0),'pos_order_basis','owner_order_then_uuid','catalogue_review_supported',true,'tax_classification_source','owner_reviewed_versioned','manual_tax_override',false,'quote_only',true,'can_issue',false);end$$;
notify pgrst,'reload schema';commit;
