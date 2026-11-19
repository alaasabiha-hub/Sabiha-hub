begin;
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

 perform set_config('request.jwt.claims',jsonb_build_object('sub',own,'role','authenticated','session_id',(select id from auth.sessions where user_id=own and(not_after is null or not_after>clock_timestamp())order by created_at desc limit 1))::text,true);
 execute 'set local role authenticated';
 result:=public.save_offline_visit_channel(overlay,branch,policy_id,rules_id,array[service],array[(intake->>'offline_profile_id')::uuid],true);
 assert result=public.save_offline_visit_channel(overlay,branch,policy_id,rules_id,array[service],array[(intake->>'offline_profile_id')::uuid],true),'Same UUID replay changed';
 assert public.get_offline_visit_channel(branch)->'current'=result;
 denied:=false;begin perform public.save_offline_visit_channel(overlay,branch,policy_id,rules_id,array[service],array[(intake->>'offline_profile_id')::uuid],false);exception when invalid_parameter_value then denied:=true;end;assert denied,'Changed replay accepted';
 denied:=false;begin perform public.save_offline_visit_channel(gen_random_uuid(),branch,policy_id,rules_id,array[service,service],null,true);exception when invalid_parameter_value then denied:=true;end;assert denied,'Duplicate services accepted';
 denied:=false;begin perform public.save_offline_visit_channel(gen_random_uuid(),branch,policy_id,gen_random_uuid(),array[service],null,true);exception when invalid_parameter_value then denied:=true;end;assert denied,'Foreign rules accepted';
 execute 'reset role';
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton),'Configuration activated production';
 assert not exists(select 1 from private.offline_visit_channel_activations where channel_version_id=overlay),'Configuration silently activated a channel';
 assert not exists(select 1 from private.canonical_loyalty_visits where offline_profile_id=(intake->>'offline_profile_id')::uuid),'Configuration generated credit';
 perform set_config('request.jwt.claim.sub',worker::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.get_offline_visit_channel(branch);exception when insufficient_privilege then denied:=true;end;assert denied,'Employee read owner configuration';
 denied:=false;begin perform public.save_offline_visit_channel(gen_random_uuid(),branch,policy_id,rules_id,array[service],null,false);exception when insufficient_privilege then denied:=true;end;assert denied,'Employee wrote owner configuration';
 execute 'reset role';perform set_config('request.jwt.claim.sub',own::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',own,'role','authenticated','session_id',gen_random_uuid())::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.get_offline_visit_channel(branch);exception when insufficient_privilege then denied:=true;end;assert denied,'Missing server session accepted';execute 'reset role';
 assert not has_function_privilege('anon','public.get_offline_visit_channel(uuid)','EXECUTE');
 assert not has_table_privilege('authenticated','private.offline_visit_channel_versions','INSERT');
end$$;
rollback;
