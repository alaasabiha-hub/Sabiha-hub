begin;
-- Internal calculator only. Callers must resolve the sealed server quote and
-- validated owner policy; this function grants no consent or balance access.
create function private.mixed_loyalty_discount_core(p_quote jsonb,p_rules jsonb,p_points bigint)returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare prior_discount numeric;entry jsonb;k text;basis text;requested numeric;weight_sum numeric;lines jsonb;discount numeric;net_sum numeric;tax_sum numeric;total_exact numeric;payable numeric;before_payable numeric;
begin
 if jsonb_typeof(p_rules)is distinct from'object' or jsonb_typeof(p_quote)is distinct from'object' then raise exception 'Objects required'using errcode='22023';end if;
 if not(p_rules?&array['maximum_discount_egp','maximum_discount_percent','minimum_invoice_egp','allow_manual_discount','eligible_item_ids'])then raise exception 'Explicit ceilings required'using errcode='22023';end if;
 foreach k in array array['maximum_discount_egp','maximum_discount_percent','minimum_invoice_egp','point_value_egp','minimum_points','maximum_points']loop
 if jsonb_typeof(p_rules->k)is distinct from'number'or(p_rules->>k)::numeric<0 then raise exception 'Numeric policy values required'using errcode='22023';end if;end loop;
 if jsonb_typeof(p_rules->'allow_manual_discount')is distinct from'boolean'or(p_rules->>'maximum_discount_percent')::numeric>100 then raise exception 'Explicit stacking and cap required'using errcode='22023';end if;
 if jsonb_typeof(p_rules->'eligible_item_ids')is distinct from'array' then raise exception 'Eligible items required'using errcode='22023';end if;
 basis:=p_rules->>'point_value_basis';
 if p_quote->>'kind'is distinct from'cashier_cart_reviewed_quote_v2'or p_quote->>'currency'is distinct from'EGP'or jsonb_typeof(p_quote->'lines')is distinct from'array'or jsonb_array_length(p_quote->'lines')=0
 or p_rules->>'unit'is distinct from'reward_points_v1'or basis is null or basis not in('gross_payable','pre_tax_base')or p_points is null or p_points<=0
 or(p_rules->>'point_value_egp')is null or(p_rules->>'point_value_egp')::numeric<=0
 or(p_rules->>'minimum_points')is null or(p_rules->>'maximum_points')is null
 or p_points<(p_rules->>'minimum_points')::bigint or p_points>(p_rules->>'maximum_points')::bigint
 then raise exception 'Canonical reviewed quote and explicit point terms required'using errcode='22023';end if;
 foreach k in array array['total','invoice_discount_exact']loop
 if jsonb_typeof(p_quote->k)is distinct from'number' then raise exception 'Quote totals required'using errcode='22023';end if;end loop;
 if coalesce((p_quote->>'invoice_discount_exact')::numeric,0)>0 and p_rules->>'allow_manual_discount'is distinct from'true'then raise exception 'Owner policy forbids stacking manual discount'using errcode='22023';end if;
 -- Offer/coupon composition needs separate versioned witnesses; never infer it.
 if p_quote->>'discount_source'is distinct from'authorized_manual_invoice_only'then raise exception 'Unsupported discount provenance'using errcode='22023';end if;
 if octet_length(p_quote::text)>2097152 then raise exception 'Quote too large'using errcode='22023';end if;
 if p_quote?'loyalty_points' then raise exception 'Loyalty cannot be applied twice'using errcode='22023';end if;
 for entry in select value from jsonb_array_elements(p_quote->'lines')loop
 if jsonb_typeof(entry)is distinct from'object' then raise exception 'Line object required'using errcode='22023';end if;
 foreach k in array array['quantity','net_amount_exact','tax_amount_exact','line_total_exact','tax_rate']loop
 if jsonb_typeof(entry->k)is distinct from'number'or(entry->>k)::numeric<0 then raise exception 'Explicit nonnegative line operands required'using errcode='22023';end if;end loop;
 if(entry->>'quantity')::numeric<=0 or(entry->>'quantity')::numeric<>trunc((entry->>'quantity')::numeric)or(entry->>'tax_rate')::numeric>999
 or entry->>'tax_mode'is null or entry->>'tax_mode'not in('inclusive','exclusive','exempt','non_taxable')
 or(entry->>'line_total_exact')::numeric<>(entry->>'net_amount_exact')::numeric+(entry->>'tax_amount_exact')::numeric
 then raise exception 'Inconsistent line operands'using errcode='22023';end if;
 if entry->>'tax_mode'in('exempt','non_taxable')and((entry->>'tax_rate')::numeric<>0 or(entry->>'tax_amount_exact')::numeric<>0)then raise exception 'Inconsistent exemption'using errcode='22023';end if;
 end loop;
 if(p_quote->>'total')::numeric<>round((select sum((value->>'line_total_exact')::numeric)from jsonb_array_elements(p_quote->'lines')),2)then raise exception 'Inconsistent payable'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_quote->'lines')where value->>'line_id'is null or value->>'item_id'is null or(value->>'net_amount_exact')::numeric<0)then raise exception 'Invalid line'using errcode='22023';end if;
 if(select count(*)from jsonb_array_elements(p_quote->'lines'))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_quote->'lines'))then raise exception 'Duplicate line'using errcode='22023';end if;
 requested:=round(p_points*(p_rules->>'point_value_egp')::numeric,5);
 select coalesce(sum(case when basis='gross_payable'then(value->>'line_total_exact')::numeric else(value->>'net_amount_exact')::numeric end),0)into weight_sum
 from jsonb_array_elements(p_quote->'lines')where(p_rules->'eligible_item_ids')?(value->>'item_id');
 if weight_sum<=0 or requested>weight_sum or(p_quote->>'total')::numeric<(p_rules->>'minimum_invoice_egp')::numeric then raise exception 'Insufficient eligible amount or invoice threshold'using errcode='22023';end if;
 with src as(select value j,value->>'line_id'id,case when(p_rules->'eligible_item_ids')?(value->>'item_id')then case when basis='gross_payable'then(value->>'line_total_exact')::numeric else(value->>'net_amount_exact')::numeric end else 0 end w from jsonb_array_elements(p_quote->'lines')),
 shares as(select *,requested*100000*w/weight_sum units from src),ranked as(select *,floor(units)whole,row_number()over(order by units-floor(units)desc,id)priority,sum(floor(units))over()allocated from shares),amounts as(select *, (whole+case when priority<=requested*100000-allocated then 1 else 0 end)/100000 reduction from ranked),
 discounted as(select *,case when basis='gross_payable'and j->>'tax_mode'in('inclusive','exclusive')then round(reduction/(1+(j->>'tax_rate')::numeric/100),5)else reduction end base_discount from amounts),
 net as(select *,round((j->>'net_amount_exact')::numeric-base_discount,5)new_net from discounted),taxed as(select *,case when base_discount=0 then(j->>'tax_amount_exact')::numeric when j->>'tax_mode'in('inclusive','exclusive')then round(new_net*(j->>'tax_rate')::numeric/100,5)else 0 end new_tax from net)
 select jsonb_agg(j||jsonb_build_object('original_item_discount_exact',coalesce(j->'item_discount_exact','0'::jsonb),'original_invoice_discount_exact',coalesce(j->'invoice_discount_exact','0'::jsonb),'item_discount_exact',coalesce((j->>'item_discount_exact')::numeric,0)+base_discount,'loyalty_base_discount_exact',base_discount,'loyalty_gross_discount_exact',(j->>'line_total_exact')::numeric-new_net-new_tax,'original_net_amount_exact',j->'net_amount_exact','original_tax_amount_exact',j->'tax_amount_exact','original_line_total_exact',j->'line_total_exact','net_amount_exact',new_net,'tax_amount_exact',new_tax,'taxable_amount_exact',case when j->>'tax_mode'in('inclusive','exclusive')then new_net else 0 end,'line_total_exact',new_net+new_tax)order by id),sum(new_net),sum(new_tax),sum(new_net+new_tax),sum((j->>'line_total_exact')::numeric-new_net-new_tax)into lines,net_sum,tax_sum,total_exact,discount from taxed;
 if exists(select 1 from jsonb_array_elements(lines)where(value->>'net_amount_exact')::numeric<0 or(value->>'loyalty_gross_discount_exact')::numeric<0)then raise exception 'Invalid discount allocation'using errcode='22023';end if;
 select coalesce(sum((coalesce((value->>'item_discount_exact')::numeric,0)+coalesce((value->>'invoice_discount_exact')::numeric,0))*(1+case when value->>'tax_mode'in('inclusive','exclusive')then(value->>'tax_rate')::numeric/100 else 0 end)),0)into prior_discount from jsonb_array_elements(p_quote->'lines');
 if discount+prior_discount>(p_rules->>'maximum_discount_egp')::numeric or discount+prior_discount>round((select sum((value->>'line_total_exact')::numeric)from jsonb_array_elements(p_quote->'lines')where(p_rules->'eligible_item_ids')?(value->>'item_id'))*(p_rules->>'maximum_discount_percent')::numeric/100,5)then raise exception 'Owner discount ceiling exceeded'using errcode='22023';end if;
 payable:=round(total_exact,2);before_payable:=(p_quote->>'total')::numeric;
 if before_payable<=payable then raise exception 'Points must produce a positive payable reduction'using errcode='22023';end if;
 if basis='gross_payable'and before_payable-payable<>round(requested,2)then raise exception 'Point value cannot be represented in payable cents; review quantity'using errcode='22023';end if;
 with src as(select value j,value->>'line_id'id,case when total_exact=0 then 0 else payable*100*(value->>'line_total_exact')::numeric/total_exact end cents from jsonb_array_elements(lines)),ranked as(select *,floor(cents)whole,row_number()over(order by cents-floor(cents)desc,id)priority,sum(floor(cents))over()allocated from src)
 select jsonb_agg(j||jsonb_build_object('refundable_amount',(whole+case when priority<=payable*100-allocated then 1 else 0 end)/100)order by id)into lines from ranked;
 return p_quote||jsonb_build_object('lines',lines,'total',payable,'total_exact',total_exact,'net_amount_exact',net_sum,'taxable_amount_exact',(select coalesce(sum((value->>'taxable_amount_exact')::numeric),0)from jsonb_array_elements(lines)),'non_taxable_amount_exact',(select coalesce(sum((value->>'net_amount_exact')::numeric),0)from jsonb_array_elements(lines)where value->>'tax_mode'in('exempt','non_taxable')),'tax_amount_exact',tax_sum,'loyalty_points',p_points,'loyalty_value_basis',basis,'loyalty_requested_value',requested,'loyalty_gross_discount_exact',discount,'loyalty_payable_reduction',before_payable-payable,'payable_rounding',payable-total_exact,'quote_only',true,'consent_authorized',false,'redemption_enabled',false,'balance_reserved',false);
end$$;
revoke all on function private.mixed_loyalty_discount_core(jsonb,jsonb,bigint)from public,anon,authenticated,service_role;
commit;
