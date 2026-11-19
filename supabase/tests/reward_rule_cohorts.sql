-- Targeted rollback only after preserve_reward_rule_cohort_order; root runs as postgres.
-- Synthetic private activations isolate predicates; no activation/adoption is persisted.
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
declare own uuid;c uuid;other uuid;br uuid:=gen_random_uuid();svc uuid:=gen_random_uuid();car uuid:=gen_random_uuid();other_car uuid:=gen_random_uuid();shift uuid:=gen_random_uuid();offer uuid;policy uuid;policy2 uuid;pooled_rule uuid:=gen_random_uuid();old_rule uuid:=gen_random_uuid();new_rule uuid:=gen_random_uuid();pre_source text;old_source text;new_source text;other_source text;old_credit uuid;new_credit uuid;pre_credit uuid;other_credit uuid;v jsonb;old_rules jsonb;new_rules jsonb;terms jsonb;q jsonb;other_q jsonb;old_q jsonb;receipt jsonb;payload jsonb;request uuid:=gen_random_uuid();expiry timestamptz;day date:=current_date+45;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select id into strict c from public.customers where not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 select id into strict other from public.customers where id<>c and not exists(select 1 from public.staff_profiles s where s.user_id=customers.id)limit 1;
 update private.loyalty_visit_outbox set next_attempt_at=clock_timestamp()+interval '1 day'where processed_at is null;
 insert into public.business_branches(branch_id,name_ar,name_en)values(br,'اختبار مجموعات الشروط','Rule cohort QA');
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,price,is_active,is_public,duration_minutes)values(svc,br,'service','Synthetic cohort service',100,true,true,30);
 insert into public.vehicles(id,customer_id,brand,model,plate_number)values(car,c,'QA','Cohort','QA-'||car),(other_car,other,'QA','Cohort','QA-'||other_car);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_visit_reward_offer(gen_random_uuid(),br,'Explicit cohort test',1,true,svc);offer:=(v->>'offer_id')::uuid;execute 'reset role';
 update public.business_offers set ends_at=clock_timestamp()+interval '90 days'where offer_id=offer;
 execute 'set local role authenticated';v:=public.save_loyalty_policy(gen_random_uuid(),br,offer,array[svc],true);policy:=(v->>'version_id')::uuid;perform public.open_cashier_shift(shift,br,0);execute 'reset role';
 insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by)values(gen_random_uuid(),policy,own);
 pre_source:=pg_temp.reward_earn(br,svc,c,own,shift);
 old_rules:=jsonb_build_object('pooling','policy_version','expiry','snapshot_offer_end','cancellation','restore_visits','refunded_contribution','offset_future_visits');
 new_rules:=jsonb_build_object('pooling','policy_version','expiry','no_expiry','cancellation','forfeit_visits','refunded_contribution','freeze_for_owner_review');
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_loyalty_redemption_rules(old_rule,policy,null,old_rules);execute 'reset role';
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by)values(gen_random_uuid(),old_rule,own);
 old_source:=pg_temp.reward_earn(br,svc,c,own,shift);
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_loyalty_redemption_rules(new_rule,policy,old_rule,new_rules);execute 'reset role';
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by)values(gen_random_uuid(),new_rule,own);
 new_source:=pg_temp.reward_earn(br,svc,c,own,shift);other_source:=pg_temp.reward_earn(br,svc,other,own,shift);
 select id into strict old_credit from private.canonical_loyalty_visits where invoice_id=old_source and kind='earn';select id into strict new_credit from private.canonical_loyalty_visits where invoice_id=new_source and kind='earn';select id into strict pre_credit from private.canonical_loyalty_visits where invoice_id=pre_source and kind='earn';select id into strict other_credit from private.canonical_loyalty_visits where invoice_id=other_source and kind='earn';
 assert(select rules_version_id from private.reward_earning_terms where earning_id=old_credit)=old_rule;
 assert(select rules_version_id from private.reward_earning_terms where earning_id=new_credit)=new_rule;
 assert not exists(select 1 from private.reward_earning_terms where earning_id=pre_credit),'Pre-rule history was automatically adopted';
 terms:=private.reward_credit_terms(new_credit,old_rule);assert terms->>'valid'='false'and terms->>'reason'='newer_bound_rules_required','Old lenient rule consumed newer bound credit';
 terms:=private.reward_credit_terms(old_credit,new_rule);select(terms_snapshot#>>'{offer,ends_at}')::timestamptz into expiry from private.loyalty_redemption_rule_versions where rules_version_id=old_rule;
 assert terms->>'valid'='true'and(terms->>'expires_at')::timestamptz=expiry and terms->>'effective_rules_version_id'=old_rule::text,'New selected program rewrote original credit expiry';
 assert private.reward_credit_terms(pre_credit,old_rule)->>'reason'='latest_activated_rules_required_for_adoption';
 terms:=private.reward_credit_terms(pre_credit,new_rule);assert terms->>'valid'='true'and terms->>'adoption_required'='true';
 assert(select count(*)from private.reward_program_lots(c,old_rule))=1,'Older program includes a newer-bound or unbound cohort';
 perform set_config('request.jwt.claim.sub',other::text,true);execute 'set local role authenticated';
 other_q:=public.quote_service_reward(gen_random_uuid(),svc,br,other_car,day,'11:00',policy,old_rule,null);assert other_q->>'eligible'='false'and other_q->>'reason'='insufficient_actual_eligible_visits','Older actual quote accepted only newer credits';
 other_q:=public.quote_service_reward(gen_random_uuid(),svc,br,other_car,day,'11:00',policy,new_rule,null);assert other_q->>'eligible'='true';
 perform set_config('request.jwt.claim.sub',c::text,true);
 old_q:=public.quote_service_reward(gen_random_uuid(),svc,br,car,day,'10:00',policy,old_rule,null);assert old_q->>'eligible'='true','Old cohort lost its old program';
 q:=public.quote_service_reward(gen_random_uuid(),svc,br,car,day,'10:00',policy,new_rule,null);assert q->>'eligible'='true'and q->'earning_ids'=jsonb_build_array(old_credit)and q#>>'{terms_snapshot,rules,cancellation}'='forfeit_visits','New program did not quote an older actual lot with explicit future terms';
 assert(q#>>'{allocation_snapshot,0,credit_terms,expires_at}')::timestamptz=expiry;
 payload:=jsonb_build_object('p_quote',q->'quote_id','p_fingerprint',q->'fingerprint','p_accept_terms',true,'p_adopt_existing_visits',false);v:=public.prepare_service_booking_attempt(request,'reward',payload);
 receipt:=public.place_customer_reward_booking(request,(q->>'quote_id')::uuid,q->>'fingerprint',true,false);assert receipt->>'payment_status'='covered_by_reward'and receipt->'rules'=new_rules;execute 'reset role';
 assert(select rules_version_id from private.reward_earning_terms where earning_id=old_credit)=old_rule,'Redeeming changed immutable original rules';
 assert not exists(select 1 from private.reward_earning_terms where earning_id=pre_credit),'Unselected pre-rule credit was adopted';
 assert(private.reward_credit_terms(old_credit,new_rule)->>'expires_at')::timestamptz=expiry;
 -- A later policy can explicitly pool older-policy credits only for the same offer+branch.
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';v:=public.save_loyalty_policy(gen_random_uuid(),br,offer,array[svc],true);policy2:=(v->>'version_id')::uuid;v:=public.save_loyalty_redemption_rules(pooled_rule,policy2,null,new_rules||jsonb_build_object('pooling','offer_branch'));execute 'reset role';
 insert into private.loyalty_visit_activations(activation_id,policy_version_id,activated_by)values(gen_random_uuid(),policy2,own);
 insert into private.reward_rule_activations(request_id,rules_version_id,activated_by)values(gen_random_uuid(),pooled_rule,own);
 assert exists(select 1 from private.reward_program_lots(c,pooled_rule)where earning_id=new_credit),'Explicit offer/branch pooling lost older-policy credits';
 assert private.reward_credit_terms(pre_credit,pooled_rule)->>'adoption_required'='true','Selected newer-policy latest rules cannot explicitly adopt older pre-rule history';
 perform set_config('request.jwt.claim.sub',other::text,true);execute 'set local role authenticated';other_q:=public.quote_service_reward(gen_random_uuid(),svc,br,other_car,day+1,'11:00',policy2,pooled_rule,null);assert other_q->>'eligible'='true'and other_q->'earning_ids'=jsonb_build_array(other_credit),'Actual newer-policy pooled quote rejected an older-policy bound lot';execute 'reset role';
 set constraints all immediate;
end $$;
rollback;
