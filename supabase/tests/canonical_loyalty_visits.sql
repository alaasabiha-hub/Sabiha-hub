-- Root-run, rollback only. Synthetic private activation is a core-engine fixture;
-- it does not claim an observed cron run or enable a persistent policy.
begin;
select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));
create temp table qa_loyalty_fixture(marker boolean);
create function pg_temp.prepare_visit(b uuid,s uuid,c uuid,bk uuid,ord uuid,inv text,slot time) returns void language plpgsql as $$begin
 insert into public.bookings(id,customer_id,service_name,booking_date,booking_time,catalog_item_id,branch_id) values(bk,c,'Synthetic canonical visit',current_date+14,slot,s,b);
 insert into public.business_orders(order_id,order_number,customer_id,booking_id,branch_id,service_name,order_type,status) values(ord,'QA-VISIT-'||ord,c,bk,b,'Synthetic canonical visit','service','received');
 insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total,discount,commission_total,sale_type,status) values(inv,ord,b,'Synthetic canonical visit',80,20,10,'service','active');
end $$;
create function pg_temp.complete_visit(bk uuid,ord uuid) returns void language plpgsql as $$begin
 update public.bookings set status='confirmed' where id=bk and status='pending';update public.bookings set status='in_progress' where id=bk and status='confirmed';update public.bookings set status='completed' where id=bk and status='in_progress';
 update public.business_orders set status='in_progress' where order_id=ord and status='received';update public.business_orders set status='quality_check' where order_id=ord and status='in_progress';update public.business_orders set status='completed' where order_id=ord and status='quality_check';
end $$;
create function pg_temp.drain_visits() returns void language plpgsql as $$declare n integer:=0;v jsonb;begin
 loop exit when not exists(select 1 from private.loyalty_visit_outbox where processed_at is null and next_attempt_at<=clock_timestamp());n:=n+1;if n>200 then raise exception 'Unexpected queue loop';end if;v:=public.drain_loyalty_visit_event();end loop;
end $$;
create function pg_temp.poison_visit_insert() returns trigger language plpgsql as $$begin if new.kind='earn' and new.order_id::text=current_setting('qa.poison_visit_order',true) then raise exception 'Synthetic isolated poison event';end if;return new;end $$;
create trigger qa_poison_visit before insert on private.canonical_loyalty_visits for each row execute function pg_temp.poison_visit_insert();
do $$
<<qa>>
declare own uuid;customer uuid;other_customer uuid;branch uuid:=gen_random_uuid();service uuid:=gen_random_uuid();offer uuid;policy uuid;activation uuid:=gen_random_uuid();shift uuid:=gen_random_uuid();denied boolean;v jsonb;repeat_result jsonb;invoice_hash text;legacy_count bigint;baseline bigint;other_baseline bigint;
 old_b uuid:=gen_random_uuid();old_o uuid:=gen_random_uuid();old_i text:='QA-VISIT-OLD-'||gen_random_uuid();
 paid_b uuid:=gen_random_uuid();paid_o uuid:=gen_random_uuid();paid_i text:='QA-VISIT-PAID-'||gen_random_uuid();
 completed_b uuid:=gen_random_uuid();completed_o uuid:=gen_random_uuid();completed_i text:='QA-VISIT-COMPLETE-'||gen_random_uuid();
 refunded_b uuid:=gen_random_uuid();refunded_o uuid:=gen_random_uuid();refunded_i text:='QA-VISIT-REFUND-'||gen_random_uuid();
 poison_b uuid:=gen_random_uuid();poison_o uuid:=gen_random_uuid();poison_i text:='QA-VISIT-POISON-'||gen_random_uuid();
 good_b uuid:=gen_random_uuid();good_o uuid:=gen_random_uuid();good_i text:='QA-VISIT-GOOD-'||gen_random_uuid();refund_request uuid:=gen_random_uuid();
begin
 select user_id into strict own from public.staff_profiles where role='owner' and is_active limit 1;
 select c.id into strict customer from public.customers c where not exists(select 1 from public.staff_profiles s where s.user_id=c.id) order by c.id limit 1;
 select c.id into strict other_customer from public.customers c where c.id<>customer and not exists(select 1 from public.staff_profiles s where s.user_id=c.id) order by c.id limit 1;
 select coalesce(sum(visits),0) into baseline from private.canonical_loyalty_visits where customer_id=customer;
 select coalesce(sum(visits),0) into other_baseline from private.canonical_loyalty_visits where customer_id=other_customer;
 select count(*) into legacy_count from public.business_loyalty_transactions;
 -- Isolate ready work temporarily; rollback restores any preexisting queue rows.
 update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp()+interval '1 day' where processed_at is null;
 insert into public.business_branches(branch_id,name_ar,name_en) values(branch,'اختبار زيارات معزول','Isolated visit QA');
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,category,price,is_active,is_public) values(service,branch,'service','Synthetic canonical service','QA',100,true,true);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';
 v:=public.save_visit_reward_offer(gen_random_uuid(),branch,'Owner configured QA visit terms',7,true,service);offer:=(v->>'offer_id')::uuid;
 v:=public.save_loyalty_policy(gen_random_uuid(),branch,offer,array[service],true);policy:=(v->>'version_id')::uuid;
 execute 'reset role';update private.loyalty_visit_runtime set scheduler_configured=false where singleton;
 execute 'set local role authenticated';denied:=false;begin perform public.activate_loyalty_visits(activation,policy);exception when raise_exception then denied:=true;end;assert denied,'Unconfigured scheduler activated earning';
 execute 'reset role';perform pg_temp.prepare_visit(branch,service,customer,old_b,old_o,old_i,'10:00');
 assert not exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=old_b),'Old foundation snapshot acquired earning binding';
 -- Register metadata transactionally but intentionally make real-run evidence absent.
 perform cron.schedule('canonical-loyalty-visits','* * * * *','select private.run_loyalty_visit_cron();');
 update private.loyalty_visit_runtime set scheduler_configured=true,installed_at=clock_timestamp()+interval '1 day' where singleton;
 execute 'set local role authenticated';denied:=false;begin perform public.activate_loyalty_visits(activation,policy);exception when raise_exception then denied:=true;end;assert denied,'Job metadata alone enabled earning';
 execute 'reset role';insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by) values(activation,policy,own);
 execute 'set local role authenticated';v:=public.activate_loyalty_visits(activation,policy);repeat_result:=public.activate_loyalty_visits(activation,policy);assert v=repeat_result,'Committed activation retry failed after scheduler became stale';
 perform public.open_cashier_shift(shift,branch,0);execute 'reset role';
 -- Payment first: method selection alone and confirmed cash alone do not award completion.
 perform pg_temp.prepare_visit(branch,service,customer,paid_b,paid_o,paid_i,'11:00');
 assert exists(select 1 from private.loyalty_earning_snapshot_bindings where booking_id=paid_b and customer_id=customer and activation_id=activation),'New visible activation was not frozen';
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,paid_i,'sale','cash');execute 'reset role';
 perform pg_temp.drain_visits();assert not exists(select 1 from private.canonical_loyalty_visits where order_id=paid_o),'Paid incomplete service earned a visit';
 perform pg_temp.complete_visit(paid_b,paid_o);
 select md5(row_to_json(i)::text) into invoice_hash from public.business_invoices i where invoice_id=paid_i;
 perform pg_temp.drain_visits();assert (select count(*) from private.canonical_loyalty_visits where order_id=paid_o and kind='earn')=1;
 assert (select md5(row_to_json(i)::text) from public.business_invoices i where invoice_id=paid_i)=invoice_hash,'Earning mutated invoice/discount/commission';
 -- Completion first, duplicate invoices fail closed, then actual cash and resolution.
 perform pg_temp.prepare_visit(branch,service,customer,completed_b,completed_o,completed_i,'12:00');perform pg_temp.complete_visit(completed_b,completed_o);
 update public.business_invoices set payment_method='cash' where invoice_id=completed_i;
 perform pg_temp.drain_visits();assert not exists(select 1 from private.canonical_loyalty_visits where order_id=completed_o),'Unpaid completed service earned';
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,completed_i,'sale','cash');execute 'reset role';
 insert into public.business_invoices(invoice_id,order_id,branch_id,service_name,total,sale_type) values(completed_i||'-DUP',completed_o,branch,'Synthetic duplicate',80,'service');
 perform pg_temp.drain_visits();assert not exists(select 1 from private.canonical_loyalty_visits where order_id=completed_o),'Duplicate invoice association earned';
 update public.business_invoices set status='void' where invoice_id=completed_i||'-DUP';perform pg_temp.drain_visits();assert (select count(*) from private.canonical_loyalty_visits where order_id=completed_o and kind='earn')=1;
 -- Refund before first processing yields neither award nor negative visit.
 perform pg_temp.prepare_visit(branch,service,customer,refunded_b,refunded_o,refunded_i,'13:00');perform pg_temp.complete_visit(refunded_b,refunded_o);
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,refunded_i,'sale','cash');perform public.record_shift_payment(gen_random_uuid(),shift,refunded_i,'refund','cash');execute 'reset role';perform pg_temp.drain_visits();
 assert not exists(select 1 from private.canonical_loyalty_visits where order_id=refunded_o),'Pre-earned refund created visits';
 -- A source identity edit cannot move a frozen customer award to a different account.
 update public.business_orders set customer_id=other_customer where order_id=old_o;perform pg_temp.complete_visit(old_b,old_o);perform pg_temp.drain_visits();assert not exists(select 1 from private.canonical_loyalty_visits where order_id=old_o),'Historical snapshot silently earned';
 -- Owner/client boundaries and own-only summary, never legacy points.
 perform set_config('request.jwt.claim.sub',customer::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',customer,'user_metadata',jsonb_build_object('role','owner'))::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.drain_loyalty_visit_event();exception when insufficient_privilege then denied:=true;end;assert denied,'Customer metadata ran system worker';
 denied:=false;begin perform public.get_loyalty_visit_lifecycle(branch);exception when insufficient_privilege then denied:=true;end;assert denied,'Customer read owner context';
 denied:=false;begin perform public.activate_loyalty_visits(gen_random_uuid(),policy);exception when insufficient_privilege then denied:=true;end;assert denied,'Customer activated earning';
 v:=public.get_my_canonical_service_visits();assert (v->>'net_visits')::bigint=baseline+2 and v->>'legacy_imported'='false' and v->>'redemption_enabled'='false';
 perform set_config('request.jwt.claim.sub',other_customer::text,true);v:=public.get_my_canonical_service_visits();assert (v->>'net_visits')::bigint=other_baseline,'Own summary leaked another customer visits';
 execute 'reset role';perform set_config('request.jwt.claim.sub',own::text,true);
 -- Poison work backs off and does not starve the next ready event.
 perform pg_temp.prepare_visit(branch,service,customer,poison_b,poison_o,poison_i,'14:00');perform pg_temp.complete_visit(poison_b,poison_o);
 perform pg_temp.prepare_visit(branch,service,customer,good_b,good_o,good_i,'15:00');perform pg_temp.complete_visit(good_b,good_o);
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,poison_i,'sale','cash');perform public.record_shift_payment(gen_random_uuid(),shift,good_i,'sale','cash');execute 'reset role';
 update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp()+interval '1 day' where processed_at is null;
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,booking_id,next_attempt_at,created_at) values('qa_poison',gen_random_uuid(),poison_o,poison_b,clock_timestamp()-interval '1 second',clock_timestamp()-interval '2 seconds'),('qa_good',gen_random_uuid(),good_o,good_b,clock_timestamp(),clock_timestamp());
 perform set_config('qa.poison_visit_order',poison_o::text,true);v:=public.drain_loyalty_visit_event();assert v->>'retry'='true';
 assert exists(select 1 from private.loyalty_visit_outbox where source_kind='qa_poison' and processed_at is null and next_attempt_at>=clock_timestamp()+interval '119 seconds'),'Poison event did not back off';
 v:=public.drain_loyalty_visit_event();assert v->>'result'='earned';assert exists(select 1 from private.canonical_loyalty_visits where order_id=good_o and kind='earn'),'Poison starved later ready work';
 -- Refund is an immutable reversal of the original earning, including during pause.
 update private.loyalty_visit_runtime set scheduler_configured=false where singleton;
 execute 'set local role authenticated';perform public.record_shift_payment(refund_request,shift,paid_i,'refund','cash');perform public.record_shift_payment(refund_request,shift,paid_i,'refund','cash');execute 'reset role';
 perform pg_temp.drain_visits();assert (select count(*) from private.canonical_loyalty_visits where order_id=paid_o and kind='refund')=1,'Refund duplicated or was lost when earning paused';
 assert (select sum(visits) from private.canonical_loyalty_visits where order_id=paid_o)=0;
 denied:=false;begin update private.canonical_loyalty_visits set visits=2 where order_id=paid_o;exception when raise_exception then denied:=true;end;assert denied,'Canonical history changed';
 assert (select count(*) from public.business_loyalty_transactions)=legacy_count,'Canonical engine mixed legacy ledger';
 execute 'set local role anon';denied:=false;begin perform public.get_my_canonical_service_visits();exception when insufficient_privilege then denied:=true;end;assert denied,'Anonymous canonical summary';
 execute 'reset role';update public.staff_profiles set is_active=false where user_id=own;execute 'set local role authenticated';denied:=false;begin perform public.activate_loyalty_visits(activation,policy);exception when insufficient_privilege then denied:=true;end;assert denied,'Revoked owner replayed activation';
 raise notice 'PASS canonical eligibility, both sequential fact orders, frozen future binding, cash-only/idempotent award, refund reversal, poison retry fairness and authorization; real concurrency/cron acceptance is separate';
end $$;
rollback;
