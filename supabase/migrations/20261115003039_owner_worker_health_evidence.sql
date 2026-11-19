begin;
-- Read-only observation. No consumer, job, activation, snapshot or queue mutation.
create function private.classify_visit_worker_health(p_checked timestamptz,p_configured boolean,p_last_success timestamptz,p_last_failure timestamptz,p_pending_errors bigint,p_unresolved bigint)
returns jsonb language sql immutable set search_path=pg_catalog as $$
select jsonb_build_object('state',case
 when p_checked is null or p_configured is distinct from true then'not_checked'
 when p_last_failure is not null and(p_last_success is null or p_last_failure>p_last_success)and p_last_failure<=p_checked then'failed'
 when coalesce(p_pending_errors,0)>0 then'failed'
 when p_last_success is null or p_last_success>p_checked or p_last_success<p_checked-interval'5 minutes'or coalesce(p_unresolved,0)>0 then'not_checked'
 else'working'end,
 'reason',case
 when p_checked is null then'missing_probe_time'
 when p_configured is distinct from true then'scheduler_not_configured'
 when p_last_failure is not null and(p_last_success is null or p_last_failure>p_last_success)and p_last_failure<=p_checked then'observed_failed_run'
 when coalesce(p_pending_errors,0)>0 then'pending_failed_attempts'
 when p_last_success is null then'no_success_observed'
 when p_last_success>p_checked then'inconsistent_observation_time'
 when p_last_success<p_checked-interval'5 minutes'then'success_observation_stale'
 when coalesce(p_unresolved,0)>0 then'unresolved_queue_scope'
 else'recent_execution_observed'end,
 'success_max_age_seconds',300,
 'success_age_seconds',case when p_last_success is not null and p_checked is not null and p_last_success<=p_checked then floor(extract(epoch from p_checked-p_last_success))else null end);
$$;
revoke all on function private.classify_visit_worker_health(timestamptz,boolean,timestamptz,timestamptz,bigint,bigint)from public,anon,authenticated,service_role;

create function private.owner_worker_health_evidence(p_branch uuid default null)returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog set lock_timeout='20s' as $$
declare observed timestamptz;configured boolean;last_success timestamptz;last_failure timestamptz;installed timestamptz;
 pending bigint;due bigint;retrying bigint;errors bigint;unknown_scope bigint;oldest timestamptz;codes jsonb;worker jsonb;
begin
 perform private.require_offline_channel_owner();
 if p_branch is not null and not exists(select 1 from public.business_branches b where b.branch_id=p_branch)then raise exception 'Actual branch required'using errcode='22023';end if;
 configured:=private.loyalty_visit_scheduler_ready();last_success:=private.loyalty_visit_cron_last_success();
 -- Existing pg_cron schema is accessed only dynamically when installed. Never
 -- return cron.command/return_message or arbitrary application exception text.
 if configured and to_regclass('cron.job_run_details')is not null then
 select installed_at into installed from private.loyalty_visit_runtime where singleton;
 execute 'select max(r.end_time) from cron.job j join cron.job_run_details r using(jobid) where j.jobname=$1 and j.active and j.database=$2 and j.username=''postgres'' and j.command=''select private.run_loyalty_visit_cron();'' and r.command=''select private.run_loyalty_visit_cron();'' and r.database=$2 and r.username=''postgres'' and r.status=''failed'' and r.start_time>=$3 and r.end_time>=$3'
 into last_failure using 'canonical-loyalty-visits',current_database(),installed;
 end if;
 -- Scope is actual canonical order.branch_id, so booking and typed offline work
 -- share the same observation. Unresolvable rows cannot silently disappear.
 select count(*),count(*)filter(where x.next_attempt_at<=clock_timestamp()),count(*)filter(where x.attempts>0),count(*)filter(where x.last_error_code is not null),min(x.created_at)
 into pending,due,retrying,errors,oldest
 from private.loyalty_visit_outbox x join public.business_orders o on o.order_id=x.order_id join public.business_branches b on b.branch_id=o.branch_id
 where x.processed_at is null and(p_branch is null or o.branch_id=p_branch);
 select count(*)into unknown_scope from private.loyalty_visit_outbox x left join public.business_orders o on o.order_id=x.order_id left join public.business_branches b on b.branch_id=o.branch_id
 where x.processed_at is null and(o.order_id is null or b.branch_id is null);
 select coalesce(jsonb_object_agg(safe_code,quantity),'{}'::jsonb)into codes from(
 select case when x.last_error_code in('55P03','40P01','40001','42501','23503','23505','23514','57014','P0001','22023','55000')then x.last_error_code else'other'end safe_code,count(*)quantity
 from private.loyalty_visit_outbox x join public.business_orders o on o.order_id=x.order_id join public.business_branches b on b.branch_id=o.branch_id
 where x.processed_at is null and x.last_error_code is not null and(p_branch is null or o.branch_id=p_branch)group by 1)counts;
 observed:=clock_timestamp();
 worker:=private.classify_visit_worker_health(observed,configured,last_success,last_failure,errors,unknown_scope)||jsonb_build_object(
 'checked_at',observed,'source','canonical_loyalty_cron_and_outbox','scope','execution_observation_only','scheduler_configured',configured,
 'last_success_at',last_success,'last_failed_run_at',last_failure,'branch_id',p_branch,'pending_events',pending,'due_events',due,'retrying_events',retrying,
 'pending_failed_attempts',errors,'oldest_pending_created_at',oldest,'error_code_counts',codes,'unresolved_pending_events',unknown_scope,'unresolved_scope','all_branches');
 return jsonb_build_object('checked_at',observed,'database_probe',jsonb_build_object('state','working','checked_at',observed,'source','authenticated_database_round_trip','scope','this_request_only'),
 'background_worker',worker,'other_checks',jsonb_build_object(
 'booking_success',jsonb_build_object('state','not_checked'),'invoice_success',jsonb_build_object('state','not_checked'),
 'payments_and_integrations',jsonb_build_object('state','not_checked'),'device_sync',jsonb_build_object('state','not_checked'),
 'in_app_notifications',jsonb_build_object('state','not_checked'),'pdf_generation',jsonb_build_object('state','not_checked'),
 'backup_restore',jsonb_build_object('state','not_checked'),'global_security',jsonb_build_object('state','not_checked'),'financial_correctness',jsonb_build_object('state','not_checked')));
end$$;
revoke all on function private.owner_worker_health_evidence(uuid)from public,anon,authenticated,service_role;
grant execute on function private.owner_worker_health_evidence(uuid)to authenticated;
create function public.get_owner_system_health(p_branch uuid default null)returns jsonb language sql volatile security invoker set search_path=pg_catalog as $$select private.owner_worker_health_evidence(p_branch)$$;
revoke all on function public.get_owner_system_health(uuid)from public,anon,service_role;
grant execute on function public.get_owner_system_health(uuid)to authenticated;
notify pgrst,'reload schema';
commit;
