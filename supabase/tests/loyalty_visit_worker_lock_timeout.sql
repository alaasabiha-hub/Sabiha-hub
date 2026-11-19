begin;
do $$begin
 assert exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname='drain_loyalty_visit_event' and p.pronargs=0 and p.proconfig @> array['lock_timeout=20s']),'Private worker must enforce its own 20-second lock bound';
 assert not has_function_privilege('authenticated','public.drain_loyalty_visit_event()','execute'),'Application clients gained worker execution';
 assert not has_function_privilege('anon','private.run_loyalty_visit_cron()','execute'),'Anonymous cron entry became executable';
 raise notice 'PASS private worker lock timeout configuration and unchanged execution boundary';
end $$;
rollback;
