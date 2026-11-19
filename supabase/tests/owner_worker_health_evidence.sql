-- Focused rollback acceptance. Root executes after reviewed migration; no cron/job
-- history edits, no fake success, no health consumer or business operation writes.
begin;
create function pg_temp.health_actor(p_actor uuid,p_session uuid)returns void language plpgsql as $$begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',p_actor,'session_id',p_session,'user_metadata',jsonb_build_object('role','owner'))::text,true);
end$$;
create function pg_temp.assert_health_queue_channels(p_booking_order uuid,p_offline_order uuid)returns void language plpgsql as $$
declare before_value jsonb;after_value jsonb;begin
 assert exists(select 1 from public.business_orders where order_id=p_booking_order and booking_id is not null);
 assert exists(select 1 from private.offline_walk_in_subjects where order_id=p_offline_order);
 before_value:=public.get_owner_system_health(null);
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id,attempts,last_error_code)
 values('qa_health_booking',gen_random_uuid(),p_booking_order,1,'55P03'),('qa_health_offline',gen_random_uuid(),p_offline_order,1,'PRIVATE_QA_PAYLOAD_MUST_NOT_ESCAPE');
 after_value:=public.get_owner_system_health(null);
 assert(after_value#>>'{background_worker,pending_events}')::bigint=(before_value#>>'{background_worker,pending_events}')::bigint+2;
 assert(after_value#>>'{background_worker,pending_failed_attempts}')::bigint=(before_value#>>'{background_worker,pending_failed_attempts}')::bigint+2;
 assert coalesce((after_value#>>'{background_worker,error_code_counts,55P03}')::bigint,0)=coalesce((before_value#>>'{background_worker,error_code_counts,55P03}')::bigint,0)+1;
 assert coalesce((after_value#>>'{background_worker,error_code_counts,other}')::bigint,0)=coalesce((before_value#>>'{background_worker,error_code_counts,other}')::bigint,0)+1;
 assert position('PRIVATE_QA_PAYLOAD_MUST_NOT_ESCAPE'in after_value::text)=0;
end$$;
do $$
declare checked timestamptz:='2026-11-15T00:00:00Z';value jsonb;prior_value jsonb;own uuid;sid uuid;nonowner uuid;nonowner_session uuid;denied boolean;booking_order uuid;offline_order uuid;
begin
 -- Synthetic classifier component assertions only. They do NOT prove actual cron.
 assert private.classify_visit_worker_health(checked,false,null,null,0,0)->>'state'='not_checked';
 assert private.classify_visit_worker_health(checked,true,null,null,0,0)->>'state'='not_checked';
 assert private.classify_visit_worker_health(checked,true,checked-interval'6 minutes',null,0,0)->>'state'='not_checked';
 assert private.classify_visit_worker_health(checked,true,checked+interval'1 second',null,0,0)->>'state'='not_checked';
 assert private.classify_visit_worker_health(checked,true,checked,null,0,1)->>'state'='not_checked';
 assert private.classify_visit_worker_health(checked,true,checked,null,0,0)->>'state'='working';
 assert private.classify_visit_worker_health(checked,true,checked-interval'1 minute',checked,0,0)->>'state'='failed';
 assert private.classify_visit_worker_health(checked,true,checked,null,1,0)->>'state'='failed';
 select s.user_id,a.id into strict own,sid from public.staff_profiles s join auth.sessions a on a.user_id=s.user_id join auth.users u on u.id=s.user_id
 where s.role='owner'and s.is_active and u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())order by a.created_at desc limit 1;
 select a.user_id,a.id into strict nonowner,nonowner_session from auth.sessions a join auth.users u on u.id=a.user_id
 where u.deleted_at is null and(u.banned_until is null or u.banned_until<=clock_timestamp())and(a.not_after is null or a.not_after>clock_timestamp())
 and not exists(select 1 from public.staff_profiles s where s.user_id=a.user_id and s.role='owner'and s.is_active)order by a.created_at desc limit 1;
 perform pg_temp.health_actor(own,null);denied:=false;begin perform public.get_owner_system_health();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.health_actor(own,nonowner_session);denied:=false;begin perform public.get_owner_system_health();exception when insufficient_privilege then denied:=true;end;assert denied;
 perform pg_temp.health_actor(nonowner,nonowner_session);denied:=false;begin perform public.get_owner_system_health();exception when insufficient_privilege then denied:=true;end;assert denied;
 assert not has_function_privilege('anon','public.get_owner_system_health(uuid)','EXECUTE');
 assert not has_function_privilege('service_role','public.get_owner_system_health(uuid)','EXECUTE');
 assert not has_function_privilege('authenticated','private.classify_visit_worker_health(timestamptz,boolean,timestamptz,timestamptz,bigint,bigint)','EXECUTE');
 perform pg_temp.health_actor(own,sid);
 -- Actual public RPC is called with the real authenticated database role.
 execute 'set local role authenticated';value:=public.get_owner_system_health(null);execute 'reset role';
 assert value#>>'{database_probe,state}'='working';
 assert(value->>'checked_at')::timestamptz<=clock_timestamp();
 assert value#>>'{background_worker,source}'='canonical_loyalty_cron_and_outbox';
 assert value#>>'{background_worker,state}'in('working','failed','not_checked');
 assert not exists(select 1 from jsonb_each(value->'other_checks')x where x.value->>'state'<>'not_checked');
 assert not(value::text~'(return_message|access_token|registered_phone|full_name|payload|command)');
 -- New uncommitted unresolved row, never an edit to a real queue/job/history row.
 prior_value:=value;
 insert into private.loyalty_visit_outbox(source_kind,source_id,order_id)values('qa_health_unknown',gen_random_uuid(),null);
 value:=public.get_owner_system_health(null);
 assert(value#>>'{background_worker,unresolved_pending_events}')::bigint=(prior_value#>>'{background_worker,unresolved_pending_events}')::bigint+1;
 assert value#>>'{background_worker,state}'<>'working';
 -- Reuse real existing canonical order facts; no invented booking/invoice. Root
 -- fixtures already have both channels. Stop if absent rather than vacuous pass.
 select order_id into strict booking_order from public.business_orders where booking_id is not null order by order_id limit 1;
 select order_id into strict offline_order from private.offline_walk_in_subjects order by order_id limit 1;
 perform pg_temp.assert_health_queue_channels(booking_order,offline_order);
end$$;
rollback;
