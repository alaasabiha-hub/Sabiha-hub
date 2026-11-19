begin;
-- Authorization delegates to invoice_document_data, which locks the live session.
-- PostgREST must run this RPC in a read-write transaction even though no financial
-- records are written. Keep ownership checks and existing function ACL unchanged.
alter function private.get_invoice_refund_document(uuid) volatile;
alter function public.get_invoice_refund_document(uuid) volatile;
notify pgrst,'reload schema';
commit;
