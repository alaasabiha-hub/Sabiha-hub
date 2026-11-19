-- COMPONENT SOURCE ONLY: root LOCAL isolated transaction. No production enable path.
-- ONLY this outer rollback transaction relaxes the shipped false CHECK by test-owned DDL.
begin;
do $$declare c record;begin
 assert exists(select 1 from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%'),'Production disabled check must exist before test-only DDL';
 for c in select conname from pg_constraint where conrelid='private.offline_service_visit_runtime'::regclass and contype='c'and pg_get_constraintdef(oid)like'%earning_enabled%'loop
 execute format('alter table private.offline_service_visit_runtime drop constraint %I',c.conname);end loop;
end$$;
do $$
declare own uuid;worker uuid;branch uuid:=gen_random_uuid();service uuid:=gen_random_uuid();offer uuid:=gen_random_uuid();policy_id uuid:=gen_random_uuid();rules_id uuid:=gen_random_uuid();overlay uuid:=gen_random_uuid();activation uuid:=gen_random_uuid();intake jsonb;reg jsonb;result jsonb;pay_shift uuid:=gen_random_uuid();cmd uuid;old_order uuid;paid_order uuid;refund_first_order uuid;paid_invoice text;refund_first_invoice text;stage text;earning uuid;before_booked_activations bigint;before_rule_activations bigint;old_ids uuid[];old_hash text;denied boolean;
begin
 select user_id into strict own from public.staff_profiles where role='owner'and is_active limit 1;
 select s.user_id into strict worker from public.staff_profiles s join private.hr_employment e on e.staff_id=s.user_id where s.is_active and s.role in('employee','manager')and e.currency='EGP'and e.starts_on<=(clock_timestamp()at time zone'Africa/Cairo')::date and(e.ends_on is null or e.ends_on>=(clock_timestamp()at time zone'Africa/Cairo')::date)order by s.user_id limit 1;
 -- If no actual configured QA worker exists, FAIL; root may create a NEW isolated staff,
 -- never extend/reset an old contract or fabricate offline-customer Auth.
 select array_agg(id),md5(coalesce(string_agg(to_jsonb(e)::text,''order by id),''))into old_ids,old_hash from private.canonical_loyalty_visits e;
 select count(*)into before_booked_activations from private.loyalty_visit_activations;
 select count(*)into before_rule_activations from private.reward_rule_activations;
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 assert(select encode(extensions.digest(prosrc,'sha256'),'hex')from pg_proc where oid='private.evaluate_booked_loyalty_visit(uuid)'::regprocedure)='f28cc6f8b1d672d498591672c3688726474bb9f6028d91134b36c809250153c1';
 assert(select encode(extensions.digest(prosrc,'sha256'),'hex')from pg_proc where oid='private.reconcile_booked_loyalty_visit(uuid)'::regprocedure)='1650a8cdfb6d732ce080bc3eef9d9208d9d17b58a842d9445c81dcd69f69fc64';
 assert not has_function_privilege('authenticated','private.reconcile_offline_service_visit(uuid)','EXECUTE');
 assert not has_table_privilege('authenticated','private.offline_visit_channel_activations','INSERT');
 insert into public.business_branches(branch_id,name_ar,name_en)values(branch,'اختبار محرك زيارات خاص','Offline kernel QA');
 update public.business_branch_hours set is_open=true,opens_at='00:00',closes_at='23:59'where branch_id=branch;
 insert into public.staff_branch_access(user_id,branch_id)values(worker,branch);
 insert into public.business_catalog_items(item_id,branch_id,item_type,name,vehicle_type,price,duration_minutes,resource_key,is_active,is_public)values(service,branch,'service','QA actual visit','sedan',120,5,'wash',true,true);
 insert into public.business_offers(offer_id,branch_id,name,offer_type,visits_required,reward_item_id,is_active,is_public)values(offer,branch,'QA visit benefit','visit_reward',3,service,true,true);
 reg:=jsonb_build_object('accepted',true,'version','offline-registration-v1','language','en','text',private.offline_registration_notice('en'));
 perform set_config('request.jwt.claim.sub',own::text,true);execute 'set local role authenticated';
 perform public.save_loyalty_policy(policy_id,branch,offer,array[service],true);
 perform public.save_loyalty_redemption_rules(rules_id,policy_id,null,'{"pooling":"policy_version","expiry":"no_expiry","cancellation":"restore_visits","refunded_contribution":"offset_future_visits"}');
 intake:=public.register_offline_customer(gen_random_uuid(),branch,'QA offline kernel profile','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA KERNEL1"}',reg);
 cmd:=gen_random_uuid();perform public.prepare_offline_walk_in(cmd,(intake->>'request_id')::uuid,service,120,own,array[worker]);result:=public.place_offline_walk_in(cmd);old_order:=(result#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(cmd);
 execute 'reset role';
 insert into private.offline_visit_channel_versions(version_id,policy_version_id,rules_version_id,branch_id,eligible_service_ids,target_offline_profile_ids,enabled,terms_snapshot,created_by)
 select overlay,p.version_id,r.rules_version_id,branch,array[service],array[(intake->>'offline_profile_id')::uuid],true,
 jsonb_build_object('unit','service_visits','source_channel','offline_walk_in','eligibility_basis','order_created_time','policy_snapshot',p.policy_snapshot,'rules',r.rules,'rules_terms_snapshot',r.terms_snapshot),own
 from private.loyalty_policy_versions p join private.loyalty_redemption_rule_versions r on r.policy_version_id=p.version_id where p.version_id=policy_id and r.rules_version_id=rules_id;
 denied:=false;begin insert into private.offline_visit_channel_activations(activation_id,channel_version_id,activated_by)values(activation,overlay,own);exception when object_not_in_prerequisite_state then denied:=true;end;assert denied,'Production default cannot activate';
 -- Test-owned DDL was isolated above; no shipped test parameter or role bypass.
 update private.offline_service_visit_runtime set earning_enabled=true where singleton;
 insert into private.offline_visit_channel_activations(activation_id,channel_version_id,activated_by)values(activation,overlay,own);

 -- New capture acceptance: targeted audience, live offer edits, base version cutoff.
 execute 'set local role authenticated';
 cmd:=gen_random_uuid();perform public.prepare_offline_walk_in(cmd,(intake->>'request_id')::uuid,service,120,own,array[worker]);result:=public.place_offline_walk_in(cmd);paid_order:=(result#>>'{result,order_id}')::uuid;perform public.ack_offline_walk_in_command(cmd);
 execute 'reset role';
 assert exists(select 1 from private.offline_service_visit_order_snapshots where order_id=paid_order and earning_authorized and offline_activation_id=activation),'Actual targeted audience capture';
 select to_jsonb(snap) into result from private.offline_service_visit_order_snapshots snap where order_id=paid_order;
 execute 'set local role authenticated';
 intake:=public.register_offline_customer(gen_random_uuid(),branch,'QA outside audience','+201'||lpad((abs(hashtextextended(gen_random_uuid()::text,0))%1000000000)::text,9,'0'),'EG','{"plate_number":"QA AUDIENCE2"}',reg);
 cmd:=gen_random_uuid();perform public.prepare_offline_walk_in(cmd,(intake->>'request_id')::uuid,service,120,own,array[worker]);intake:=intake||jsonb_build_object('placed',public.place_offline_walk_in(cmd));refund_first_order:=(intake#>>'{placed,result,order_id}')::uuid;perform public.ack_offline_walk_in_command(cmd);
 execute 'reset role';
 assert exists(select 1 from private.offline_service_visit_order_snapshots where order_id=refund_first_order and not earning_authorized and not declared_eligible),'Outside audience cannot earn';
 update public.business_offers set name='QA changed offer terms'where offer_id=offer;
 assert not private.offline_visit_base_terms_current(policy_id,rules_id),'Live offer edits invalidate new captures';
 execute 'set local role authenticated';
 cmd:=gen_random_uuid();perform public.prepare_offline_walk_in(cmd,(intake->>'request_id')::uuid,service,120,own,array[worker]);intake:=intake||jsonb_build_object('placed',public.place_offline_walk_in(cmd));refund_first_order:=(intake#>>'{placed,result,order_id}')::uuid;perform public.ack_offline_walk_in_command(cmd);
 execute 'reset role';
 assert not exists(select 1 from private.offline_service_visit_order_snapshots where order_id=refund_first_order and earning_authorized),'Changed offer never reuses old channel authorization';
 assert result=(select to_jsonb(snap)from private.offline_service_visit_order_snapshots snap where order_id=paid_order),'Earlier snapshot rights stay frozen';
 update public.business_offers set name='QA visit benefit'where offer_id=offer;
 assert private.offline_visit_base_terms_current(policy_id,rules_id);
 execute 'set local role authenticated';perform public.save_loyalty_policy(gen_random_uuid(),branch,offer,array[service],false);execute 'reset role';
 assert not private.offline_visit_base_terms_current(policy_id,rules_id),'New owner policy supersedes new channel capture';
 assert result=(select to_jsonb(snap)from private.offline_service_visit_order_snapshots snap where order_id=paid_order),'New base versions cannot rewrite old captured terms';
 update private.offline_service_visit_runtime set earning_enabled=false where singleton;
end$$;
rollback;
