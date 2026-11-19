begin;
-- INTERNAL arithmetic only. No authenticated/service-role EXECUTE, no public RPC.
-- Callers must resolve prices, legally reviewed classifications and promotion
-- limits from authorized server records. A JSON flag is NOT proof of exemption.
-- Exact pricing/tax operands retain 5 decimal places for future ETA mapping.
-- This function does not submit ETA documents or create invoices/payments.
create function private.cashier_tax_amounts_core(p_lines jsonb,p_invoice_discount_mode text,p_invoice_discount_value numeric)returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare v_line jsonb;prepared jsonb:='[]';lines jsonb;amount numeric;v_base numeric;rate numeric;v_item_disc numeric;cap numeric;eligible numeric:=0;global_disc numeric;mode text;disc_mode text;disc_value numeric;tax_sum numeric;net_sum numeric;total_exact numeric;payable numeric;begin
 if jsonb_typeof(p_lines)is distinct from'array'or jsonb_array_length(p_lines)=0 or octet_length(p_lines::text)>2097152 or p_invoice_discount_mode is null or p_invoice_discount_mode not in('fixed','percentage')or p_invoice_discount_value is null or p_invoice_discount_value::text in('NaN','Infinity','-Infinity')or p_invoice_discount_value<0 or round(p_invoice_discount_value,5)<>p_invoice_discount_value or(p_invoice_discount_mode='percentage'and p_invoice_discount_value>100)then raise exception 'Invalid canonical pricing operands'using errcode='22023';end if;
 if(select count(*)from jsonb_array_elements(p_lines))<>(select count(distinct value->>'line_id')from jsonb_array_elements(p_lines))then raise exception 'Distinct canonical line identities required'using errcode='22023';end if;
 for v_line in select value from jsonb_array_elements(p_lines)loop
 if jsonb_typeof(v_line)is distinct from'object'or jsonb_typeof(v_line->'line_id')is distinct from'string'or length(v_line->>'line_id')not between 1 and 80 or v_line->>'tax_status'is distinct from'verified'or jsonb_typeof(v_line->'unit_price')is distinct from'number'or jsonb_typeof(v_line->'quantity')is distinct from'number'or jsonb_typeof(v_line->'tax_rate')is distinct from'number'or(v_line->>'unit_price')::numeric<0 or(v_line->>'quantity')::numeric<=0 or(v_line->>'tax_rate')::numeric not between 0 and 999 then raise exception 'Verified canonical item classification and nonnegative amounts required'using errcode='22023';end if;
 mode:=v_line->>'tax_mode';rate:=(v_line->>'tax_rate')::numeric;
 if mode is null or mode not in('inclusive','exclusive','exempt','non_taxable')or(mode in('inclusive','exclusive')and rate<=0)or(mode in('exempt','non_taxable')and(rate<>0 or length(trim(coalesce(v_line->>'legal_basis','')))not between 5 and 1000))then raise exception 'Explicit valid tax treatment; exemption requires reviewed legal basis'using errcode='22023';end if;
 amount:=round((v_line->>'unit_price')::numeric*(v_line->>'quantity')::numeric,5);
 v_base:=case when mode='inclusive'then round(amount/(1+rate/100),5)else amount end;
 disc_mode:=coalesce(v_line->>'item_discount_mode','fixed');disc_value:=coalesce((v_line->>'item_discount_value')::numeric,0);
 if disc_mode not in('fixed','percentage')or disc_value<0 or disc_value::text in('NaN','Infinity','-Infinity')or(disc_mode='percentage'and disc_value>100)then raise exception 'Invalid authorized line discount'using errcode='22023';end if;
 cap:=coalesce((v_line->>'max_discount_percent')::numeric,0);
 if cap not between 0 and 100 then raise exception 'Explicit promotion cap required'using errcode='22023';end if;
 cap:=round(v_base*cap/100,5);v_item_disc:=case when disc_mode='percentage'then round(v_base*disc_value/100,5)else round(disc_value,5)end;
 if v_item_disc>v_base or v_item_disc>cap then raise exception 'Line discount exceeds approved cap'using errcode='22023';end if;
 prepared:=prepared||jsonb_build_array(jsonb_build_object('line_id',v_line->>'line_id','unit_price',(v_line->>'unit_price')::numeric,'quantity',(v_line->>'quantity')::numeric,'catalog_amount',amount,'tax_mode',mode,'tax_rate',rate,'base_before_discount_exact',v_base,'original_tax_exact',case when mode='inclusive'then amount-v_base when mode='exclusive'then round(v_base*rate/100,5)else 0 end,'item_discount_exact',v_item_disc,'max_discount_exact',cap,'invoice_discount_eligible',coalesce((v_line->>'allow_invoice_discount')::boolean,false)and(v_item_disc=0 or coalesce((v_line->>'allow_stacking')::boolean,false))));
 if coalesce((v_line->>'allow_invoice_discount')::boolean,false)and(v_item_disc=0 or coalesce((v_line->>'allow_stacking')::boolean,false))then eligible:=eligible+v_base-v_item_disc;end if;
 end loop;
 global_disc:=case when p_invoice_discount_mode='percentage'then round(eligible*p_invoice_discount_value/100,5)else p_invoice_discount_value end;
 if global_disc>eligible then raise exception 'Invoice discount exceeds eligible base or stacking rules'using errcode='22023';end if;
 with sources as(select value j,value->>'line_id' ident,(value->>'base_before_discount_exact')::numeric base,(value->>'item_discount_exact')::numeric item_disc,case when(value->>'invoice_discount_eligible')::boolean then(value->>'base_before_discount_exact')::numeric-(value->>'item_discount_exact')::numeric else 0 end weight from jsonb_array_elements(prepared)),shares as(select *,case when eligible=0 then 0 else global_disc*100000*weight/eligible end units from sources),ranked as(select *,floor(units)whole,row_number()over(order by units-floor(units)desc,ident)priority,sum(floor(units))over()allocated from shares),discounted as(select *, (whole+case when priority<=global_disc*100000-allocated then 1 else 0 end)/100000 invoice_disc from ranked),net as(select *,round(base-item_disc-invoice_disc,5) net_base from discounted),taxed as(select *,case when j->>'tax_mode'in('exempt','non_taxable')then 0 when j->>'tax_mode'='inclusive'and item_disc=0 and invoice_disc=0 then(j->>'original_tax_exact')::numeric else round(net_base*(j->>'tax_rate')::numeric/100,5)end tax from net)
 select jsonb_agg(j||jsonb_build_object('invoice_discount_exact',invoice_disc,'net_amount_exact',net_base,'taxable_amount_exact',case when j->>'tax_mode'in('inclusive','exclusive')then net_base else 0 end,'tax_amount_exact',tax,'line_total_exact',net_base+tax)order by ident),sum(tax),sum(net_base),sum(net_base+tax)into lines,tax_sum,net_sum,total_exact from taxed;
 if exists(select 1 from jsonb_array_elements(lines)x where(x->>'net_amount_exact')::numeric<0 or(x->>'item_discount_exact')::numeric+(x->>'invoice_discount_exact')::numeric>(x->>'max_discount_exact')::numeric)then raise exception 'Combined discount exceeds approved line limit'using errcode='22023';end if;
 payable:=round(total_exact,2);
 -- A stable allocation of the original payable cents bounds future partial refunds.
 with source as(select value j,value->>'line_id' ident,case when total_exact=0 then 0 else payable*100*(value->>'line_total_exact')::numeric/total_exact end cents from jsonb_array_elements(lines)),ranked as(select *,floor(cents)whole,row_number()over(order by cents-floor(cents)desc,ident)priority,sum(floor(cents))over()allocated from source)
 select jsonb_agg(j||jsonb_build_object('refundable_amount',(whole+case when priority<=payable*100-allocated then 1 else 0 end)/100)order by ident)into lines from ranked;
 return jsonb_build_object('arithmetic_version','cashier_tax_v2','currency','EGP','discount_tax_treatment','commercial_before_tax','tax_precision',5,'payable_precision',2,'subtotal_before_discount_exact',(select sum((value->>'base_before_discount_exact')::numeric)from jsonb_array_elements(lines)),'item_discount_exact',(select sum((value->>'item_discount_exact')::numeric)from jsonb_array_elements(lines)),'invoice_discount_exact',global_disc,'net_amount_exact',net_sum,'taxable_amount_exact',(select coalesce(sum((value->>'taxable_amount_exact')::numeric),0)from jsonb_array_elements(lines)),'non_taxable_amount_exact',(select coalesce(sum((value->>'net_amount_exact')::numeric),0)from jsonb_array_elements(lines)where value->>'tax_mode'in('exempt','non_taxable')),'tax_amount_exact',tax_sum,'total_exact',total_exact,'total',payable,'payable_rounding',payable-total_exact,'lines',lines,'eta_submission_enabled',false,'quote_only',true,'earned_commission',false);
end$$;
create function private.cashier_refund_slice_core(p_snapshot jsonb,p_line text,p_previous_quantity numeric,p_quantity numeric)returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare j jsonb;q numeric;next_q numeric;amount numeric;tax numeric;discount numeric;begin
 if p_snapshot->>'arithmetic_version'is distinct from'cashier_tax_v2'or p_line is null or p_previous_quantity is null or p_quantity is null or p_previous_quantity<0 or p_quantity<=0 or p_previous_quantity::text in('NaN','Infinity','-Infinity')or p_quantity::text in('NaN','Infinity','-Infinity')then raise exception 'Exact original refund slice required'using errcode='22023';end if;
 select value into j from jsonb_array_elements(p_snapshot->'lines')where value->>'line_id'=p_line;
 if not found then raise exception 'Original invoice line required'using errcode='22023';end if;
 q:=(j->>'quantity')::numeric;next_q:=p_previous_quantity+p_quantity;
 if next_q>q then raise exception 'Refund exceeds original quantity'using errcode='22023';end if;
 amount:=round((j->>'refundable_amount')::numeric*next_q/q,2)-round((j->>'refundable_amount')::numeric*p_previous_quantity/q,2);
 tax:=round((j->>'tax_amount_exact')::numeric*next_q/q,5)-round((j->>'tax_amount_exact')::numeric*p_previous_quantity/q,5);
 discount:=round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*next_q/q,5)-round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*p_previous_quantity/q,5);
 return jsonb_build_object('line_id',p_line,'quantity',p_quantity,'previous_quantity',p_previous_quantity,'cumulative_quantity',next_q,'amount',amount,'tax_amount_exact',tax,'discount_exact',discount,'currency','EGP','original_snapshot_required',true,'refund_executed',false);
end$$;
revoke all on function private.cashier_tax_amounts_core(jsonb,text,numeric),private.cashier_refund_slice_core(jsonb,text,numeric,numeric)from public,anon,authenticated,service_role;
commit;
