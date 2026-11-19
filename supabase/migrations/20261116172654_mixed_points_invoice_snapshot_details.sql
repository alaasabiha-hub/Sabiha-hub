begin;
alter function private.invoice_snapshot(text)rename to invoice_snapshot_before_mixed_points;
revoke all on function private.invoice_snapshot_before_mixed_points(text)from public,anon,authenticated,service_role;
create function private.invoice_snapshot(p_invoice text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare snap jsonb;p private.cashier_invoice_postings;begin
 snap:=private.invoice_snapshot_before_mixed_points(p_invoice);
 select *into p from private.cashier_invoice_postings where invoice_id=p_invoice and quote?'loyalty_points';
 if not found then return snap;end if;
 return snap||jsonb_build_object('loyalty',jsonb_build_object('unit','reward_points_v1','points',p.quote->'loyalty_points','payable_discount',p.quote->'loyalty_payable_reduction','value_basis',p.quote->'loyalty_value_basis','original_total',(p.quote->>'total')::numeric+(p.quote->>'loyalty_payable_reduction')::numeric,'approval_method',case when exists(select 1 from private.mixed_points_verbal_consents v join private.mixed_points_issue_authorizations a on a.consent_id=v.request_id where a.request_id=p.request_id)then'cashier_attested_verbal'else'customer_exact_financial_consent'end));
end$$;
revoke all on function private.invoice_snapshot(text)from public,anon,authenticated,service_role;
commit;
