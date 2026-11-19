begin;
do $$declare before_hash text;refunded_first uuid:=current_setting('qa.refund_first')::uuid;earned_first uuid:=current_setting('qa.earn_first')::uuid;begin
 assert not(select earning_enabled from private.offline_service_visit_runtime where singleton);
 select md5(coalesce(string_agg(to_jsonb(e)::text,''order by id),''))into before_hash from private.canonical_loyalty_visits e;
 assert private.reconcile_loyalty_visit(refunded_first)='fully_refunded_before_earning';
 assert private.reconcile_loyalty_visit(refunded_first)='fully_refunded_before_earning';
 assert not exists(select 1 from private.canonical_loyalty_visits where order_id=refunded_first);
 assert private.reconcile_loyalty_visit(earned_first)='refunded';
 assert private.reconcile_offline_service_visit(gen_random_uuid())='scheduler_disabled','Unrelated paused sources must not be consumed';
 assert before_hash=(select md5(coalesce(string_agg(to_jsonb(e)::text,''order by id),''))from private.canonical_loyalty_visits e);
end$$;
rollback;
