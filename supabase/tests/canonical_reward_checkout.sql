-- Root-run only as postgres, after A+B+reader migrations. Every fixture rolls back.
-- Private activation inserts below are isolated fixtures, not evidence of scheduled production readiness.
begin;
select pg_advisory_xact_lock(hashtextextended('canonical-loyalty-cron',0));
\ir reward_invoice_reader_assertions.sql
\ir reward_review_owner_references.sql
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

create function pg_temp.reward_earn(b uuid,s uuid,c uuid,own uuid,shift uuid)returns text language plpgsql as $$
declare bk uuid:=gen_random_uuid();ord uuid:=gen_random_uuid();inv text:='QA-REWARD-EARN-'||gen_random_uuid();begin
 perform pg_temp.prepare_visit(b,s,c,bk,ord,inv,'09:00');perform pg_temp.complete_visit(bk,ord);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,inv,'sale','cash');execute 'reset role';perform pg_temp.drain_visits();
 assert(select count(*)from private.canonical_loyalty_visits where invoice_id=inv and kind='earn')=1;return inv;
end $$;
do $$
<<qa>>
declare own uuid;c uuid;other uuid;br uuid;svc uuid;car uuid;offer uuid;policy uuid;rid uuid;shift uuid;source text;future_source text;request uuid;close_request uuid;quote_request uuid;second_request uuid;v jsonb;q jsonb;q2 jsonb;receipt jsonb;recovery jsonb;payload jsonb;rule jsonb;denied boolean;refund_request uuid;review uuid;before_hash text;legacy bigint;n integer;day date:=current_date+45;reward_booking uuid;reward_invoice text;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select id into strict c from public.customers where not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 select id into strict other from public.customers where id<>c and not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 select count(*)into legacy from public.business_loyalty_transactions;
 update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp()+interval '1 day'where processed_at is null;
 assert exists(select 1 from private.reward_runtime where singleton and booking_installed and readers_integrated),'All reader migration prerequisites required';
 for n in 1..4 loop
 br:=gen_random_uuid();svc:=gen_random_uuid();car:=gen_random_uuid();shift:=gen_random_uuid();rid:=gen_random_uuid();
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'اختبار استبدال معزول','Isolated reward QA');
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,price,is_active,is_public,duration_minutes)values(svc,br,'service','Synthetic reward service',100,true,true,30);
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(car,c,'QA','Reward','QA-'||car);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';
 v:=public.save_visit_reward_offer(gen_random_uuid(),br,'Explicit QA owner reward',1,true,svc);offer:=(v->>'offer_id')::uuid;execute 'reset role';
 update public.business_offers set ends_at=clock_timestamp()+interval '90 days'where offer_id=offer;
 execute 'set local role authenticated';v:=public.save_loyalty_policy(gen_random_uuid(),br,offer,array[svc],true);policy:=(v->>'version_id')::uuid;execute 'reset role';
 insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by)values(gen_random_uuid(),policy,own);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';perform public.open_cashier_shift(shift,br,0);execute 'reset role';
 source:=pg_temp.reward_earn(br,svc,c,own,shift); -- opened shift is required below; see helper fixture insertion
 rule:=jsonb_build_object('pooling',case when n%2=0 then 'offer_branch'else 'policy_version'end,'expiry',case when n%2=0 then 'snapshot_offer_end'else 'no_expiry'end,'cancellation',case when n<=2 then 'restore_visits'else 'forfeit_visits'end,'refunded_contribution',case when n%2=0 then 'freeze_for_owner_review'else 'offset_future_visits'end);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_loyalty_redemption_rules(rid,policy,null,rule);execute 'reset role';
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by)values(gen_random_uuid(),rid,own);
 perform pg_temp.assert_reward_reader_readiness(policy,own);
 if n=1 then perform pg_temp.assert_existing_legacy_reward_replay(c,br);end if;
 assert not exists(select 1 from private.reward_earning_terms t join private.canonical_loyalty_visits e on e.id=t.earning_id where e.invoice_id=source),'Pre-rule earnings silently adopted';
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';
 quote_request:=gen_random_uuid();q:=public.quote_service_reward(quote_request,svc,br,car,day,'10:00',policy,rid,null);assert(q->>'eligible')::boolean and(q->>'adoption_required')::boolean;
 q2:=public.quote_service_reward(gen_random_uuid(),svc,br,car,day+1,'10:00',policy,rid,null);assert(q2->>'eligible')::boolean;
 request:=gen_random_uuid();payload:=jsonb_build_object('p_quote',q->'quote_id','p_fingerprint',q->'fingerprint','p_accept_terms',true,'p_adopt_existing_visits',false);
 denied:=false;begin perform public.prepare_service_booking_attempt(request,'reward',payload);exception when invalid_parameter_value then denied:=true;end;assert denied,'Adoption consent bypassed';
 payload:=payload||jsonb_build_object('p_adopt_existing_visits',true);v:=public.prepare_service_booking_attempt(request,'reward',payload);assert v->>'state'='open';
 receipt:=public.place_customer_reward_booking(request,(q->>'quote_id')::uuid,q->>'fingerprint',true,true);assert receipt->>'payment_status'='covered_by_reward'and(receipt->>'amount_due')::numeric=0 and(receipt->>'gross_amount')::numeric=100;
 recovery:=public.get_service_booking_attempt(request);assert recovery->>'state'='succeeded'and recovery->'payload'=payload;
 assert public.place_customer_reward_booking(request,(q->>'quote_id')::uuid,q->>'fingerprint',true,true)->>'invoice_id'=receipt->>'invoice_id';
 v:=public.close_service_booking_attempt(request);assert v->>'state'='succeeded';perform public.acknowledge_service_booking_attempt(request);
 reward_booking:=(receipt->>'booking_id')::uuid;reward_invoice:=receipt->>'invoice_id';execute 'reset role';
 assert private.reward_invoice_coverage(reward_invoice)->>'state'='covered_by_reward';
 assert not has_function_privilege('authenticated','private.create_customer_service_booking(uuid,uuid,uuid,uuid,date,time,numeric,text,uuid,boolean)','execute'),'Authenticated role can forge internal coverage';
 denied:=false;begin insert into public.business_invoices(invoice_id,order_id,branch_id,total,discount,reward_snapshot)select 'QA-FORGED-'||gen_random_uuid(),order_id,branch_id,0,discount,reward_snapshot from public.business_invoices where invoice_id=reward_invoice;exception when insufficient_privilege then denied:=true;end;assert denied,'Raw writer forged backed coverage';
 denied:=false;begin update public.business_invoices set reward_snapshot=null where invoice_id=reward_invoice;exception when raise_exception then denied:=true;end;assert denied,'Issued coverage snapshot could be removed';

 perform pg_temp.assert_reward_invoice_readers(reward_invoice,c,own);
 perform pg_temp.assert_canonical_order_excludes_legacy(source,c);
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';
 v:=public.get_my_reward_wallet();assert exists(select 1 from jsonb_array_elements(v->'programs')p where p->>'rules_version_id'=rid::text and(p->>'unused_valid_visits')::integer=0);
 second_request:=gen_random_uuid();perform public.prepare_service_booking_attempt(second_request,'reward',jsonb_build_object('p_quote',q2->'quote_id','p_fingerprint',q2->'fingerprint','p_accept_terms',true,'p_adopt_existing_visits',true));
 denied:=false;begin perform public.place_customer_reward_booking(second_request,(q2->>'quote_id')::uuid,q2->>'fingerprint',true,true);exception when serialization_failure then denied:=true;end;assert denied,'Double spend succeeded';perform public.close_service_booking_attempt(second_request);
 close_request:=gen_random_uuid();v:=public.close_service_booking_attempt(close_request);assert v->>'state'='closed';
 denied:=false;begin perform public.place_customer_service_booking(close_request,svc,br,car,day+2,'10:00',100,null);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied,'Late normal request bypassed tombstone';
 denied:=false;begin perform public.place_customer_service_booking(request,svc,br,car,day,'10:00',100,null);exception when invalid_parameter_value then denied:=true;end;assert denied,'Reward nonce replayed in normal mode';
 execute 'reset role';perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,source,'refund','cash');execute 'reset role';
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';v:=public.get_my_reward_wallet();execute 'reset role';
 select review_id into strict review from private.reward_refund_reviews where redemption_id=(select redemption_id from private.service_reward_redemptions where invoice_id=reward_invoice);
 perform pg_temp.assert_reward_review_owner_references(own,c,br,review,reward_invoice);
 assert private.reward_program_blockers(c,rid)->>'eligible'='false','Actual refund was ignored until async reversal';
 if n%2=0 then
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.resolve_reward_refund_review(gen_random_uuid(),review,'QA explicit review, debt remains');execute 'reset role';
 assert private.reward_program_blockers(c,rid)->>'eligible'='false','Owner acknowledgement minted or waived debt';end if;
 future_source:=pg_temp.reward_earn(br,svc,c,own,shift);perform private.sync_customer_rewards(c);
 assert private.reward_program_blockers(c,rid)->>'eligible'='true','Actual future visit did not offset refund debt';
 assert exists(select 1 from private.reward_earning_terms t join private.canonical_loyalty_visits e on e.id=t.earning_id where e.invoice_id=future_source and t.rules_version_id=rid),'Future earning did not freeze activated rules';
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';v:=public.change_customer_booking(gen_random_uuid(),reward_booking,'cancel');execute 'reset role';
 assert private.reward_invoice_coverage(reward_invoice)->>'state'='cancelled_reward';
 perform pg_temp.assert_cancelled_reward_invoice_readers(reward_invoice,c,own);
 assert(select state from private.service_reward_redemptions where invoice_id=reward_invoice)=case when n<=2 then 'restored'else 'forfeited'end;
 assert(select count(*)from private.reward_program_lots(c,rid))=case when n<=2 then 1 else 0 end,'Cancellation minted refunded visits or violated forfeit';
 perform set_config('request.jwt.claim.sub',other::text,true);execute 'set local role authenticated';v:=public.get_service_booking_attempt(request);assert v->>'state'='absent','Other account recovered private receipt';execute 'reset role';
 end loop;
 assert(select count(*)from public.business_loyalty_transactions)=legacy,'Canonical redemption changed legacy balance';
 set constraints all immediate;
end $$;
rollback;
