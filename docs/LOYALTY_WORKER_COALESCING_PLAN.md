# Captured same-order loyalty event coalescing — source only

No migration application, DB query/test, runtime mutation, library change, build, deployment, cron activation or old-suite repeat by the author. Migration was created by the local CLI. Root must independently review/apply/test during an exclusive database slot.

## Bounded change

Same existing private outbox, public/private worker, cron entry/advisory key, reconciler and shared booking/offline visit ledger. No financial trigger synchronization or second queue. Existing return keys/codes, READ COMMITTED requirement,20-second lock timeout, scheduler-disabled2-minute retry, per-event exponential error backoff capped at1hour, SQLSTATE-only errors and client/private grants remain.

Select the original oldest due anchor with `FOR UPDATE SKIP LOCKED`. A private non-client-callable resolver coalesces only recognized real source events resolving to an existing service order: all present order/invoice/booking references agree, invoice/booking branch matches, booking has exactly one service order, actual payment source points at the stated invoice, and snapshot-binding source points at the actual binding. Missing, contradictory, ambiguous, orphan or unknown-source events stay individual using the old fallback. This does not change financial/earning eligibility.

Capture up to99 additional visible due same-order IDs (100including anchor) in one ordered `FOR UPDATE SKIP LOCKED` query, before canonical/order reconciliation locks. The cheap reference filter avoids resolving every unrelated explicit-order event. Existing event source IDs are not presumed equal to order/booking IDs: many trigger events intentionally have opaque random source IDs.

A successful capture subtransaction transfers its event locks to the outer transaction. If capture fails, its candidate locks roll back and ONLY the outer-locked anchor receives backoff. Then a separate reconcile subtransaction calls the existing reconciler once for the captured canonical order. That order is frozen across capture/reconcile; it is not re-resolved to another invoice/order reference while acknowledging the captured order's rows. Only the captured UUID array is ever marked processed/retried. If reconciliation fails, all its partial writes roll back while the earlier event locks remain held; every captured event keeps its own attempts/backoff. No update by order ID occurs after reconciliation.

An event inserted/committed after the capture statement remains pending even if the reconciler observes its business facts. Another worker's locked event is skipped and never updated; this avoids event-row→canonical-lock versus canonical-lock→foreign-event-row inversion. Batches over100naturally retain more events for the next worker. The cap is a work bound, not a reward policy.

## Source fixtures, explicitly not run

* `supabase/tests/loyalty_visit_worker_coalescing.sql`: exclusive empty queue and existing service reference; all changes inside ROLLBACK. Replaces the reconciler **inside that transaction only** with a temporary call/partial-write spy. Proves one call for multiple same-order events, future event untouched, new after-capture event preserved, scheduler-disabled shape/backoff, per-row attempts, poison partial-write rollback, missing booking/bad invoice references processed individually,20s/grants unchanged. It does not claim actual earning/refund eligibility or concurrent sessions. No existing business rows are changed. The transaction restores the real function and every row at rollback. Missing-booking fixture covers unresolved references; actual ambiguous-booking creation is not fabricated against existing rows.
* `tools/loyalty_visit_coalescing_concurrency.py`: PLAN default, no DB/API/credentials accessed. `py_compile` and PLAN only passed. A future root-released `--execute` uses the actual installed worker/reconciler and two real SQL sessions with an existing received, unpaired, untyped, non-earned legacy service order as a read-only reference. It acquires only the existing cron session mutex, requires no pending work and actual scheduler readiness, and creates only new journaled private outbox QA events. No Auth/config/business/financial/visit rows are created/changed, no replacement reconciler, no deletes.

The actual-session plan holds A's own event; B skips it and holds its canonical lock; A then waits for that canonical advisory lock rather than B's event. B must commit and both events finish once. Next, block canonical reconciliation after A captures two events, insert a third from an independent committed connection, release A and prove the third stays pending until another real drain. Finally roll back an actual worker transaction and prove both events remain pending and can be retried. `finally` rolls back only owned sessions, releases own advisory locks, and drains only known QA events if every pending event belongs to this run. It never manually marks events processed, restores counters, or deletes rows. Known QA attempts may be rescheduled only for cleanup through the actual worker.

Example future root invocation (no execution currently authorized):

```sh
python3 tools/loyalty_visit_coalescing_concurrency.py
python3 tools/loyalty_visit_coalescing_concurrency.py --execute \
 --state /Users/user/Documents/Codex/2026-11-12/v/work/runtime/loyalty-coalescing-concurrency-state.json \
 --proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/loyalty-coalescing-concurrency-proof.json
```

Fresh0600journal/proof paths required; no overwriting prior evidence. Original public/private row hashes, including counters/financial/visit rows, must remain identical; additions must be only new private outbox rows, all processed afterward. Any failure stops with sanitized class/stage and no automatic retry. Existing cron, production offline-earning disabled CHECK, runtime readiness and actual policy activation are unchanged.

## Remaining limits

Not a throughput benchmark, new scheduler frequency or general queue rewrite. Reference classification costs reads; very large backlog plans/load must be checked separately. The existing individual-event fallback and actual reconciler retain their earlier semantics. Static/dry-run/rollback and actual two-session acceptance remain required before any success claim or apply. Root's concurrently developed identity/wallet/recovery work is not touched.
