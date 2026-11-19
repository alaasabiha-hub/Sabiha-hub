-- Root-run rollback-only acceptance for customer-facing targeted-terms copies.
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
create function pg_temp.reward_earn(b uuid,s uuid,c uuid,own uuid,shift uuid)returns text language plpgsql as $$
declare bk uuid:=gen_random_uuid();ord uuid:=gen_random_uuid();inv text:='QA-REWARD-EARN-'||gen_random_uuid();begin
 perform pg_temp.prepare_visit(b,s,c,bk,ord,inv,'09:00');perform pg_temp.complete_visit(bk,ord);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),shift,inv,'sale','cash');execute 'reset role';perform pg_temp.drain_visits();
 assert(select count(*)from private.canonical_loyalty_visits where invoice_id=inv and kind='earn')=1;return inv;
end $$;

do $$
<<qa>>
declare own uuid;c uuid;other uuid;excluded uuid;br uuid:=gen_random_uuid();svc uuid:=gen_random_uuid();car uuid:=gen_random_uuid();excluded_car uuid:=gen_random_uuid();shift uuid:=gen_random_uuid();offer uuid;policy uuid;rules_id uuid:=gen_random_uuid();quote_id uuid:=gen_random_uuid();request_id uuid:=gen_random_uuid();source text;v jsonb;q jsonb;replay jsonb;view jsonb;receipt jsonb;payload jsonb;private_quote private.service_reward_quotes;private_hash text;safe jsonb;day date:=current_date+45;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select id into strict c from public.customers where not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 select id into strict other from public.customers where id<>c and not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 select id into strict excluded from public.customers where id<>c and id<>other limit 1;
 update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp()+interval '1 day'where processed_at is null;
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'اختبار خصوصية الشروط','Targeted privacy QA');
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,price,is_active,is_public,duration_minutes)values(svc,br,'service','Synthetic privacy service',100,true,true,30);
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(car,c,'QA','Privacy','QA-'||car),(excluded_car,excluded,'QA','Privacy','QA-'||excluded_car);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_visit_reward_offer(gen_random_uuid(),br,'Explicit targeted QA reward',1,true,svc);offer:=(v->>'offer_id')::uuid;execute 'reset role';
 -- Existing targeting metadata is frozen through actual owner policy/rule RPCs.
 update public.business_offers set target_customer_ids=array[c,other]where offer_id=offer;
 execute 'set local role authenticated';v:=public.save_loyalty_policy(gen_random_uuid(),br,offer,array[svc],true);policy:=(v->>'version_id')::uuid;perform public.open_cashier_shift(shift,br,0);v:=public.save_loyalty_redemption_rules(rules_id,policy,null,jsonb_build_object('pooling','policy_version','expiry','no_expiry','cancellation','restore_visits','refunded_contribution','offset_future_visits'));execute 'reset role';
 insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by)values(gen_random_uuid(),policy,own);
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by)values(gen_random_uuid(),rules_id,own);
 source:=pg_temp.reward_earn(br,svc,c,own,shift);
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';
 v:=public.get_service_reward_options(svc,br);assert jsonb_array_length(v->'programs')=1 and position(other::text in v::text)=0 and position(excluded::text in v::text)=0,'Options leaked another targeted customer';
 q:=public.quote_service_reward(quote_id,svc,br,car,day,'10:00',policy,rules_id,'Synthetic own privacy note');assert q->>'eligible'='true'and position(other::text in q::text)=0 and position(excluded::text in q::text)=0,'Quote leaked targeted identities';
 assert not(q->'terms_snapshot'?'target_customer_ids')and(q#>'{allocation_snapshot,0,credit_terms}')-array['valid','expires_at','adoption_required','original_rules_version_id','effective_rules_version_id']='{}'::jsonb,'Customer copy has unexpected private fields';
 replay:=public.quote_service_reward(quote_id,svc,br,car,day,'10:00',policy,rules_id,'Synthetic own privacy note');assert replay->>'fingerprint'=q->>'fingerprint'and position(other::text in replay::text)=0;
 payload:=jsonb_build_object('p_quote',quote_id,'p_fingerprint',q->>'fingerprint','p_accept_terms',true,'p_adopt_existing_visits',false);
 view:=public.prepare_service_booking_attempt(request_id,'reward',payload);assert view->>'state'='open'and view#>>'{form_context,fingerprint}'=q->>'fingerprint'and position(other::text in view::text)=0;
 view:=public.get_service_booking_attempt(request_id);assert view->>'state'='open'and position(other::text in view::text)=0 and not(view#>'{form_context,terms_snapshot}'?'target_customer_ids');
 view:=public.get_customer_reward_booking(request_id);assert position(other::text in view::text)=0;
 v:=public.get_my_reward_wallet();assert position(other::text in v::text)=0 and position(excluded::text in v::text)=0,'Own wallet leaked audience identities';execute 'reset role';
 select * into strict private_quote from private.service_reward_quotes where service_reward_quotes.quote_id=qa.quote_id;
 assert private_quote.terms_snapshot->'target_customer_ids'=to_jsonb(array[c,other]),'Sanitizer rewrote immutable private terms';
 private_hash:=md5(to_jsonb(private_quote)::text);assert private_quote.fingerprint=q->>'fingerprint';
 safe:=private.customer_reward_terms(private_quote.terms_snapshot||jsonb_build_object('internal_target_ids',array[other],'offer',(private_quote.terms_snapshot->'offer')||jsonb_build_object('internal_target_ids',array[excluded]),'reward_service',(private_quote.terms_snapshot->'reward_service')||jsonb_build_object('internal_target_ids',array[other])));
 assert position(other::text in safe::text)=0 and position(excluded::text in safe::text)=0,'Nested unknown metadata escaped explicit whitelist';
 perform set_config('request.jwt.claim.sub',other::text,true);execute 'set local role authenticated';v:=public.get_service_reward_options(svc,br);assert jsonb_array_length(v->'programs')=1 and position(c::text in v::text)=0,'Included audience member lost access or saw another member';
 perform set_config('request.jwt.claim.sub',excluded::text,true);v:=public.get_service_reward_options(svc,br);assert v->'programs'='[]'::jsonb,'Audience exclusion changed';
 v:=public.quote_service_reward(gen_random_uuid(),svc,br,excluded_car,day,'11:00',policy,rules_id,null);assert v->>'eligible'='false'and v->>'reason'='actual_activated_reward_terms_required';
 perform set_config('request.jwt.claim.sub',c::text,true);receipt:=public.place_customer_reward_booking(request_id,quote_id,q->>'fingerprint',true,false);assert receipt->>'payment_status'='covered_by_reward'and(receipt->>'amount_due')::numeric=0 and position(other::text in receipt::text)=0;
 view:=public.get_service_booking_attempt(request_id);assert view->>'state'='succeeded'and position(other::text in view::text)=0;execute 'reset role';
 assert(select md5(to_jsonb(stored)::text)from private.service_reward_quotes stored where stored.quote_id=qa.quote_id)=private_hash,'Public response or placement mutated private quote/fingerprint';
 assert(select terms_snapshot->'target_customer_ids'from private.loyalty_redemption_rule_versions where rules_version_id=rules_id)=to_jsonb(array[c,other]);
 set constraints all immediate;
end $$;
rollback;
