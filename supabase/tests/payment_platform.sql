-- Isolated transactional acceptance of the NEW checkout boundary, rollback only.
begin;
do $$
<<qa>>
declare
  owner_id uuid;
  customer_id uuid;
  other_id uuid;
  cashier_id uuid;
  branch_id uuid := gen_random_uuid();
  car_id uuid := gen_random_uuid();
  other_car uuid := gen_random_uuid();
  request_id uuid := gen_random_uuid();
  shift_id uuid := gen_random_uuid();
  service_id uuid;
  offer_id uuid;
  result jsonb;
  repeated jsonb;
  saved jsonb;
  token uuid;
  day date := (now() at time zone 'Africa/Cairo')::date + 7;
  rejected boolean;
  policy uuid:=gen_random_uuid(); old_number text; counter_before bigint; intent jsonb; report jsonb; invoice text; cb text:=repeat('a',128);
begin
  select user_id into strict owner_id from public.staff_profiles where role='owner' and is_active limit 1;
  select c.id into strict customer_id from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id) order by c.id limit 1;
  select c.id into strict other_id from public.customers c where c.id<>customer_id and not exists(select 1 from public.staff_profiles s where s.user_id=c.id) order by c.id limit 1;
  select user_id into strict cashier_id from public.staff_profiles where role='employee' and is_active limit 1;
  update public.business_branches set is_default=false where is_default;
  insert into public.business_branches(branch_id,name_ar,name_en,is_default)
    values(branch_id,'فرع اختبار معزول','Isolated QA branch',true);
  insert into public.vehicles(id,customer_id,brand,model,plate_number) values
    (car_id,customer_id,'QA','Checkout','QA-'||car_id::text),
    (other_car,other_id,'QA','Other','QA-'||other_car::text);
  update public.staff_profiles set permissions=permissions||'{"cashier":true}'::jsonb where user_id=cashier_id;
  insert into public.staff_branch_access(user_id,branch_id) values(cashier_id,branch_id);

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  saved := public.save_service_promotion(gen_random_uuid(),
    jsonb_build_object('name','باقة اختبار معزولة','name_en','Isolated QA package',
      'price',137.45,'duration_minutes',45,'resource_key','wash','is_active',true,'is_public',true),
    jsonb_build_object('name','عرض اختبار معزول','name_en','Isolated QA offer',
      'category','package','compare_price',160,'is_active',true,'is_public',true));
  service_id := (saved->>'service_id')::uuid;
  offer_id := (saved->>'offer_id')::uuid;

  saved:=jsonb_build_object('gateway_percent',2.5,'gateway_fixed',3,'proposed_mode','equal');
  assert public.save_payment_policy(policy,'card',null,saved)=policy;
  assert public.save_payment_policy(policy,'card',null,saved)=policy;
  rejected:=false;
  begin perform public.save_payment_policy(policy,'cash',null,saved);exception when raise_exception then rejected:=true;end;
  assert rejected,'Policy retry allowed different payment method';
  rejected:=false;
  begin perform public.save_payment_policy(gen_random_uuid(),'card',policy,'{"customer_surcharge_enabled":true}');exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Card surcharge activated';
  raise notice 'PASS owner policy version, exact replay, method binding and surcharge block';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  rejected:=false;
  begin perform public.get_payment_policy_context();exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Customer reads owner payment policies';
  result:=public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,null);
  invoice:=result->>'invoice_id';
  repeated:=public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,null);
  assert repeated=result;
  execute 'reset role';
  select display_number into strict old_number from public.business_invoices where invoice_id=invoice;
  assert old_number ~ '^SH-INV-[0-9]{6,}$';
  assert (select display_number ~ '^SH-BKG-[0-9]{6,}$' from public.bookings where id=(result->>'booking_id')::uuid);
  select last_value into counter_before from private.document_number_counters where kind='INV';
  -- A retry of an existing invoice may not consume or replace its display number.
  insert into public.business_invoices select * from public.business_invoices where invoice_id=invoice on conflict(invoice_id) do nothing;
  assert (select last_value=counter_before from private.document_number_counters where kind='INV');
  rejected:=false;
  begin update public.business_invoices set display_number='SH-INV-999999' where invoice_id=invoice;exception when raise_exception then rejected:=true;end;
  assert rejected,'Invoice display number mutable';
  execute 'set local role authenticated';
  saved:=public.invoice_payment_quote(invoice);
  assert (saved->>'cash_total')::numeric=137.45 and saved->>'card_total'=saved->>'cash_total' and (saved->>'customer_fee')::numeric=0;
  assert saved->'policy'->'versions'->'card'->>'version_id'=policy::text;
  assert not ((saved->'policy'->'versions'->'card') ? 'gateway_percent'),'Internal merchant fee exposed';
  assert exists(select 1 from jsonb_array_elements(public.search_invoice_documents(old_number)) x where x->>'invoice_id'=invoice);
  raise notice 'PASS sequential numbers, immutable display, retry counter, searchable number and equal-price snapshot';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.save_payment_policy(gen_random_uuid(),'card',policy,'{"gateway_percent":4,"gateway_fixed":7}');
  assert public.invoice_payment_quote(invoice)->'policy'=saved->'policy','Existing invoice policy changed';
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  rejected:=false;
  begin perform public.invoice_payment_quote(invoice);exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Another customer reads quote';
  assert not exists(select 1 from jsonb_array_elements(public.search_invoice_documents(old_number)) x where x->>'invoice_id'=invoice);
  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  intent:=public.reserve_paymob_sandbox(gen_random_uuid(),invoice);
  assert (intent->>'claimed')::boolean and (intent->>'amount_cents')::bigint=13745;
  repeated:=public.reserve_paymob_sandbox(gen_random_uuid(),invoice);
  assert repeated->>'intent_id'=intent->>'intent_id' and not (repeated->>'claimed')::boolean;
  rejected:=false;
  begin perform public.attach_paymob_sandbox((intent->>'intent_id')::uuid,'qa-order','qa-intention','https://accept.paymob.com/unifiedcheckout/?qa');exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Customer called privileged gateway function';
  execute 'set local role service_role';
  perform public.attach_paymob_sandbox((intent->>'intent_id')::uuid,'qa-order','qa-intention','https://accept.paymob.com/unifiedcheckout/?qa');
  rejected:=false;
  begin perform public.accept_paymob_sandbox_callback('qa-order','qa-tx',1,'EGP','sandbox_succeeded',cb);exception when raise_exception then rejected:=true;end;
  assert rejected,'Callback accepted wrong amount';
  saved:=public.accept_paymob_sandbox_callback('qa-order','qa-tx',13745,'EGP','sandbox_succeeded',cb);
  assert saved->>'real_collection_recorded'='false';
  perform public.accept_paymob_sandbox_callback('qa-order','qa-tx',13745,'EGP','sandbox_succeeded',cb);
  saved:=public.accept_paymob_sandbox_callback('qa-order','qa-tx',13745,'EGP','failed',repeat('b',128));
  assert saved->>'status'='sandbox_succeeded','Late failure reversed success';
  saved:=public.accept_paymob_sandbox_callback('qa-order','qa-tx',13745,'EGP','refund_reported',repeat('c',128));
  saved:=public.accept_paymob_sandbox_callback('qa-order','qa-tx',13745,'EGP','sandbox_succeeded',cb);
  assert saved->>'status'='refund_reported','Replay reversed refund';
  execute 'reset role';
  assert (select count(*)=3 from private.paymob_callbacks where intent_id=(intent->>'intent_id')::uuid),'Callback replay duplicated audit';
  assert not exists(select 1 from public.business_payment_events where invoice_id=invoice),'Sandbox created real collection';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  report:=public.get_ai_payment_analytics(current_date,current_date);
  assert report->'summary'->>'cash_share_percent' is null and report->'summary'->>'net_collections' is null,'Incomplete card coverage presented as total';
  assert report->>'sandbox_excluded'='true' and (report->'summary'->>'cash_collections')::numeric=0 and report->'summary'->>'actual_profit' is null;
  perform set_config('request.jwt.claim.sub',cashier_id::text,true);
  rejected:=false;
  begin perform public.get_ai_payment_analytics(current_date,current_date);exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Cashier accessed owner analytics';
  rejected:=false;
  begin perform public.save_payment_policy(gen_random_uuid(),'cash',null,'{}');exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Cashier changed payment policy';
  raise notice 'PASS gateway server-only, exact amount, callbacks replay/terminal status, no real money and owner analytics scope';
  execute 'reset role';
end;
$$;
rollback;
