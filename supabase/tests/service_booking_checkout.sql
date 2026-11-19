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
  execute 'set local role anon';
  assert exists(select 1 from jsonb_array_elements(public.get_public_promotions()->'offers') x
    where x->>'offer_id'=offer_id::text and (x->>'price')::numeric=137.45
      and (x->>'service_id')::uuid=service_id and x->>'name_en'='Isolated QA offer');
  raise notice 'PASS owner publication, anonymous published catalog and actual bilingual price';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,null);
  exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Anonymous booking allowed';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  assert exists(select 1 from public.available_booking_slots(branch_id,service_id,day) where slot_time='10:00');
  rejected:=false;
  begin
    insert into public.bookings(customer_id,service_name,vehicle_id,catalog_item_id,booking_date,booking_time)
      values(customer_id,'QA bypass',car_id,service_id,day,'10:00');
  exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Raw booking insert bypassed atomic invoice creation';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,other_car,day,'10:00',137.45,null);
  exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Another customer vehicle accepted';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,car_id,day,'10:00',1,null);
  exception when serialization_failure then rejected:=true;end;
  assert rejected,'Client invented price accepted';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,car_id,day,'03:00',137.45,null);
  exception when raise_exception then rejected:=sqlerrm='Appointment outside opening hours';end;
  assert rejected,'Out-of-hours booking accepted';
  result:=public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,' QA note ');
  repeated:=public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,'QA note');
  assert result=repeated,'Repeated request duplicated checkout';
  execute 'reset role';
  assert (select count(*)=1 from public.bookings b where b.id=(result->>'booking_id')::uuid and b.customer_id=qa.customer_id and b.quoted_price=137.45);
  assert (select count(*)=1 from public.business_orders o where o.order_id=(result->>'order_id')::uuid and o.booking_id=(result->>'booking_id')::uuid);
  assert (select count(*)=1 from public.business_invoices i where i.invoice_id=result->>'invoice_id' and i.order_id=(result->>'order_id')::uuid and i.total=137.45);
  execute 'set local role authenticated';
  saved:=public.list_invoice_documents();
  select (x->>'document_token')::uuid into strict token from jsonb_array_elements(saved) x where x->>'invoice_id'=result->>'invoice_id';
  saved:=public.resolve_invoice_document(token);
  assert saved->>'payment_status'='unpaid';
  assert saved->>'booking_id'=result->>'booking_id';
  assert saved->>'vehicle_id'=car_id::text;
  assert (saved->'snapshot'->>'total')::numeric=137.45;
  assert (saved->'snapshot'->'lines'->0->>'unit_price')::numeric=137.45;
  select x into strict saved from jsonb_array_elements(public.get_customer_booking_history()) x where x->>'id'=result->>'booking_id';
  assert saved->>'invoice_token'=token::text;
  assert saved->>'payment_status'='unpaid';
  assert saved->'vehicle'->>'plate_number'='QA-'||car_id::text;
  assert (saved->>'quoted_price')::numeric=137.45;
  raise notice 'PASS booking/order/invoice linked atomically, actual snapshot and unpaid receipt';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'11:00',137.45,'QA note');
  exception when invalid_parameter_value then rejected:=true;end;
  assert rejected,'Changed payload reused a request';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,car_id,day,'10:15',137.45,null);
  exception when raise_exception then rejected:=sqlerrm='Vehicle already booked in this interval';end;
  assert rejected,'Overlapping duplicate booking accepted';

  -- Failure late in the transaction cannot leave a booking or an invoice parent.
  execute 'reset role';
  execute 'create function pg_temp.reject_qa_invoice() returns trigger language plpgsql as $t$ begin raise exception ''QA invoice failure''; end; $t$';
  execute 'create trigger qa_invoice_failure before insert on public.business_invoices for each row execute function pg_temp.reject_qa_invoice()';
  execute 'set local role authenticated';
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,car_id,day,'12:00',137.45,null);
  exception when raise_exception then rejected:=sqlerrm='QA invoice failure';end;
  assert rejected,'Late failure not reached';
  assert (select count(*)=1 from public.bookings b where b.branch_id=qa.branch_id);
  assert (select count(*)=1 from public.business_orders o where o.branch_id=qa.branch_id);
  raise notice 'PASS request mismatch, vehicle conflict and late failure atomic rollback';

  execute 'reset role';
  update public.business_catalog_items c set price=146.25 where c.item_id=service_id;
  execute 'set local role authenticated';
  assert public.place_customer_service_booking(request_id,service_id,branch_id,car_id,day,'10:00',137.45,'QA note')=result;
  assert (public.resolve_invoice_document(token)->'snapshot'->>'total')::numeric=137.45;
  rejected:=false;
  begin
    perform public.place_customer_service_booking(gen_random_uuid(),service_id,branch_id,car_id,day,'14:00',137.45,null);
  exception when serialization_failure then rejected:=true;end;
  assert rejected,'Stale price accepted after catalog changed';
  raise notice 'PASS existing booking price stays immutable; new stale-price request rejected';

  perform set_config('request.jwt.claim.sub',other_id::text,true);
  assert not exists(select 1 from jsonb_array_elements(public.get_customer_booking_history()) x where x->>'id'=result->>'booking_id');
  assert not exists(select 1 from public.bookings b where b.id=(result->>'booking_id')::uuid);
  assert not exists(select 1 from public.business_invoices i where i.invoice_id=result->>'invoice_id');
  rejected:=false;
  begin perform public.resolve_invoice_document(token);exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Another customer resolved an invoice QR';
  rejected:=false;
  begin perform public.get_owner_promotions();exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Customer entered owner catalog';

  perform set_config('request.jwt.claim.sub',cashier_id::text,true);
  rejected:=false;
  begin perform public.get_owner_promotions();exception when insufficient_privilege then rejected:=true;end;
  assert rejected,'Cashier entered owner catalog';
  perform public.open_cashier_shift(shift_id,branch_id,0);
  assert exists(select 1 from jsonb_array_elements(public.shift_invoice_options(branch_id)) x where x->>'invoice_id'=result->>'invoice_id');
  perform public.record_shift_payment(gen_random_uuid(),shift_id,result->>'invoice_id','sale','cash');
  assert public.resolve_invoice_document(token)->>'payment_status'='paid';
  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  assert public.resolve_invoice_document(token)->>'payment_status'='paid';
  assert exists(select 1 from jsonb_array_elements(public.get_customer_booking_history()) x where x->>'id'=result->>'booking_id' and x->>'payment_status'='paid');
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  assert public.resolve_invoice_document(token)->>'payment_status'='paid';
  raise notice 'PASS customer isolation, owner access and authorized cashier confirmation';
  execute 'reset role';
  -- Simulate a historical manual electronic row, not a new gateway success.
  -- Privileged fixture setup is transactional; immediately restore the guard.
  execute 'alter table public.business_payment_events disable trigger require_verified_electronic_payment';
  execute 'alter table public.business_invoices disable trigger qa_invoice_failure';
  insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total,payment_method,issued_at)
    values('QA-LEGACY-'||request_id::text,(result->>'order_id')::uuid,branch_id,'Isolated historical electronic QA',137.45,'electronic',clock_timestamp())
    returning document_token into token;
  insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id)
    values(gen_random_uuid(),shift_id,'QA-LEGACY-'||request_id::text,'sale','electronic',137.45,cashier_id);
  execute 'alter table public.business_payment_events enable trigger require_verified_electronic_payment';
  execute 'alter table public.business_invoices enable trigger qa_invoice_failure';
  perform set_config('request.jwt.claim.sub',customer_id::text,true);
  execute 'set local role authenticated';
  assert public.resolve_invoice_document(token)->>'payment_status'='verification_required';
  assert exists(select 1 from jsonb_array_elements(public.get_customer_booking_history()) x where x->>'id'=result->>'booking_id' and x->>'payment_status'='verification_required');
  raise notice 'PASS own history enrichment and historical electronic status never treated as verified paid';
  execute 'reset role';
end $$;
rollback;
