-- Future legacy service-only reward compatibility. All fixtures roll back.
begin;
do $$
declare c uuid;owner_id uuid;offer uuid;oid uuid;hist uuid;invoice text;r record;i integer;balance bigint;
begin
 select id into strict c from public.customers order by id limit 1;
 select user_id into strict owner_id from public.staff_profiles where role='owner' and is_active limit 1;
 -- Test-only normalization uses additive ledger entries, never history deletes.
 select coalesce(sum(points),0) into balance from public.business_loyalty_transactions where customer_id=c;
 if balance<>0 then
  insert into public.business_loyalty_transactions(customer_id,points,reason) values(c,-balance,'QA isolated starting balance');
 end if;
 update public.business_offers set is_active=false where offer_type='visit_reward' and is_active;
 insert into public.business_offers(name,offer_type,visits_required,reward_value,is_active,is_public) values('QA isolated visit reward','visit_reward',3,0,true,true) returning offer_id into offer;
 for i in 1..4 loop
  oid:=gen_random_uuid();invoice:='QA-REWARD-'||oid;
  insert into public.business_orders(order_id,order_number,customer_id,service_name,status,order_type) values(oid,invoice,c,'QA service reward','completed','service');
  insert into public.business_invoices(invoice_id,order_id,service_name,total,discount,commission_total,commission_share,sale_type) values(invoice,oid,'QA service reward',120,30,15,7.5,'service');
  select * into r from public.finalize_service_loyalty(c,oid,invoice);assert r.reward_applied=(i=4);
  perform public.finalize_service_loyalty(c,oid,invoice);
  assert exists(select 1 from public.business_invoices where invoice_id=invoice and commission_total=15 and commission_share=7.5 and total+discount=150),'Reward/replay changed issued pre-discount commissions';
  if i=4 then
   update public.business_invoices set status='refunded' where invoice_id=invoice;
   perform public.reverse_service_loyalty(c,oid,invoice);perform public.reverse_service_loyalty(c,oid,invoice);
   assert exists(select 1 from public.business_invoices where invoice_id=invoice and total=0 and discount=150 and commission_total=15 and commission_share=7.5),'Refund changed commissions';
  end if;
 end loop;
 insert into private.managed_visit_reward_offers(offer_id,managed_by) values(offer,owner_id);
 oid:=gen_random_uuid();invoice:='QA-MANAGED-GUARD-'||oid;
 insert into public.business_orders(order_id,order_number,customer_id,service_name,status,order_type) values(oid,invoice,c,'Managed offer guard','completed','service');
 insert into public.business_invoices(invoice_id,order_id,service_name,total,discount,commission_total,commission_share,sale_type) values(invoice,oid,'Managed offer guard',120,30,15,7.5,'service');
 select * into r from public.finalize_service_loyalty(c,oid,invoice);assert not r.reward_applied;
 assert not exists(select 1 from public.business_loyalty_transactions where order_id=oid),'Managed offer minted legacy visits';
 assert exists(select 1 from public.business_invoices where invoice_id=invoice and total=120 and discount=30 and commission_total=15 and commission_share=7.5),'Managed offer mutated invoice';
 hist:=gen_random_uuid();invoice:='QA-HIST-REWARD-'||hist;
 insert into public.business_orders(order_id,order_number,customer_id,service_name,status,order_type) values(hist,invoice,c,'Historical zero fixture','completed','service');
 insert into public.business_invoices(invoice_id,order_id,service_name,total,discount,commission_total,commission_share,sale_type) values(invoice,hist,'Historical zero fixture',0,150,0,0,'service');
 insert into public.business_loyalty_transactions(customer_id,order_id,points,reason,offer_id) values(c,hist,-3,'Wash reward redeemed',offer);
 perform public.finalize_service_loyalty(c,hist,invoice);
 update public.business_invoices set status='refunded' where invoice_id=invoice;
 perform public.reverse_service_loyalty(c,hist,invoice);
 assert exists(select 1 from public.business_invoices where invoice_id=invoice and commission_total=0 and commission_share=0 and total=0 and discount=150),'Historical commission backfilled';
 raise notice 'PASS legacy issued commissions preserved on reward/replay/refund; historical zeros unchanged';
end;$$;
rollback;
