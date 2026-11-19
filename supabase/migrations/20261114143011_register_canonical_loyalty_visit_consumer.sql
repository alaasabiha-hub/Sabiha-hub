begin;
-- Durable consumer only. No policy activations or historical visits are seeded.
do $$
declare jid bigint;
begin
 if current_user<>'postgres' then raise exception 'Register the private visit consumer as postgres';end if;
 if to_regclass('cron.job') is null then raise exception 'Enable pg_cron before registering the visit consumer';end if;
 if current_setting('cron.log_run',true) is distinct from 'on' then raise exception 'cron.log_run must be on so actual consumer execution can be verified';end if;
 if exists(select 1 from cron.job where jobname='canonical-loyalty-visits' and (username<>'postgres' or database<>current_database() or command<>'select private.run_loyalty_visit_cron();' or not active or schedule<>'* * * * *')) then raise exception 'Existing consumer name belongs to different scheduler configuration; review without overwriting';end if;
 select cron.schedule('canonical-loyalty-visits','* * * * *','select private.run_loyalty_visit_cron();') into jid;
 if not exists(select 1 from cron.job where jobid=jid and active and username='postgres' and database=current_database() and command='select private.run_loyalty_visit_cron();' and schedule='* * * * *') then raise exception 'Durable consumer registration did not match the required private command';end if;
 update private.loyalty_visit_runtime set scheduler_configured=true where singleton;
 if not found then raise exception 'Install canonical visit engine first';end if;
end $$;
-- The first successful actual cron run is still required before owner activation.
commit;
