-- SOURCE ONLY. Root serial LOCAL rollback acceptance; never fabricates Auth/booking/payment.
-- Requires one existing configured active EGP QA worker; does not modify employment.
begin;
do $$
declare own uuid;worker uuid;branch uuid:=gen_random_uuid();service uuid:=gen_random_uuid();offer uuid:=gen_random_uuid();policy1 uuid:=gen_random_uuid();policy2 uuid:=gen_random_uuid();policy3 uuid:=gen_random_uuid();
 intake jsonb;other_intake jsonb;reg jsonb;terms jsonb;result jsonb;snapshot private.offline_service_visit_order_snapshots;receipt jsonb;
 command1 uuid:=gen_random_uuid();command2 uuid:=gen_random_uuid();command3 uuid:=gen_random_uuid();order1 uuid;order2 uuid;order3 uuid;
 original_ledger text;after_ledger text;original_engine text;original_policy_count bigint;original_outbox bigint;denied boolean;golden jsonb;old_policy record;legacy_before jsonb;legacy_after jsonb;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select s.user_id into strict worker from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id
 where s.is_active and s.role in('manager','employee')and e.currency='EGP'and e.starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date
 and(e.ends_on is null or e.ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date)order by s.user_id limit 1;
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by id),''))into original_ledger from private.canonical_loyalty_visits e;
 select md5(string_agg(pg_get_functiondef(p.oid),''order by p.oid))into original_engine from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'and p.proname in('evaluate_loyalty_visit','reconcile_loyalty_visit','drain_loyalty_visit_event','reward_credit_terms','reward_program_lots','sync_customer_rewards');
 select count(*)into original_policy_count from private.loyalty_policy_versions;select count(*)into original_outbox from private.loyalty_visit_outbox;
 select coalesce(jsonb_object_agg(p.version_id::text,to_jsonb(p)-'offline_channel_terms'),'{}'::jsonb)into legacy_before from private.loyalty_policy_versions p;
 -- Golden pre-extension policy shape, including NULL fields; do not rewrite stored JSON.
 for old_policy in select p.*,to_jsonb(p)-'offline_channel_terms'golden,exists(select 1 from public.business_branches b where b.branch_id=p.branch_id and b.is_active)and not exists(select 1 from private.loyalty_policy_versions newer where newer.branch_id=p.branch_id and newer.version_no>p.version_no)check_current from private.loyalty_policy_versions p where p.created_by=own and p.offline_channel_terms is null loop
  execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);
  result:=public.save_loyalty_policy(old_policy.version_id,old_policy.branch_id,old_policy.offer_id,old_policy.eligible_service_ids,old_policy.enabled);
  assert result=old_policy.golden and not(result?'offline_channel_terms'),'Existing saved request replay changed legacy JSON shape';
  if old_policy.check_current then assert public.get_loyalty_policy(old_policy.branch_id)->'current'=old_policy.golden,'Existing current-policy read changed legacy JSON shape';end if;
  execute 'reset role';
 end loop;

 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert private.offline_service_visit_readiness() @>'{"unit":"service_visits","earning_enabled":false,"redemption_enabled":false,"offline_wallet_access":false,"points_conversion":false}';
 assert not has_table_privilege('authenticated','private.offline_service_visit_order_snapshots','SELECT');
 assert not has_function_privilege('authenticated','private.canonical_service_visit_owner(uuid)','EXECUTE');
 denied:=false;begin update private.offline_service_visit_runtime set earning_enabled=true;exception when check_violation then denied:=true;end;assert denied,'No private/test activation bypass';
 assert private.valid_offline_service_visit_terms(null);
 assert not private.valid_offline_service_visit_terms('{"unit":"points","enabled":true}');
 terms:='{"unit":"service_visits","source_channel":"offline_walk_in","eligibility_basis":"order_created_time","enabled":true,"target_offline_profile_ids":null}';
 assert private.valid_offline_service_visit_terms(terms);
 assert not private.valid_offline_service_visit_terms(terms||'{"target_customer_ids":[]}'),'Auth audiences must not silently target guests';
 assert not private.valid_offline_service_visit_terms(terms||'{"target_offline_profile_ids":[]}');
 insert into public.business_branches(branch_id,name_ar,name_en)values(branch,'اختبار ملكية الزيارات','Offline visit owner QA');
 update public.business_branch_hours set is_open=true,opens_at='00:00',closes_at='23:59'where branch_id=branch;
 insert into public.staff_branch_access(user_id,branch_id)values(worker,branch);
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(service,branch,'service','QA typed visit service','sedan',120,5,'wash',true,true);
 insert into public.business_offers(offer_id,branch_id,name,offer_type,visits_required,reward_item_id,is_active,is_public)values(offer,branch,'QA explicit visit offer', 'visit_reward',3,service,true,true);
 reg:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 execute 'set local role authenticated';perform set_config('request.jwt.claim.sub',own::text,true);
 intake:=public.register_offline_customer(gen_random_uuid(),branch,'QA offline visit owner','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA VISIT1"}',reg);
 other_intake:=public.register_offline_customer(gen_random_uuid(),branch,'QA separate visit owner','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA VISIT2"}',reg);
 result:=public.save_loyalty_policy(policy1,branch,offer,array[service],true);
 assert not(result?'offline_channel_terms'),'Legacy new-save response must omit the new field';
 assert public.save_loyalty_policy(policy1,branch,offer,array[service],true)=result,'Normal/replay replies differ';
 assert public.get_loyalty_policy(branch)->'current'=result,'Legacy read differs from save/replay';
 execute 'reset role';select to_jsonb(p)-'offline_channel_terms'into golden from private.loyalty_policy_versions p where p.version_id=policy1;
 assert golden=result,'New-save response differs from independent pre-extension golden shape';
 execute 'set local role authenticated';
 perform public.prepare_offline_walk_in(command1,(intake->>'request_id')::uuid,service,120,own,array[worker]);receipt:=public.place_offline_walk_in(command1);order1:=(receipt#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(command1);
 execute 'reset role';assert not exists(select 1 from private.offline_service_visit_order_snapshots where order_id=order1),'Old save contract must not expand to offline';
 -- TEST-ONLY future-version input; no public owner channel-config RPC exists yet.
 insert into private.loyalty_policy_versions(version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by,offline_channel_terms)
 select policy2,p.branch_id,p.offer_id,p.eligible_service_ids,p.enabled,p.policy_snapshot,p.request_payload||jsonb_build_object('offline_channel_terms',terms),own,terms from private.loyalty_policy_versions p where p.version_id=policy1;
 denied:=false;begin insert into private.loyalty_policy_versions(version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by,offline_channel_terms)
 select gen_random_uuid(),p.branch_id,p.offer_id,p.eligible_service_ids,p.enabled,p.policy_snapshot,p.request_payload,own,terms from private.loyalty_policy_versions p where p.version_id=policy1;
 exception when invalid_parameter_value then denied:=true;end;assert denied,'New terms require explicit exact request payload';
 execute 'set local role authenticated';
 perform public.prepare_offline_walk_in(command2,(intake->>'request_id')::uuid,service,120,own,array[worker]);receipt:=public.place_offline_walk_in(command2);order2:=(receipt#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(command2);
 execute 'reset role';select * into strict snapshot from private.offline_service_visit_order_snapshots where order_id=order2;
 assert snapshot.offline_profile_id=(intake->>'offline_profile_id')::uuid and snapshot.catalog_item_id=service and snapshot.policy_version_id=policy2;
 assert snapshot.declared_eligible and not snapshot.earning_authorized and snapshot.eligibility_basis='order_created_time';
 assert snapshot.channel_terms_snapshot=terms and snapshot.rules_reference_id is null;
 assert not exists(select 1 from private.offline_service_visit_order_snapshots where order_id=order1),'Later policy must not backfill earlier order';
 denied:=false;begin update private.offline_service_visit_order_snapshots set earning_authorized=true where order_id=order2;exception when raise_exception or check_violation then denied:=true;end;assert denied,'Disabled snapshot cannot become retroactive rights';
 denied:=false;begin insert into private.canonical_loyalty_visits(kind,visits,source_channel,offline_profile_id,offline_order_snapshot_id)values('earn',1,'offline_walk_in',(intake->>'offline_profile_id')::uuid,order2);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied,'No offline credit before full kernel even with real source/profile';
 terms:=terms||jsonb_build_object('target_offline_profile_ids',jsonb_build_array(other_intake->>'offline_profile_id'));
 insert into private.loyalty_policy_versions(version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by,offline_channel_terms)
 select policy3,p.branch_id,p.offer_id,p.eligible_service_ids,p.enabled,p.policy_snapshot,p.request_payload||jsonb_build_object('offline_channel_terms',terms),own,terms from private.loyalty_policy_versions p where p.version_id=policy1;
 execute 'set local role authenticated';
 perform public.prepare_offline_walk_in(command3,(intake->>'request_id')::uuid,service,120,own,array[worker]);receipt:=public.place_offline_walk_in(command3);order3:=(receipt#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(command3);
 execute 'reset role';assert exists(select 1 from private.offline_service_visit_order_snapshots where order_id=order3 and not declared_eligible and not earning_authorized),'Actual typed audience exclusion must remain frozen';
 assert(select policy_version_id from private.offline_service_visit_order_snapshots where order_id=order2)=policy2;
 assert not exists(select 1 from public.business_orders where order_id in(order1,order2,order3)and(customer_id is not null or booking_id is not null));
 assert not exists(select 1 from public.business_payment_events where invoice_id in(select invoice_id from private.offline_walk_in_subjects where order_id in(order1,order2,order3)));
 assert(select count(*)from private.loyalty_visit_outbox)=original_outbox,'No parallel consumer or guest outbox work enabled';
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by id),''))into after_ledger from private.canonical_loyalty_visits e;assert after_ledger=original_ledger,'No new or changed credits/rights';
 assert not exists(select 1 from private.canonical_loyalty_visits e where e.source_channel<>'booking'or e.offline_profile_id is not null or e.customer_id is null or e.booking_id is null);
 assert original_engine=(select md5(string_agg(pg_get_functiondef(p.oid),''order by p.oid))from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'and p.proname in('evaluate_loyalty_visit','reconcile_loyalty_visit','drain_loyalty_visit_event','reward_credit_terms','reward_program_lots','sync_customer_rewards')),'Existing engine/cohort/refund functions untouched';
 assert(select count(*)from private.loyalty_policy_versions)=original_policy_count+3;
 select coalesce(jsonb_object_agg(p.version_id::text,to_jsonb(p)-'offline_channel_terms'),'{}'::jsonb)into legacy_after from private.loyalty_policy_versions p where legacy_before?p.version_id::text;
 assert legacy_after=legacy_before,'Old policy JSON/facts/payload changed';

end$$;
rollback;
