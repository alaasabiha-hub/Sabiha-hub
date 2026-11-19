begin;
-- Route canonical work/credit/refund unit allocation only for typed visit snapshots.
-- Existing ordinary/points snapshot arithmetic remains byte-for-byte in the fallback.
CREATE OR REPLACE FUNCTION private.cashier_refund_slice_core(p_snapshot jsonb, p_line text, p_previous_quantity numeric, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
declare j jsonb;q numeric;next_q numeric;amount numeric;tax numeric;discount numeric;visit_part jsonb;covered numeric;manual_part numeric;visit_discount numeric;begin
 if p_snapshot->>'discount_source'='authorized_manual_and_visit_reward'then
 if p_previous_quantity is null or p_quantity is null or p_previous_quantity::text in('NaN','Infinity','-Infinity')or p_quantity::text in('NaN','Infinity','-Infinity')or p_previous_quantity<0 or p_quantity<=0 or p_previous_quantity<>trunc(p_previous_quantity)or p_quantity<>trunc(p_quantity)or p_previous_quantity+p_quantity>2147483647 then raise exception 'Exact bounded original service/product units required'using errcode='22023';end if;
 visit_part:=private.mixed_visit_refund_slice_core(p_snapshot,p_line,p_quantity::bigint,p_previous_quantity::bigint);
 select value into strict j from jsonb_array_elements(p_snapshot->'lines')where value->>'line_id'=p_line;
 q:=(j->>'quantity')::numeric;next_q:=p_previous_quantity+p_quantity;
 manual_part:=round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*next_q/q,5)-round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*p_previous_quantity/q,5);
 visit_discount:=0;
 if j->>'line_id'=p_snapshot#>>'{visit_reward,covered_line}'then
 covered:=(p_snapshot#>>'{visit_reward,covered_units}')::numeric;
 visit_discount:=round((j->>'visit_discount_exact')::numeric*least(next_q,covered)/covered,5)-round((j->>'visit_discount_exact')::numeric*least(p_previous_quantity,covered)/covered,5);
 end if;
 return visit_part||jsonb_build_object('discount_exact',manual_part+visit_discount,'manual_discount_exact',manual_part,'visit_discount_exact',visit_discount);
 end if;

 if p_snapshot->>'arithmetic_version'is distinct from'cashier_tax_v2'or p_line is null or p_previous_quantity is null or p_quantity is null or p_previous_quantity<0 or p_quantity<=0 or p_previous_quantity::text in('NaN','Infinity','-Infinity')or p_quantity::text in('NaN','Infinity','-Infinity')then raise exception 'Exact original refund slice required'using errcode='22023';end if;
 select value into j from jsonb_array_elements(p_snapshot->'lines')where value->>'line_id'=p_line;
 if not found then raise exception 'Original invoice line required'using errcode='22023';end if;
 q:=(j->>'quantity')::numeric;next_q:=p_previous_quantity+p_quantity;
 if next_q>q then raise exception 'Refund exceeds original quantity'using errcode='22023';end if;
 amount:=round((j->>'refundable_amount')::numeric*next_q/q,2)-round((j->>'refundable_amount')::numeric*p_previous_quantity/q,2);
 tax:=round((j->>'tax_amount_exact')::numeric*next_q/q,5)-round((j->>'tax_amount_exact')::numeric*p_previous_quantity/q,5);
 discount:=round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*next_q/q,5)-round(((j->>'item_discount_exact')::numeric+(j->>'invoice_discount_exact')::numeric)*p_previous_quantity/q,5);
 return jsonb_build_object('line_id',p_line,'quantity',p_quantity,'previous_quantity',p_previous_quantity,'cumulative_quantity',next_q,'amount',amount,'tax_amount_exact',tax,'discount_exact',discount,'currency','EGP','original_snapshot_required',true,'refund_executed',false);
end$function$;
revoke all on function private.cashier_refund_slice_core(jsonb,text,numeric,numeric)from public,anon,authenticated,service_role;
commit;
