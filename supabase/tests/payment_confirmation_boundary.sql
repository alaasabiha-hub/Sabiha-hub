-- Local-only runner: tools/payment_confirmation_e2e.py. Every fixture and ledger
-- event is rolled back; no gateway, real money or production endpoint is used.
begin;
do $$
<<payment_confirmation_boundary>>
declare
  owner_id uuid;
  customer_id uuid;
  branch_id uuid := gen_random_uuid();
  shift_id uuid := gen_random_uuid();
  payment_id uuid := gen_random_uuid();
  invoice_id text := 'QA-PAYMENT-BOUNDARY-' || gen_random_uuid()::text;
  document_token uuid;
  rejected boolean;
begin
  select user_id into strict owner_id from public.staff_profiles
    where role='owner' and is_active order by user_id limit 1;
  select id into strict customer_id from public.customers order by id limit 1;
  insert into public.business_branches(branch_id,name_ar,name_en)
    values(branch_id,'اختبار دفع معزول','Isolated payment QA');
  insert into public.business_invoices(invoice_id,branch_id,service_name,total,payment_method)
    values(invoice_id,branch_id,'Isolated QA invoice',17.35,'cash_on_receipt')
    returning business_invoices.document_token into document_token;

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  perform public.open_cashier_shift(shift_id,branch_id,0);
  assert public.resolve_invoice_document(document_token)->>'payment_status'='unpaid',
    'Cash choice alone must not mark the invoice paid';

  rejected := false;
  begin
    perform public.record_shift_payment(gen_random_uuid(),shift_id,invoice_id,'sale','electronic');
  exception when insufficient_privilege then
    rejected := sqlerrm like 'Electronic payment requires verified gateway confirmation%';
  end;
  assert rejected, 'Manual electronic payment was accepted without gateway verification';
  assert public.resolve_invoice_document(document_token)->>'payment_status'='unpaid',
    'Rejected electronic attempt changed invoice payment state';
  raise notice 'PASS manual electronic payment rejected; invoice still unpaid';

  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  rejected := false;
  begin
    perform public.record_shift_payment(gen_random_uuid(),shift_id,invoice_id,'sale','cash');
  exception when raise_exception then
    rejected := sqlerrm='Shift access denied';
  end;
  assert rejected, 'Customer confirmed their own cash payment';

  execute 'set local role anon';
  rejected := false;
  begin
    perform public.record_shift_payment(gen_random_uuid(),shift_id,invoice_id,'sale','cash');
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'Anonymous payment RPC was executable';
  raise notice 'PASS customer/anonymous payment confirmation denied';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  assert public.record_shift_payment(payment_id,shift_id,invoice_id,'sale','cash')=payment_id;
  assert public.record_shift_payment(payment_id,shift_id,invoice_id,'sale','cash')=payment_id;
  assert public.record_shift_payment(gen_random_uuid(),shift_id,invoice_id,'sale','cash')=payment_id;
  assert public.resolve_invoice_document(document_token)->>'payment_status'='paid';
  assert (public.cashier_shift_totals(shift_id)->>'expected_cash')::numeric=17.35;
  raise notice 'PASS authorized cash confirmation once, server amount and paid invoice';

  execute 'reset role';
  -- Also reject privileged direct writes: no bypass via a different RPC/writer.
  rejected := false;
  begin
    insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id)
      values(gen_random_uuid(),shift_id,invoice_id,'refund','electronic',17.35,owner_id);
  exception when insufficient_privilege then
    rejected := sqlerrm like 'Electronic payment requires verified gateway confirmation%';
  end;
  assert rejected, 'Direct electronic ledger insertion bypassed verification';
  assert (select count(*)=1 from public.business_payment_events e where e.invoice_id=payment_confirmation_boundary.invoice_id);
  rejected := false;
  begin
    update public.business_payment_events e set method='electronic'
      where e.payment_id=payment_confirmation_boundary.payment_id;
  exception when insufficient_privilege then
    rejected := sqlerrm like 'Electronic payment requires verified gateway confirmation%';
  end;
  assert rejected, 'Cash ledger row was converted into an unverified electronic payment';
  execute 'set local role authenticated';
  perform public.record_shift_payment(gen_random_uuid(),shift_id,invoice_id,'refund','cash');
  assert public.resolve_invoice_document(document_token)->>'payment_status'='refunded';
  assert (public.cashier_shift_totals(shift_id)->>'expected_cash')::numeric=0;
  raise notice 'PASS direct insert/update blocked; existing cash refund path preserved';
  execute 'reset role';
end $$;
rollback;
