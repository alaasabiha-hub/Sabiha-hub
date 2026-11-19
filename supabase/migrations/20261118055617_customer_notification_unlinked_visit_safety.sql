begin;

-- Offline walk-ins intentionally have no customers.id until a verified claim
-- is accepted. Keep the loyalty ledger write independent from app-notification
-- delivery for those visits.
create or replace function private.customer_canonical_visit_operational_notice()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
  if new.kind='earn' and new.customer_id is not null then
    perform private.enqueue_customer_operational_notification(
      new.customer_id,new.branch_id,'loyalty_visit_earned','loyalty',new.id,
      'loyalty:visit:'||new.id::text,clock_timestamp(),jsonb_build_object('visits_earned',new.visits)
    );
  end if;
  return new;
end$$;
revoke all on function private.customer_canonical_visit_operational_notice()
  from public,anon,authenticated,service_role;

commit;
