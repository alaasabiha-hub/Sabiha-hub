begin;
-- Private arithmetic ONLY. No balance access, reservation, assent or issuance.
-- Callers must provide the sealed canonical quote and an explicit owner-approved
-- tax treatment; this calculator does not infer legal tax treatment of rewards.
create or replace function private.mixed_visit_coverage_core(p_quote jsonb,p_rules jsonb,p_line text,p_units bigint)returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog as $$
declare j jsonb;k text;target jsonb;qty numeric;covered_base numeric;remaining_base numeric;remaining_tax numeric;
 lines jsonb:='[]'::jsonb;net_sum numeric;tax_sum numeric;total_exact numeric;payable numeric;original_payable numeric;threshold numeric;max_units numeric;
begin
 if jsonb_typeof(p_quote)is distinct from'object'or jsonb_typeof(p_rules)is distinct from'object'or octet_length(p_quote::text)>2097152 then raise exception 'Bounded quote and explicit visit terms required'using errcode='22023';end if;
 if p_quote->>'kind'is distinct from'cashier_cart_reviewed_quote_v2'or p_quote->>'currency'is distinct from'EGP'or p_quote->>'discount_source'is distinct from'authorized_manual_invoice_only'
 or p_quote?'loyalty_points'or p_quote?'visit_reward'or p_quote?'reward_snapshot' then raise exception 'Uncovered canonical quote required; composition needs a separate witness'using errcode='22023';end if;
 if p_rules->>'unit'is distinct from'service_visits'or p_rules->>'tax_treatment'is distinct from'commercial_before_tax'or jsonb_typeof(p_rules->'allow_manual_discount')is distinct from'boolean'
 or jsonb_typeof(p_rules->'reward_item_id')is distinct from'string'or nullif(p_rules->>'reward_item_id','')is null
 then raise exception 'Explicit service-visit coverage and tax terms required'using errcode='22023';end if;
 foreach k in array array['threshold_visits','maximum_covered_units','minimum_invoice_egp']loop
 if jsonb_typeof(p_rules->k)is distinct from'number'or(p_rules->>k)::numeric<0 then raise exception 'Explicit nonnegative visit limits required'using errcode='22023';end if;end loop;
 threshold:=(p_rules->>'threshold_visits')::numeric;max_units:=(p_rules->>'maximum_covered_units')::numeric;
 if threshold<1 or threshold<>trunc(threshold)or max_units<1 or max_units<>trunc(max_units)or p_units is null or p_units<1 or p_units>max_units or p_line is null or p_line=''then raise exception 'Exact positive visit quantities required'using errcode='22023';end if;
 if jsonb_typeof(p_quote->'lines')is distinct from'array'or jsonb_array_length(p_quote->'lines')=0 then raise exception 'Actual invoice lines required'using errcode='22023';end if;
 foreach k in array array['total','invoice_discount_exact','net_amount_exact','tax_amount_exact','total_exact']loop
 if jsonb_typeof(p_quote->k)is distinct from'number'or(p_quote->>k)::numeric<0 then raise exception 'Canonical nonnegative quote totals required'using errcode='22023';end if;end loop;
 original_payable:=(p_quote->>'total')::numeric;
 if original_payable<(p_rules->>'minimum_invoice_egp')::numeric then raise exception 'Invoice below owner minimum'using errcode='22023';end if;
 if(p_quote->>'invoice_discount_exact')::numeric>0 and p_rules->>'allow_manual_discount'is distinct from'true'then raise exception 'Owner terms forbid manual discount composition'using errcode='22023';end if;
 for j in select value from jsonb_array_elements(p_quote->'lines')loop
 if jsonb_typeof(j)is distinct from'object'or nullif(j->>'line_id','')is null or nullif(j->>'item_id','')is null or j->>'item_type'is null or j->>'item_type'not in('service','product')then raise exception 'Typed canonical line required'using errcode='22023';end if;
 foreach k in array array['quantity','net_amount_exact','tax_amount_exact','line_total_exact','tax_rate','base_before_discount_exact','taxable_amount_exact','commission_basis_exact']loop
 if jsonb_typeof(j->k)is distinct from'number'or(j->>k)::numeric<0 then raise exception 'Explicit nonnegative canonical line amounts required'using errcode='22023';end if;end loop;
 qty:=(j->>'quantity')::numeric;
 if qty<1 or qty<>trunc(qty)or(j->>'tax_rate')::numeric>999 or j->>'tax_mode'is null or j->>'tax_mode'not in('inclusive','exclusive','exempt','non_taxable')
 or(j->>'line_total_exact')::numeric<>(j->>'net_amount_exact')::numeric+(j->>'tax_amount_exact')::numeric
 or(j->>'taxable_amount_exact')::numeric<>(case when j->>'tax_mode'in('inclusive','exclusive')then(j->>'net_amount_exact')::numeric else 0 end)
 or(j->>'net_amount_exact')::numeric>(j->>'base_before_discount_exact')::numeric
 or(j->>'commission_basis_exact')::numeric<>(case when j->>'item_type'='service'then(j->>'base_before_discount_exact')::numeric else 0 end)
 then raise exception 'Inconsistent quantity, tax or preserved commission basis'using errcode='22023';end if;
 if j->>'tax_mode'in('exempt','non_taxable')and((j->>'tax_rate')::numeric<>0 or(j->>'tax_amount_exact')::numeric<>0)then raise exception 'Inconsistent exemption'using errcode='22023';end if;
 if j->>'line_id'=p_line then target:=j;end if;
 end loop;
 if(select count(*)from jsonb_array_elements(p_quote->'lines'))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_quote->'lines'))then raise exception 'Duplicate invoice line'using errcode='22023';end if;
 select sum((value->>'net_amount_exact')::numeric),sum((value->>'tax_amount_exact')::numeric),sum((value->>'line_total_exact')::numeric)into net_sum,tax_sum,total_exact from jsonb_array_elements(p_quote->'lines');
 if net_sum<>(p_quote->>'net_amount_exact')::numeric or tax_sum<>(p_quote->>'tax_amount_exact')::numeric or total_exact<>(p_quote->>'total_exact')::numeric or original_payable<>round(total_exact,2)then raise exception 'Inconsistent original totals'using errcode='22023';end if;
 if target is null or target->>'item_type'<>'service'or target->>'item_id'<>p_rules->>'reward_item_id'or p_units>(target->>'quantity')::numeric then raise exception 'Eligible service units required; products cannot consume visits'using errcode='22023';end if;
 -- Compact first-unit interval: no per-unit loop, even for very large quantities.
 -- Existing manual discounts have already been allocated by the canonical quote.
 qty:=(target->>'quantity')::numeric;covered_base:=round((target->>'net_amount_exact')::numeric*p_units/qty,5);
 if covered_base<=0 then raise exception 'Positive service coverage required'using errcode='22023';end if;
 remaining_base:=(target->>'net_amount_exact')::numeric-covered_base;
 remaining_tax:=case when target->>'tax_mode'in('exempt','non_taxable')then 0 else round(remaining_base*(target->>'tax_rate')::numeric/100,5)end;
 -- Never create a tax increase from a reward or consume unsupported input rounding.
 if remaining_base<0 or remaining_tax>(target->>'tax_amount_exact')::numeric then raise exception 'Coverage tax requires a reviewed compatible quote'using errcode='22023';end if;
 for j in select value from jsonb_array_elements(p_quote->'lines')loop
 if j->>'line_id'=p_line then
 j:=j||jsonb_build_object('visit_discount_exact',covered_base,'visit_tax_reduction_exact',(j->>'tax_amount_exact')::numeric-remaining_tax,'visit_covered_quantity',p_units,'net_amount_exact',remaining_base,'taxable_amount_exact',case when j->>'tax_mode'in('inclusive','exclusive')then remaining_base else 0 end,'tax_amount_exact',remaining_tax,'line_total_exact',remaining_base+remaining_tax);
 end if;lines:=lines||jsonb_build_array(j);
 end loop;
 select sum((value->>'net_amount_exact')::numeric),sum((value->>'tax_amount_exact')::numeric),sum((value->>'line_total_exact')::numeric)into net_sum,tax_sum,total_exact from jsonb_array_elements(lines);payable:=round(total_exact,2);
 -- Reallocate actual remaining payable cents so refunds cannot exceed payment.
 with source as(select value j,value->>'line_id' ident,payable*100*(value->>'line_total_exact')::numeric numerator from jsonb_array_elements(lines)),shares as(select *,case when total_exact=0 then 0 else div(numerator,total_exact)end whole,case when total_exact=0 then 0 else mod(numerator,total_exact)end remainder from source),ranked as(select *,row_number()over(order by remainder desc,ident)priority,sum(whole)over()allocated from shares)
 select jsonb_agg(ranked.j||jsonb_build_object('refundable_amount',(whole+case when priority<=payable*100-allocated then 1 else 0 end)*0.01)order by ident)into lines from ranked;
 return p_quote||jsonb_build_object('lines',lines,'net_amount_exact',net_sum,'taxable_amount_exact',(select coalesce(sum((value->>'taxable_amount_exact')::numeric),0)from jsonb_array_elements(lines)),'non_taxable_amount_exact',(select coalesce(sum((value->>'net_amount_exact')::numeric),0)from jsonb_array_elements(lines)where value->>'tax_mode'in('exempt','non_taxable')),'tax_amount_exact',tax_sum,'total_exact',total_exact,'total',payable,'payable_rounding',payable-total_exact,'visit_discount_exact',covered_base,'discount_source','authorized_manual_and_visit_reward',
 'visit_reward',jsonb_build_object('unit','service_visits','threshold_visits',threshold,'covered_line',p_line,'covered_item',target->'item_id','covered_units',p_units,'unit_first',1,'unit_last',p_units,'required_visits',threshold*p_units,'tax_treatment','commercial_before_tax','net_coverage_exact',covered_base,'payable_reduction',original_payable-payable),
 'quote_only',true,'can_issue',false,'balance_reserved',false,'consent_authorized',false,'redemption_enabled',false,'earned_commission',false,'legally_verified_by_software',false,'eta_accepted',false);
end$$;
revoke all on function private.mixed_visit_coverage_core(jsonb,jsonb,text,bigint)from public,anon,authenticated,service_role;
alter function private.mixed_visit_refund_slice_core(jsonb,text,bigint,bigint) stable;
commit;
