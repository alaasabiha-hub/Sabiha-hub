-- Rollback-only local acceptance; requires existing synthetic customer accounts.
begin;
do $$
<<qa>>
declare c uuid;other uuid;br uuid:=gen_random_uuid();car uuid:=gen_random_uuid();svc uuid:=gen_random_uuid();b uuid;inv text;r uuid:=gen_random_uuid();x jsonb;y jsonb;rejected boolean;day date:=(now() at time zone 'Africa/Cairo')::date+30;
begin
 select id into strict c from public.customers where not exists(select 1 from public.staff_profiles s where s.user_id=customers.id) limit 1;
 select id into strict other from public.customers where id<>c and not exists(select 1 from public.staff_profiles s where s.user_id=customers.id) limit 1;
 insert into public.business_branches(branch_id,name_ar,name_en) values(br,'اختبار تعديل','Change QA');
 insert into public.vehicles(id,customer_id,brand,model,plate_number) values(car,c,'QA','Change','QA-'||car);
 insert into public.business_catalog_items(item_id,branch_id,name,item_type,price,is_active,is_public,duration_minutes) values(svc,br,'Change QA','service',123,true,true,30);
 perform set_config('request.jwt.claim.sub',c::text,true);
 execute 'set local role authenticated';
 x:=public.place_customer_service_booking(gen_random_uuid(),svc,br,car,day,'10:00',123,null);b:=(x->>'booking_id')::uuid;inv:=x->>'invoice_id';
 perform set_config('request.jwt.claim.sub',other::text,true);
 rejected:=false;begin perform public.change_customer_booking(r,b,'cancel');exception when insufficient_privilege then rejected:=true;end;assert rejected,'Other customer allowed';
 perform set_config('request.jwt.claim.sub',c::text,true);
 x:=public.change_customer_booking(r,b,'reschedule',day+1,'11:00');
 y:=public.change_customer_booking(r,b,'reschedule',day+1,'11:00');assert x=y,'Retry changed result';
 rejected:=false;begin perform public.change_customer_booking(r,b,'cancel');exception when invalid_parameter_value then rejected:=true;end;assert rejected,'Changed payload reused';
 execute 'reset role';
 assert (select quoted_price=123 and booking_date=day+1 from public.bookings where id=b),'Price/appointment incorrect';
 insert into private.paymob_intents(intent_id,invoice_id,created_by,amount_cents,status) values(gen_random_uuid(),inv,c,12300,'uncertain');
 execute 'set local role authenticated';
 rejected:=false;begin perform public.change_customer_booking(gen_random_uuid(),b,'cancel');exception when others then rejected:=sqlerrm like 'Payment recorded or unresolved%';end;assert rejected,'Uncertain gateway allowed cancellation';
 execute 'reset role';delete from private.paymob_intents where invoice_id=inv;
 insert into public.business_cashier_shifts(shift_id,branch_id,cashier_id,opening_cash)
 select gen_random_uuid(),br,user_id,0 from public.staff_profiles where role='owner' and is_active limit 1;
 insert into public.business_payment_events(payment_id,shift_id,invoice_id,event_type,method,amount,actor_id)
 select gen_random_uuid(),shift_id,inv,'sale','cash',123,c from public.business_cashier_shifts where branch_id=br limit 1;
 execute 'set local role authenticated';
 rejected:=false;begin perform public.change_customer_booking(gen_random_uuid(),b,'reschedule',day+3,'11:00');exception when others then rejected:=sqlerrm like 'Payment recorded or unresolved%';end;assert rejected,'Paid booking allowed';
 execute 'reset role';
 delete from public.business_payment_events where invoice_id=inv;

 update public.bookings set status='confirmed' where id=b;
 execute 'set local role authenticated';rejected:=false;begin perform public.change_customer_booking(gen_random_uuid(),b,'cancel');exception when others then rejected:=sqlerrm like 'Only future pending%';end;assert rejected,'Confirmed booking allowed';
 execute 'reset role';
 -- New pending visit independently verifies atomic cancellation and stable retry.
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';
 x:=public.place_customer_service_booking(gen_random_uuid(),svc,br,car,day+2,'10:00',123,null);b:=(x->>'booking_id')::uuid;inv:=x->>'invoice_id';r:=gen_random_uuid();
 x:=public.change_customer_booking(r,b,'cancel');y:=public.change_customer_booking(r,b,'cancel');assert x=y;
 execute 'reset role';
 assert (select status='cancelled' from public.bookings where id=b);
 assert (select status='cancelled' from public.business_orders where booking_id=b);
 assert (select status='void' from public.business_invoices where invoice_id=inv);
 assert exists(select 1 from public.business_audit_log where entity_id=b::text and action='customer_booking_cancel' and before_data is not null and after_data is not null);
 raise notice 'PASS customer ownership, reschedule price, request identity, unresolved gateway, confirmed guard, atomic cancellation and audit';
end;$$;
rollback;
