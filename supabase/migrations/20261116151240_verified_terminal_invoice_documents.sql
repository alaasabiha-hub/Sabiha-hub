begin;
-- Preserve the complete existing authorization, session and financial projection chain.
alter function private.invoice_document_data(uuid,boolean)rename to invoice_document_data_before_terminal_receipts;
revoke all on function private.invoice_document_data_before_terminal_receipts(uuid,boolean)from public,anon,authenticated,service_role;
create function private.invoice_document_data(p_token uuid,p_allow_revoked boolean)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog as $$
declare doc jsonb;sale public.business_payment_events;receipt private.card_terminal_confirmations;i public.business_invoices;refunded numeric;
begin
 doc:=private.invoice_document_data_before_terminal_receipts(p_token,p_allow_revoked);
 select e.*into sale from public.business_payment_events e where e.invoice_id=doc->>'invoice_id'and e.event_type='sale'and e.method='card_terminal';
 if not found then return doc;end if;
 select *into receipt from private.card_terminal_confirmations where payment_id=sale.payment_id and invoice_id=sale.invoice_id and amount=sale.amount;
 if not found then return doc;end if;
 select *into strict i from public.business_invoices where invoice_id=sale.invoice_id;
 select coalesce(sum(amount),0)into refunded from public.business_payment_events where invoice_id=sale.invoice_id and event_type='refund';
 return doc||jsonb_build_object('payment_method','card_terminal','payment_status',case when i.status='void'then'cancelled'when refunded>=sale.amount then'refunded'when refunded>0 then'partially_refunded'else'paid'end,
 'terminal_transaction_reference',receipt.reference,'terminal_confirmation_source','verified_cashier_receipt','net_collected',sale.amount-refunded,'refund_amount',refunded,'remaining_refundable',sale.amount-refunded,'amount_outstanding',0);
end$$;
revoke all on function private.invoice_document_data(uuid,boolean)from public,anon,authenticated,service_role;
create or replace function private.resolve_invoice_document(p_token uuid)returns jsonb language sql volatile security definer set search_path=pg_catalog as $$select private.invoice_document_data(p_token,false)$$;
commit;
