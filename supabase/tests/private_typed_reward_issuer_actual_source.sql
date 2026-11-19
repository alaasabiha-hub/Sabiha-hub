-- SOURCE ONLY, never executed by author. Root must explicitly supply existing QA
-- UUIDs via psql -v qa_customer_id=... -v qa_other_customer_id=... (no secrets).
-- No Auth/phone/role/quota edit. No fabricated link/credit. Ordinary claim caps.
-- Same accepted actual-earning test-owned DDL method inside one outer ROLLBACK.
\if :{?qa_customer_id}
\else
\echo 'Missing explicit existing QA customer UUID'
\quit 3
\endif
\if :{?qa_other_customer_id}
\else
\echo 'Missing explicit existing other QA customer UUID'
\quit 3
\endif
begin;
\ir private_typed_reward_issuer_assertions.sql
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
\if :{?qa_cancel_rule}
\else
\set qa_cancel_rule restore_visits
\endif
\if :{?qa_refund_rule}
\else
\set qa_refund_rule offset_future_visits
\endif
select set_config('qa.cancel_rule', :'qa_cancel_rule', true);
select set_config('qa.refund_rule', :'qa_refund_rule', true);
select set_config('qa.financial_customer', :'qa_customer_id', true);
select set_config('qa.financial_other_customer', :'qa_other_customer_id', true);
do $$
declare
 v_owner uuid;v_worker uuid;v_branch uuid:=gen_random_uuid();v_service uuid:=gen_random_uuid();v_offer uuid:=gen_random_uuid();v_policy uuid:=gen_random_uuid();v_rules uuid:=gen_random_uuid();v_channel uuid:=gen_random_uuid();v_activation uuid:=gen_random_uuid();
 v_intake jsonb;v_registration_consent jsonb;v_walkin_nonce uuid:=gen_random_uuid();v_result jsonb;v_order uuid;v_invoice text;v_shift uuid:=gen_random_uuid();v_stage text;v_work_nonce uuid;
 v_earning uuid;v_profile uuid;v_car uuid;v_reservation uuid:=gen_random_uuid();v_prepare_nonce uuid:=gen_random_uuid();v_hold jsonb;v_prepared jsonb;v_closed jsonb;v_original_witness jsonb;
 v_reward_a jsonb;v_reward_b jsonb;v_source_b jsonb;v_source_c jsonb;v_delayed_source jsonb;v_delayed_earning uuid;v_target_source text;v_target_earning uuid;v_redemption uuid;v_review uuid;v_snapshot_before jsonb;v_refund_count bigint;v_offset_count bigint;v_payment record;v_abort_issue uuid:=gen_random_uuid();v_before_invoice_count bigint;v_stage_work uuid;
 v_customer uuid:=current_setting('qa.financial_customer')::uuid;v_other uuid:=current_setting('qa.financial_other_customer')::uuid;v_customer_session uuid;v_phone text;v_owner_claims text;v_claim uuid:=gen_random_uuid();v_decision uuid:=gen_random_uuid();v_link uuid;v_link_revoke uuid:=gen_random_uuid();v_proposal uuid:=gen_random_uuid();v_consent_nonce uuid;v_claim_consent jsonb;v_claim_result jsonb;v_secret text;v_receipt uuid;v_decision_result jsonb;v_denied boolean;v_customer_claims text;v_claim_hour bigint;v_claim_day bigint;
 v_old_auth_hash text;v_old_employment_hash text;v_old_credit_ids uuid[];v_old_credit_hash text;v_rule_activation_count bigint;v_booking_activation_count bigint;v_local_now timestamp;
begin
 select s.user_id into strict v_owner from public.staff_profiles s where s.role='owner'and s.is_active and exists(select 1 from auth.sessions sess where sess.user_id=s.user_id and(sess.not_after is null or sess.not_after>clock_timestamp()))limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'session_id',(select sess.id from auth.sessions sess where sess.user_id=v_owner and(sess.not_after is null or sess.not_after>clock_timestamp())order by sess.created_at desc limit 1))::text,true);
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_owner_claims:=current_setting('request.jwt.claims');
 assert v_customer<>v_other and v_customer<>v_owner and v_other<>v_owner;
 select c.phone into strict v_phone from public.customers c join auth.users u on u.id=c.id where c.id=v_customer and u.email_confirmed_at is not null and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and private.offline_phone_key(c.phone,'EG')is not null;
 assert not exists(select 1 from public.staff_profiles where user_id in(v_customer,v_other)and is_active),'Use actual non-staff QA customers';
 assert not exists(select 1 from private.offline_customer_trusted_links where auth_user_id=v_customer and revoked_at is null),'Choose explicitly reviewed QA actor with no existing active link; never revoke an old link';
 select id into strict v_customer_session from auth.sessions where user_id=v_customer and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1;
 assert exists(select 1 from auth.sessions sess join auth.users u on u.id=sess.user_id join public.customers c on c.id=u.id where u.id=v_other and u.email_confirmed_at is not null and u.deleted_at is null and(sess.not_after is null or sess.not_after>clock_timestamp()));
 select count(*)filter(where created_at>clock_timestamp()-interval'1 hour'),count(*)into v_claim_hour,v_claim_day from private.offline_claim_requests where actor_id=v_customer and created_at>clock_timestamp()-interval'1 day';
 assert v_claim_hour<5 and v_claim_day<20,'Ordinary claim budget exhausted: wait; never reset or bypass limits';
 v_customer_claims:=jsonb_build_object('sub',v_customer,'session_id',v_customer_session)::text;
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
 insert into public.staff_branch_access(user_id,branch_id)values(v_worker,v_branch);
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)
 values(v_service,v_branch,'service','QA actual witness source','sedan',120,5,'wash',true,true);
 insert into public.business_offers(offer_id,branch_id,name,offer_type,visits_required,reward_item_id,is_active,is_public)
 values(v_offer,v_branch,'QA exact visit witness benefit','visit_reward',1,v_service,true,true);
 v_registration_consent:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 execute 'set local role authenticated';
 perform public.save_loyalty_policy(v_policy,v_branch,v_offer,array[v_service],true);
 perform public.save_loyalty_redemption_rules(v_rules,v_policy,null,jsonb_build_object('pooling','policy_version','expiry','no_expiry','cancellation',current_setting('qa.cancel_rule'),'refunded_contribution',current_setting('qa.refund_rule')));
 v_intake:=public.register_offline_customer(gen_random_uuid(),v_branch,'QA financial consent profile',v_phone,'EG','{"plate_number":"QA FINANCE"}',v_registration_consent,'create_separate','Explicit QA separate reception record with genuine original receipt proof');
 execute 'reset role';
 v_profile:=(v_intake->>'offline_profile_id')::uuid;v_car:=(v_intake->>'car_ref_id')::uuid;
 assert v_intake->>'status'='created_unverified';
 v_secret:=v_intake->>'enrollment_secret';v_receipt:=(v_intake->>'enrollment_receipt_id')::uuid;
 assert v_secret~'^[0-9a-f]{64}$';
 -- Original receipt secret stays solely in SQL memory, never a notice/log/result.
 v_claim_consent:=jsonb_build_object('accepted',true,'version','offline-claim-v1','language','en','text',private.offline_claim_notice('en'));
 perform set_config('request.jwt.claims',v_customer_claims,true);perform set_config('request.jwt.claim.sub',v_customer::text,true);
 execute 'set local role authenticated';
 v_claim_result:=public.request_offline_customer_claim(v_claim,v_receipt,v_secret,'original_receipt',v_claim_consent);
 execute 'reset role';v_secret:=null;v_intake:=v_intake-'enrollment_secret';
 assert exists(select 1 from private.offline_claim_requests where request_id=v_claim and actor_id=v_customer and profile_id=v_profile and secret_proved and outcome='pending_owner_review');
 perform set_config('request.jwt.claims',v_owner_claims,true);perform set_config('request.jwt.claim.sub',v_owner::text,true);
 execute 'set local role authenticated';
 perform public.prepare_offline_claim_command(v_decision,'decide',jsonb_build_object('p_claim',v_claim,'p_decision','approve_with_secret','p_reason','QA independent owner review of actual original receipt proof','p_evidence_type',null));
 v_decision_result:=public.decide_offline_customer_claim(v_decision,v_claim,'approve_with_secret','QA independent owner review of actual original receipt proof',null);
 execute 'reset role';v_link:=(v_decision_result->>'link_id')::uuid;
 assert exists(select 1 from private.offline_customer_trusted_links where link_id=v_link and auth_user_id=v_customer and profile_id=v_profile and revoked_at is null);

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
 -- New private issuer cases ONLY, using genuine held earned credits and actual
 -- independently signed-in linked customer financial assent.
 assert(select kernel_installed and not public_enabled from private.offline_reward_issuer_runtime where singleton);
 v_reward_a:=pg_temp.issue_actual_offline_reward(v_profile,v_car,v_channel,(v_intake->>'request_id')::uuid,v_worker,v_customer,v_shift);
 select document_snapshot into v_snapshot_before from public.business_invoices where invoice_id=v_reward_a->>'invoice_id';
 perform private.cancel_offline_reward_issue(gen_random_uuid(),(v_reward_a->>'issue_request_id')::uuid,'QA received reward cancellation under frozen explicit rule');
 assert(private.reward_invoice_coverage(v_reward_a->>'invoice_id')->>'state')='cancelled_reward';
 assert(select document_snapshot from public.business_invoices where invoice_id=v_reward_a->>'invoice_id')=v_snapshot_before,'Cancellation must preserve original covered document/QR';
 assert(private.invoice_payment_quote(v_reward_a->>'invoice_id')->>'payment_status')='cancelled';
 assert(select state from private.service_reward_redemptions where redemption_id=(v_reward_a->>'redemption_id')::uuid)=case current_setting('qa.cancel_rule')when'restore_visits'then'restored'else'forfeited'end;
 if current_setting('qa.cancel_rule')='restore_visits'then
 assert not exists(select 1 from private.reward_credit_claims where redemption_id=(v_reward_a->>'redemption_id')::uuid and released_at is null);
 else assert exists(select 1 from private.reward_credit_claims where redemption_id=(v_reward_a->>'redemption_id')::uuid and released_at is null);end if;
 set constraints all immediate;set constraints all deferred;
 -- Fresh genuine credit makes the forfeit case independently spendable; in the
 -- restore case FIFO may correctly reuse its restored original-expiry credit.
 v_source_b:=pg_temp.make_actual_offline_source((v_intake->>'request_id')::uuid,v_service,v_worker,v_shift);
 v_reward_b:=pg_temp.issue_actual_offline_reward(v_profile,v_car,v_channel,(v_intake->>'request_id')::uuid,v_worker,v_customer,v_shift);
 execute 'set local role authenticated';
 foreach v_stage in array array['in_progress','quality_check','completed']loop v_stage_work:=gen_random_uuid();
 perform public.prepare_service_work(v_stage_work,(v_reward_b->>'order_id')::uuid,case v_stage when'in_progress'then'received'when'quality_check'then'in_progress'else'quality_check'end,v_stage,'QA actual reward service work');perform public.place_service_work(v_stage_work);perform public.ack_service_work_command(v_stage_work);end loop;execute 'reset role';
 assert private.reconcile_loyalty_visit((v_reward_b->>'order_id')::uuid)<>'earned';
 assert not exists(select 1 from private.canonical_loyalty_visits where order_id=(v_reward_b->>'order_id')::uuid),'No reward-on-reward earning';
 assert exists(select 1 from public.business_invoices invoice join public.business_orders orders using(order_id)join private.offline_walk_in_commissions frozen on frozen.invoice_id=invoice.invoice_id where invoice.invoice_id=v_reward_b->>'invoice_id'and orders.status='completed'and invoice.status='active'and invoice.total+invoice.discount=frozen.gross and frozen.amount=round(frozen.gross*frozen.rate_percent/100/frozen.assigned_count,2)),'Actual HR completed-active predicate retains frozen gross commission without cash';
 -- Complete/pay a genuine service BEFORE refund, deliberately postpone its
 -- canonical worker until AFTER refund. No clock edit/backdating/fake credit.
 v_delayed_source:=pg_temp.make_actual_offline_source((v_intake->>'request_id')::uuid,v_service,v_worker,v_shift,false);
 v_redemption:=(v_reward_b->>'redemption_id')::uuid;
 select earning_id into strict v_target_earning from private.reward_credit_claims where redemption_id=v_redemption and kind='reward';
 select invoice_id into strict v_target_source from private.canonical_loyalty_visits where id=v_target_earning;
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),v_shift,v_target_source,'refund','cash');execute 'reset role';
 assert private.reconcile_loyalty_visit((v_delayed_source->>'order_id')::uuid)='earned';
 select id into strict v_delayed_earning from private.canonical_loyalty_visits where order_id=(v_delayed_source->>'order_id')::uuid and kind='earn';
 assert(select created_at from private.canonical_loyalty_visits where id=v_delayed_earning)>(select event.created_at from private.loyalty_visit_outbox event join public.business_payment_events payment on payment.payment_id=event.source_id where event.source_kind='business_payment_events'and payment.invoice_id=v_target_source and payment.event_type='refund'),'Worker actually ran after refund';
 assert private.offline_reward_credit_qualified_at(v_delayed_earning)<(select event.created_at from private.loyalty_visit_outbox event join public.business_payment_events payment on payment.payment_id=event.source_id where event.source_kind='business_payment_events'and payment.invoice_id=v_target_source and payment.event_type='refund');
 perform private.sync_offline_profile_rewards(v_profile);
 select review_id into strict v_review from private.reward_refund_reviews where redemption_id=v_redemption and original_claim_id=(select claim_id from private.reward_credit_claims where redemption_id=v_redemption and earning_id=v_target_earning and kind='reward');
 select count(*)into v_refund_count from private.reward_refund_reviews where redemption_id=v_redemption;
 perform private.sync_offline_profile_rewards(v_profile);assert(select count(*)from private.reward_refund_reviews where redemption_id=v_redemption)=v_refund_count,'Consumed refund review exactly once';
 assert not private.offline_reward_debt_clear(v_profile,v_rules);
 assert not exists(select 1 from private.reward_credit_claims where debt_id=v_review and earning_id=v_delayed_earning),'Worker latency must never turn a pre-refund visit into future offset';
 assert private.reward_invoice_coverage(v_reward_b->>'invoice_id')->>'state'='covered_by_reward','Issued benefit honored; no retroactive customer charge';
 assert not exists(select 1 from public.business_payment_events where invoice_id=v_reward_b->>'invoice_id');
 -- Only a genuine credit earned AFTER actual refund can repay this review.
 v_source_c:=pg_temp.make_actual_offline_source((v_intake->>'request_id')::uuid,v_service,v_worker,v_shift);
 perform private.sync_offline_profile_rewards(v_profile);
 if current_setting('qa.refund_rule')='freeze_for_owner_review'then
 assert not private.offline_reward_debt_clear(v_profile,v_rules);
 assert not exists(select 1 from private.reward_credit_claims where debt_id=v_review),'Freeze cannot silently offset before explicit owner review';
 v_denied:=false;begin perform private.reserve_offline_reward_candidates(gen_random_uuid(),v_profile,v_car,v_channel,120);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 perform private.resolve_offline_reward_refund_review(gen_random_uuid(),v_review,'Explicit QA acknowledgement without debt waiver');
 end if;
 assert private.offline_reward_debt_clear(v_profile,v_rules),'Actual future visit must repay, never waive debt';
 assert exists(select 1 from private.reward_credit_claims where debt_id=v_review and earning_id=(v_source_c->>'earning_id')::uuid and kind='offset'and released_at is null);
 select count(*)into v_offset_count from private.reward_credit_claims where debt_id=v_review;
 perform private.sync_offline_profile_rewards(v_profile);assert(select count(*)from private.reward_credit_claims where debt_id=v_review)=v_offset_count,'Same actual offset cannot duplicate';
 assert not exists(select 1 from private.reward_credit_claims where earning_id=(v_source_c->>'earning_id')::uuid and kind='reward'and released_at is null),'Debt repayment cannot also spend';
 -- Refund BEFORE consume after a valid prepare: no order/invoice/receipt can
 -- escape, and close must definitively resolve only that exact attempt.
 v_source_c:=pg_temp.make_actual_offline_source((v_intake->>'request_id')::uuid,v_service,v_worker,v_shift);
 v_reservation:=gen_random_uuid();v_prepare_nonce:=gen_random_uuid();v_proposal:=gen_random_uuid();v_hold:=private.reserve_offline_reward_candidates(v_reservation,v_profile,v_car,v_channel,120);
 perform private.prepare_offline_reward_consumption(v_prepare_nonce,v_reservation,v_hold->>'fingerprint');
 perform private.propose_offline_reward_financial_consent(v_proposal,v_prepare_nonce);
 v_consent_nonce:=pg_temp.record_actual_reward_assent(v_customer,v_proposal);
 perform private.prepare_offline_reward_issue(v_abort_issue,v_prepare_nonce,v_consent_nonce,(v_intake->>'request_id')::uuid,array[v_worker]);
 select invoice_id into strict v_target_source from private.canonical_loyalty_visits where id=(select earning_ids[1]from private.service_reward_quotes where quote_id=(v_hold->>'quote_id')::uuid);
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),v_shift,v_target_source,'refund','cash');execute 'reset role';
 select count(*)into v_before_invoice_count from public.business_invoices;
 v_denied:=false;begin perform private.place_offline_reward_issue(v_abort_issue);exception when object_not_in_prerequisite_state then v_denied:=true;end;assert v_denied;
 assert(select count(*)from public.business_invoices)=v_before_invoice_count;
 assert private.close_offline_reward_issue(v_abort_issue)->>'state'='closed';perform private.ack_offline_reward_issue(v_abort_issue);
 assert(select state from private.offline_reward_reservation_commands where request_id=v_reservation)='refunded';

 -- Refund remaining NEW ordinary QA sales only, so fixture cash nets zero.
 for v_payment in select payment.invoice_id from public.business_payment_events payment join public.business_invoices invoice on invoice.invoice_id=payment.invoice_id where invoice.branch_id=v_branch and payment.event_type='sale'and not exists(select 1 from public.business_payment_events refunded where refunded.invoice_id=payment.invoice_id and refunded.event_type='refund')loop
 execute 'set local role authenticated';perform public.record_shift_payment(gen_random_uuid(),v_shift,v_payment.invoice_id,'refund','cash');execute 'reset role';end loop;
 assert(select coalesce(sum(case when payment.event_type='sale'then payment.amount else-payment.amount end),0)from public.business_payment_events payment join public.business_invoices invoice on invoice.invoice_id=payment.invoice_id where invoice.branch_id=v_branch)=0;
 update private.offline_service_visit_runtime set earning_enabled=false where singleton;
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert not(select read_enabled from private.offline_visit_wallet_runtime where singleton);
 assert not(select public_enabled from private.offline_reward_issuer_runtime where singleton);
 assert private.offline_service_visit_readiness()->>'redemption_enabled'='false';
 assert(select count(*)from private.reward_rule_activations)=v_rule_activation_count;
 assert(select count(*)from private.loyalty_visit_activations)=v_booking_activation_count;
 assert v_old_auth_hash=(select md5(coalesce(string_agg(to_jsonb(u)::text,''order by id),''))from auth.users u);
 assert v_old_employment_hash=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by staff_id),''))from private.hr_employment e);
 assert v_old_credit_hash=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by e.id),''))from private.canonical_loyalty_visits e where e.id=any(coalesce(v_old_credit_ids,'{}'::uuid[])));
 set constraints all immediate;
end$$;
rollback;
