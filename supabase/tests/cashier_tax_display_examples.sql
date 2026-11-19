-- Pure QA regression for the server's canonical invoice-tax arithmetic.
-- This never inserts invoices, payments, tax classifications, or customer data.
do $$
declare
  inclusive_quote jsonb;
  exclusive_quote jsonb;
begin
  inclusive_quote := private.cashier_tax_amounts_core(
    '[{"line_id":"inclusive-200","unit_price":200,"quantity":1,"tax_mode":"inclusive","tax_rate":14,"tax_status":"verified","max_discount_percent":100,"allow_invoice_discount":true,"allow_stacking":false}]'::jsonb,
    'fixed', 0
  );
  if (inclusive_quote->>'total')::numeric <> 200
     or (inclusive_quote->>'net_amount_exact')::numeric <> 175.4386
     or (inclusive_quote->>'tax_amount_exact')::numeric <> 24.5614 then
    raise exception 'Inclusive EGP 200 at 14%% must stay EGP 200 total with extracted VAT';
  end if;

  exclusive_quote := private.cashier_tax_amounts_core(
    '[{"line_id":"exclusive-200","unit_price":200,"quantity":1,"tax_mode":"exclusive","tax_rate":14,"tax_status":"verified","max_discount_percent":100,"allow_invoice_discount":true,"allow_stacking":false}]'::jsonb,
    'fixed', 0
  );
  if (exclusive_quote->>'total')::numeric <> 228
     or (exclusive_quote->>'net_amount_exact')::numeric <> 200
     or (exclusive_quote->>'tax_amount_exact')::numeric <> 28 then
    raise exception 'Exclusive EGP 200 at 14%% must total EGP 228';
  end if;
end
$$;
