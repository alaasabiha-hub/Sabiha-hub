begin;
-- Future document generation only; never rewrite an issued stored snapshot.
alter function private.invoice_snapshot(text)rename to invoice_snapshot_before_mixed_visits;
revoke all on function private.invoice_snapshot_before_mixed_visits(text)from public,anon,authenticated,service_role;
create function private.invoice_snapshot(p_invoice text)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$
declare snap jsonb;p private.cashier_invoice_postings;begin
 snap:=private.invoice_snapshot_before_mixed_visits(p_invoice);
 select x.*into p from private.cashier_invoice_postings x join private.mixed_visit_invoice_bindings b on b.invoice_id=x.invoice_id where x.invoice_id=p_invoice;
 if not found then return snap;end if;
 return snap||jsonb_build_object('visit_loyalty',jsonb_build_object('unit','service_visits','visits_redeemed',p.quote#>'{visit_reward,required_visits}','covered_service_units',p.quote#>'{visit_reward,covered_units}','payable_discount',p.quote#>'{visit_reward,payable_reduction}','net_coverage_exact',p.quote#>'{visit_reward,net_coverage_exact}','currency','EGP','tax_treatment',p.quote#>'{visit_reward,tax_treatment}','approval_method','cashier_attested_verbal'));
end$$;
revoke all on function private.invoice_snapshot(text)from public,anon,authenticated,service_role;
commit;
