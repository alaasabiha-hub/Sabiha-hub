-- SOURCE ONLY: focused integration fixture, never run by its author.
-- Requires the NEW witness migration plus these pg_temp helpers. No old assertions.
-- Existing accepted setup reference:
-- typed_offline_reservation_actual_earning_refund.sql (real order/payment/work/kernel).
-- Root PostgreSQL-owner outer ROLLBACK only; there is no shipped runtime bypass.
begin;
\ir offline_reward_consumption_assertions.sql
-- The production CHECK forbids offline earning. To exercise this PRIVATE component
-- before activation, use the SAME test-owned transactional DDL as the accepted
-- real-earning fixture. No application API can execute this setup. ROLLBACK restores
-- the original constraint and false gate. Never COMMIT or run outside local QA.
do $$declare v_constraint record;begin
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton),'Expected shipped disabled earning gate';
 assert exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%'),'Original disabled CHECK required';
 for v_constraint in select conname from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%'loop
 execute format('alter table private.offline_service_visit_runtime drop constraint %I',v_constraint.conname);end loop;
end$$;
do $$
declare
 v_owner uuid;v_worker uuid;v_branch uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_offer uuid:=gen_random_uuid();v_policy uuid:=gen_random_uuid();v_rules uuid:=gen_random_uuid();v_channel uuid:=gen_random_uuid();v_activation uuid:=gen_random_uuid();
 v_intake jsonb;v_registration_consent jsonb;v_walkin_nonce uuid:=gen_random_uuid();v_result jsonb;v_order uuid;v_invoice text;v_shift uuid:=gen_random_uuid();v_stage text;v_work_nonce uuid;
 v_earning uuid;v_profile uuid;v_car uuid;v_reservation uuid:=gen_random_uuid();v_prepare_nonce uuid:=gen_random_uuid();v_hold jsonb;v_prepared jsonb;v_closed jsonb;v_original_witness jsonb;
 v_old_auth_hash text;v_old_employment_hash text;v_old_credit_ids uuid[];v_old_credit_hash text;v_rule_activation_count bigint;v_booking_activation_count bigint;v_local_now timestamp;
begin
 select s.user_id into strict v_owner from public.staff_profiles s where s.role='owner'and s.is_active and exists(select 1 from auth.sessions sess where sess.user_id=s.user_id and(sess.not_after is null or sess.not_after>clock_timestamp()))limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'session_id',(select sess.id from auth.sessions sess where sess.user_id=v_owner and(sess.not_after is null or sess.not_after>clock_timestamp())order by sess.created_at desc limit 1))::text,true);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 -- Select existing actually eligible staff; no new Auth account, HR contract,
 -- employment extension, salary/rate edit or immutable earning INSERT is allowed.
 select s.user_id into strict v_worker from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id
 where s.is_active and e.currency='EGP'and e.starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and(e.ends_on is null or e.ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date)
 order by s.user_id limit 1;
 v_local_now:=clock_timestamp()at time zone'Africa/Cairo';
 assert v_local_now::time<'23:50'::time,'Run within actual configured QA hours, never fake the clock';
 select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))into v_old_auth_hash from auth.users u;
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by staff_id),''))into v_old_employment_hash from private.hr_employment e;
 select array_agg(e.id),md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.id),''))into v_old_credit_ids,v_old_credit_hash from private.canonical_loyalty_visits e;
 select count(*)into v_rule_activation_count from private.reward_rule_activations;
 select count(*)into v_booking_activation_count from private.loyalty_visit_activations;
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert not has_function_privilege('authenticated','private.prepare_offline_reward_consumption(uuid,uuid,text)','EXECUTE');

 -- All configuration below is NEW and confined to the outer rollback.
 insert into public.business_branches(branch_id,name_ar,name_en)values(v_branch,'اختبار شاهد حجز مكافأة','QA consumption witness');
 update public.business_branch_hours set is_open=true,opens_at='00:00',closes_at='23:59'where branch_id=v_branch;
 assert exists(select 1 from public.business_branch_resources where branch_id=v_branch and resource_key='wash'and capacity>0),'Use actual configured capacity';
 if v_worker<>v_owner then insert into public.staff_branch_access(user_id,branch_id)values(v_worker,v_branch);end if;
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)
 values(v_service,v_branch,'service','QA actual witness source','sedan',120,5,'wash',true,true);
 insert into public.business_offers(offer_id,branch_id,name,offer_type,visits_required,reward_item_id,is_active,is_public)
 values(v_offer,v_branch,'QA exact visit witness benefit','visit_reward',1,v_service,true,true);
 v_registration_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 execute 'set local role authenticated';
 perform public.save_loyalty_policy(v_policy,v_branch,v_offer,array[v_service],true);
 perform public.save_loyalty_redemption_rules(v_rules,v_policy,null,'{"pooling":"policy_version","expiry":"no_expiry","cancellation":"restore_visits","refunded_contribution":"offset_future_visits"}');
 v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'QA consumption witness profile','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA WITNESS"}',v_registration_consent);
 execute 'reset role';
 v_profile:=(v_intake->>'offline_profile_id')::uuid;v_car:=(v_intake->>'car_ref_id')::uuid;
 insert into private.offline_visit_channel_versions(version_id,policy_version_id,rules_version_id,branch_id,eligible_service_ids,target_offline_profile_ids,enabled,terms_snapshot,created_by)
 select v_channel,p.version_id,r.rules_version_id,v_branch,array[v_service],array[v_profile],true,
 jsonb_build_object('unit','service_visits','source_channel','offline_walk_in','eligibility_basis','order_created_time','policy_snapshot',p.policy_snapshot,'rules',r.rules,'rules_terms_snapshot',r.terms_snapshot),v_owner
 from private.loyalty_policy_versions p join private.loyalty_redemption_rule_versions r on r.policy_version_id=p.version_id where p.version_id=v_policy and r.rules_version_id=v_rules;
 -- Exact accepted private component test setup, not an enable API or new gate.
 update private.offline_service_visit_runtime set earning_enabled=true where singleton;
 insert into private.offline_visit_channel_activations(activation_id,channel_version_id,activated_by)values(v_activation,v_channel,v_owner);

 -- ONE genuine typed walk-in, actual frozen invoice/worker lines, cash ledger and
 -- guarded physical work. No booking, fake Auth or direct credit writes.
 execute 'set local role authenticated';
 perform public.prepare_offline_walk_in(v_walkin_nonce,(v_intake->>'request_id')::uuid,v_service,120,v_owner,array[v_worker]);
 v_result:=public.place_offline_walk_in(v_walkin_nonce);perform public.ack_offline_walk_in_command(v_walkin_nonce);
 v_order:=(v_result#>>'{result,order_id}')::uuid;v_invoice:=v_result#>>'{result,invoice_id}';
 perform public.open_cashier_shift(v_shift,v_branch,0);
 perform public.record_shift_payment(gen_random_uuid(),v_shift,v_invoice,'sale','cash');
 foreach v_stage in array array['in_progress','quality_check','completed']loop
 v_work_nonce:=gen_random_uuid();perform public.prepare_service_work(v_work_nonce,v_order,case v_stage when'in_progress'then'received'when'quality_check'then'in_progress'else'quality_check'end,v_stage,'QA actual witness source work');
 perform public.place_service_work(v_work_nonce);perform public.ack_service_work_command(v_work_nonce);end loop;
 execute 'reset role';
 assert private.reconcile_loyalty_visit(v_order)='earned','Actual existing typed reconciler must earn the source';
 select e.id into strict v_earning from private.canonical_loyalty_visits e where e.order_id=v_order and e.kind='earn'and e.source_channel='offline_walk_in'and e.offline_profile_id=v_profile;
 assert exists(select 1 from public.business_orders o where o.order_id=v_order and o.booking_id is null and o.customer_id is null);
 -- New positive witness assertions ONLY. They release all their temporary holds.
 perform pg_temp.assert_offline_consumption_preparation(v_profile,v_car,v_channel,120);

 -- A fresh held source, with a stored witness, then ACTUAL cash refund. The new
 -- denial helper runs before reconciliation to prove direct financial recheck.
 v_hold:=private.reserve_offline_reward_candidates(v_reservation,v_profile,v_car,v_channel,120);
 v_prepared:=private.prepare_offline_reward_consumption(v_prepare_nonce,v_reservation,v_hold->>'fingerprint');
 assert(v_prepared->>'hold_current')::boolean;v_original_witness:=v_prepared->'witness';
 update private.offline_service_visit_runtime set earning_enabled=false where singleton;
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),v_shift,v_invoice,'refund','cash');execute 'reset role';
 assert not exists(select 1 from private.canonical_loyalty_visits where reverses_earning=v_earning),'Refund assertion must run before async reversal';
 perform pg_temp.assert_refunded_hold_cannot_prepare(v_reservation,v_hold->>'fingerprint');
 v_prepared:=private.get_offline_reward_consumption_preparation(v_prepare_nonce);
 assert v_prepared->>'state'='prepared'and not(v_prepared->>'hold_current')::boolean and v_prepared->'witness'=v_original_witness;
 v_closed:=private.close_offline_reward_consumption(v_prepare_nonce,'Actual refunded source invalidated private witness');
 assert v_closed->>'state'='closed';
 assert(select state from private.offline_reward_reservation_commands where request_id=v_reservation)='refunded';
 assert not exists(select 1 from private.reward_credit_claims where reserve_request_id=v_reservation and released_at is null);
 assert(select witness from private.offline_reward_consumption_preparations where request_id=v_prepare_nonce)=v_original_witness;
 assert(select coalesce(sum(case when event_type='sale'then amount else-amount end),0)from public.business_payment_events where invoice_id=v_invoice)=0;
 assert not exists(select 1 from private.service_reward_redemptions where offline_profile_id=v_profile),'Preparation must never issue coverage';
 assert not exists(select 1 from private.reward_refund_reviews where offline_profile_id=v_profile),'No consumed-debt fiction';
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert private.offline_service_visit_readiness()->>'earning_enabled'='false';
 assert private.offline_service_visit_readiness()->>'redemption_enabled'='false';
 assert private.offline_service_visit_readiness()->>'offline_wallet_access'='false';
 assert(select count(*)from private.reward_rule_activations)=v_rule_activation_count;
 assert(select count(*)from private.loyalty_visit_activations)=v_booking_activation_count;
 assert v_old_auth_hash=(select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u);
 assert v_old_employment_hash=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by staff_id),''))from private.hr_employment e);
 assert v_old_credit_hash=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.id),''))from private.canonical_loyalty_visits e where e.id=any(coalesce(v_old_credit_ids,'{}'::uuid[])));
 set constraints all immediate;
end$$;
rollback;
