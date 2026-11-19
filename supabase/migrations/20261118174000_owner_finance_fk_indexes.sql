-- Cover finance audit/idempotency foreign keys identified by the QA advisor.
-- These indexes are additive and do not modify financial rows.
create index if not exists owner_expense_audit_actor_idx
  on private.owner_expense_audit(actor_id);
create index if not exists owner_expense_audit_expense_idx
  on private.owner_expense_audit(expense_id);
create index if not exists owner_expense_records_created_by_idx
  on private.owner_expense_records(created_by);
create index if not exists owner_expense_records_updated_by_idx
  on private.owner_expense_records(updated_by);
create index if not exists owner_expense_requests_actor_idx
  on private.owner_expense_requests(actor_id);
