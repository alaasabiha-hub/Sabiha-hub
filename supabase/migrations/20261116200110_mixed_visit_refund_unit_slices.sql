begin;
-- Private frozen-snapshot arithmetic. No refund, stock return, work cancellation
-- or restoration of visit rights is authorized/executed by this function.
create function private.mixed_visit_refund_slice_core(p_quote jsonb,p_line text,p_quantity bigint,p_previous_quantity bigint)returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare line jsonb;cover jsonb;qty numeric;covered numeric:=0;before_paid numeric;after_paid numeric;paid_units numeric;
 amount_units numeric;tax_units numeric;before_amount numeric;after_amount numeric;before_tax numeric;after_tax numeric;
 covered_in_slice numeric:=0;threshold numeric;amount numeric;tax numeric;
begin
 if jsonb_typeof(p_quote)is distinct from'object'or p_quote->>'currency'is distinct from'EGP'or p_quote->>'discount_source'is distinct from'authorized_manual_and_visit_reward'
 or jsonb_typeof(p_quote->'lines')is distinct from'array'or jsonb_typeof(p_quote->'visit_reward')is distinct from'object'or octet_length(p_quote::text)>2097152
 or p_line is null or p_quantity is null or p_previous_quantity is null or p_quantity<=0 or p_previous_quantity<0
 then raise exception 'Exact original mixed-visit quote and positive unit slice required'using errcode='22023';end if;
 if(select count(*)from jsonb_array_elements(p_quote->'lines'))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_quote->'lines'))then raise exception 'Distinct frozen lines required'using errcode='22023';end if;
 select value into line from jsonb_array_elements(p_quote->'lines')where value->>'line_id'=p_line;
 if line is null or line->>'item_type'is null or line->>'item_type'not in('service','product')or jsonb_typeof(line->'quantity')is distinct from'number'or jsonb_typeof(line->'refundable_amount')is distinct from'number'or jsonb_typeof(line->'tax_amount_exact')is distinct from'number'then raise exception 'Actual original paid line required'using errcode='22023';end if;
 qty:=(line->>'quantity')::numeric;amount:=(line->>'refundable_amount')::numeric;tax:=(line->>'tax_amount_exact')::numeric;
 if qty<1 or qty<>trunc(qty)or p_previous_quantity::numeric+p_quantity>qty or amount<0 or round(amount,2)<>amount or tax<0 or round(tax,5)<>tax then raise exception 'Slice exceeds original units or exact paid amounts'using errcode='22023';end if;
 cover:=p_quote->'visit_reward';
 if cover->>'unit'is distinct from'service_visits'or jsonb_typeof(cover->'threshold_visits')is distinct from'number'or nullif(cover->>'covered_line','')is null then raise exception 'Original visit coverage required'using errcode='22023';end if;
 threshold:=(cover->>'threshold_visits')::numeric;
 if threshold<1 or threshold<>trunc(threshold)then raise exception 'Exact original visit threshold required'using errcode='22023';end if;
 if cover->>'covered_line'=p_line then
 if line->>'item_type'<>'service'or line->>'item_id'is distinct from cover->>'covered_item'or jsonb_typeof(cover->'covered_units')is distinct from'number'
 or jsonb_typeof(cover->'unit_first')is distinct from'number'or jsonb_typeof(cover->'unit_last')is distinct from'number'or jsonb_typeof(line->'visit_covered_quantity')is distinct from'number'then raise exception 'Original covered service interval required'using errcode='22023';end if;
 covered:=(cover->>'covered_units')::numeric;
 if covered<1 or covered>qty or covered<>trunc(covered)or(cover->>'unit_first')::numeric<>1 or(cover->>'unit_last')::numeric<>covered or(line->>'visit_covered_quantity')::numeric<>covered then raise exception 'Inconsistent covered unit interval'using errcode='22023';end if;
 elsif line?'visit_covered_quantity'then raise exception 'Unexpected coverage on another line'using errcode='22023';end if;
 paid_units:=qty-covered;
 if paid_units=0 and(amount<>0 or tax<>0)then raise exception 'Fully covered service cannot carry paid refund amounts'using errcode='22023';end if;
 before_paid:=greatest(p_previous_quantity::numeric-covered,0);after_paid:=greatest(p_previous_quantity::numeric+p_quantity-covered,0);
 covered_in_slice:=least(p_previous_quantity::numeric+p_quantity,covered)-least(p_previous_quantity::numeric,covered);
 amount_units:=amount*100;tax_units:=tax*100000;
 -- Integer half-up cumulative allocation. Avoid numeric division rounding away
 -- cents at large magnitudes. No enumeration of quantity/covered units.
 if paid_units=0 then before_amount:=0;after_amount:=0;before_tax:=0;after_tax:=0;
 else
 before_amount:=div(amount_units*before_paid*2+paid_units,paid_units*2);after_amount:=div(amount_units*after_paid*2+paid_units,paid_units*2);
 before_tax:=div(tax_units*before_paid*2+paid_units,paid_units*2);after_tax:=div(tax_units*after_paid*2+paid_units,paid_units*2);
 end if;
 return jsonb_build_object('line_id',p_line,'quantity',p_quantity,'previous_quantity',p_previous_quantity,'cumulative_quantity',p_previous_quantity::numeric+p_quantity,
 'amount',(after_amount-before_amount)*0.01,'tax_amount_exact',(after_tax-before_tax)*0.00001,'covered_service_units',covered_in_slice,'original_visits_affected',covered_in_slice*threshold,
 'currency','EGP','original_snapshot_required',true,'refund_executed',false,'visit_restoration_authorized',false,'stock_return_authorized',false,'service_cancellation_authorized',false);
end$$;
revoke all on function private.mixed_visit_refund_slice_core(jsonb,text,bigint,bigint)from public,anon,authenticated,service_role;
commit;
