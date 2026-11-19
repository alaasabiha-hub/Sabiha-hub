begin;
-- New terms only. Existing snapshots and command receipts retain their original semantics.
create or replace function private.validate_mixed_points_rules(p_branch uuid,p_rules jsonb)returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare k text;entry jsonb;id uuid;ids uuid[]:='{}';rates uuid[]:='{}';
 fields text[]:=array['unit','point_value_basis','point_value_egp','minimum_points','maximum_points','minimum_invoice_egp','maximum_discount_egp','maximum_discount_percent','allow_walk_in','allow_booking','allow_coupon','allow_offer','allow_manual_discount','eligible_item_ids','earning_rates','cancellation','refunded_contribution'];
begin
 if p_rules is null or jsonb_typeof(p_rules)<>'object'or octet_length(p_rules::text)>65536
 or not(p_rules?&fields)or(select count(*)from jsonb_object_keys(p_rules))<>cardinality(fields)
 or p_rules->>'unit' is distinct from'reward_points_v1' then raise exception 'Complete explicit future points rules required; legacy conversion is forbidden'using errcode='22023';end if;
 if coalesce(p_rules->>'point_value_basis','')not in('gross_payable','pre_tax_base')then raise exception 'Owner must explicitly choose the point value basis'using errcode='22023';end if;
 foreach k in array array['point_value_egp','minimum_points','maximum_points','minimum_invoice_egp','maximum_discount_egp','maximum_discount_percent']loop
 if jsonb_typeof(p_rules->k)<>'number'or length(p_rules->>k)>24 or (p_rules->>k)::numeric<0 then raise exception 'Nonnegative bounded numeric points terms required'using errcode='22023';end if;end loop;
 if(p_rules->>'point_value_egp')::numeric<=0 or(p_rules->>'point_value_egp')::numeric>1000000 or round((p_rules->>'point_value_egp')::numeric,4)<>(p_rules->>'point_value_egp')::numeric
 or(p_rules->>'minimum_points')!~'^[1-9][0-9]{0,8}$'or(p_rules->>'maximum_points')!~'^[1-9][0-9]{0,8}$'or(p_rules->>'maximum_points')::numeric<(p_rules->>'minimum_points')::numeric
 or(p_rules->>'maximum_discount_percent')::numeric>100 or round((p_rules->>'maximum_discount_percent')::numeric,4)<>(p_rules->>'maximum_discount_percent')::numeric then raise exception 'Explicit valid point value, integer range and discount ceiling required'using errcode='22023';end if;
 foreach k in array array['minimum_invoice_egp','maximum_discount_egp']loop
 if(p_rules->>k)::numeric>1000000000 or round((p_rules->>k)::numeric,2)<>(p_rules->>k)::numeric then raise exception 'EGP thresholds require cents precision and bounded values'using errcode='22023';end if;end loop;
 foreach k in array array['allow_walk_in','allow_booking','allow_coupon','allow_offer','allow_manual_discount']loop
 if jsonb_typeof(p_rules->k)<>'boolean'then raise exception 'Explicit channel and stacking choices required'using errcode='22023';end if;end loop;
 if not((p_rules->>'allow_walk_in')::boolean or(p_rules->>'allow_booking')::boolean)
 or coalesce(p_rules->>'cancellation','')not in('restore_points','forfeit_points')
 or coalesce(p_rules->>'refunded_contribution','')not in('offset_future_points','freeze_for_owner_review')then raise exception 'Explicit supported channel/cancellation/refund choices required'using errcode='22023';end if;
 if jsonb_typeof(p_rules->'eligible_item_ids')<>'array'or jsonb_array_length(p_rules->'eligible_item_ids')not between 1 and 1000
 or jsonb_typeof(p_rules->'earning_rates')<>'array'or jsonb_array_length(p_rules->'earning_rates')not between 1 and 1000 then raise exception 'Actual eligible items and service earning rates required'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_rules->'eligible_item_ids')loop
 if jsonb_typeof(entry)<>'string'or entry#>>'{}'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then raise exception 'Actual item UUID required'using errcode='22023';end if;
 id:=(entry#>>'{}')::uuid;
 if id=any(ids)or not exists(select 1 from public.business_catalog_items where item_id=id and branch_id=p_branch and item_type in('service','product'))then raise exception 'Distinct same-branch eligible items required'using errcode='22023';end if;ids:=array_append(ids,id);
 end loop;
 for entry in select value from jsonb_array_elements(p_rules->'earning_rates')loop
 if jsonb_typeof(entry)<>'object'or not(entry?&array['item_id','points_per_completed_unit'])or(select count(*)from jsonb_object_keys(entry))<>2
 or jsonb_typeof(entry->'item_id')<>'string'or entry->>'item_id'!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or jsonb_typeof(entry->'points_per_completed_unit')<>'number'or entry->>'points_per_completed_unit'!~'^(0|[1-9][0-9]{0,5}|1000000)$'then raise exception 'Explicit service earning rate required'using errcode='22023';end if;
 id:=(entry->>'item_id')::uuid;
 if id=any(rates)or not exists(select 1 from public.business_catalog_items where item_id=id and branch_id=p_branch and item_type='service')then raise exception 'Distinct same-branch service rates required'using errcode='22023';end if;rates:=array_append(rates,id);
 end loop;
 return(p_rules-'eligible_item_ids'-'earning_rates')||jsonb_build_object('eligible_item_ids',(select jsonb_agg(x::text order by x)from unnest(ids)x),'earning_rates',(select jsonb_agg(jsonb_build_object('item_id',e->>'item_id','points_per_completed_unit',e->'points_per_completed_unit')order by e->>'item_id')from jsonb_array_elements(p_rules->'earning_rates')e));
end$$;

commit;
