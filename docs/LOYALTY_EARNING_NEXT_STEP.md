> Update 14 November 2026: the engine, source outbox, actual scheduled posting, two-session races/refund reversal and bounded lock retry are now implemented and LOCAL-tested. See `PAYMENTS_HR_CONTINUATION_2026-11-14.md` for proofs. The text below records the earlier foundation design. Actual redemption is the current separate work; no production activation occurred.

# Canonical service-visit lifecycle

This development implementation counts **service visits**, not money or convertible credit. It never imports or merges legacy points, redeems rewards, changes invoice totals/discounts, or changes commissions. Production has not been updated. Do not call the automatic lifecycle verified merely because its SQL or cron registration exists.

## Policy and future-only activation

Owners create actual named visit offers with an explicit threshold and branch; drafts are unpublished unless explicitly published. Policies reference actual eligible service IDs. No configuration means inactive. The append-only `private.managed_visit_reward_offers` marker keeps adopted terms out of the legacy redemption path without rewriting legacy history.

Policy versions freeze the offer window, threshold, reward reference/value, targeting and booking-created eligibility basis. New eligible bookings capture an immutable policy snapshot. Live offer active/public flags stop future captures; old captures retain their original terms.

The server engine starts with its scheduler gate disabled and no policy activations. The separate registration migration installs a private postgres cron command. A current active owner can activate a current enabled policy only after an actual successful execution of that exact command has been observed recently in `cron.job_run_details`. A matching committed activation request remains idempotently readable if scheduler health later becomes stale; the current-owner check still runs first.

Only new snapshots that can see that committed activation create a separate immutable earning binding. It freezes customer, branch and catalog identity. This protects concurrent activation/booking creation and prevents older foundation snapshots from silently becoming earned visits. There is no historical backfill.

## Eligibility and reversal

A service visit requires the frozen binding, unchanged canonical customer/catalog/branch association, one service order for the booking, completed booking **and** completed/delivered order, one unambiguous non-void service invoice, and a matching full positive **cash** sale in the actual cashier ledger/branch. Selecting a payment method or receiving a sandbox callback does not qualify. Unknown mappings, duplicate invoices and incomplete facts fail closed.

An immutable earning is unique per canonical order. An actual matching full cash refund adds at most one negative reversal referencing that original earning and original customer. Refund-before-earning yields no positive visit. A refund racing the award is rechecked after financial FK waits and reconciled by its durable source event. Reversals can still run while new earning is paused. No financial source field is updated by this engine.

## Worker and scheduler

Triggers append independent source events; they never update one shared queue row per order or acquire the consumer's order advisory lock. A worker takes exactly one event with `FOR UPDATE SKIP LOCKED` per transaction, then serializes one canonical order. It does not lock another worker's event. READ COMMITTED is required; workers must not batch multiple drain calls into one transaction.

The source event from whichever completion/payment fact commits last causes another reconciliation. A rolled-back/crashed worker leaves its event pending. Failed work uses next-attempt ordering and exponential retry from 2 minutes to 1 hour, so an old poison event does not permanently block ready later work. Error metadata contains SQLSTATE rather than applicant/customer data.

The prepared cron registration is `canonical-loyalty-visits`, schedule `* * * * *`, command `select private.run_loyalty_visit_cron();`, database=current database, username=postgres. The entry is private/postgres-only; service workers have a separate tightly granted drain RPC. Registration requires `pg_cron` and run logging and refuses a conflicting/paused existing job. It does not activate policies. A maintenance advisory mutex can defer the cron entry without disabling the job; normal source writers never acquire that mutex.

This conservative schedule processes **one source event per minute**, and a visit can create several events. It is an asynchronous correctness baseline, not a verified busy-shop throughput setting. Pending-event counts expose the backlog. Faster scheduling/worker capacity requires separate load and concurrency verification. The follow-up `20261114144646_bound_loyalty_visit_worker_lock_waits.sql` bounds worker lock waits at 20 seconds; a timeout enters the same durable retry path rather than hanging the queue. The targeted helper disables the caller's lock timeout to verify that the bound comes from the worker itself.

## RPC contracts

- `get_loyalty_visit_lifecycle(p_branch uuid default null)`: active DB owner only. Flat fields include `policy_version_id`, `current_policy_enabled`, `activation`, `scheduler_ready`, `actual_cron_run_observed`, `last_successful_cron_run_at`, `pending_events`, `earned_visits`, `reversed_visits`, `net_visits`, and explicit visit unit/no-redemption/no-legacy flags.
- `activate_loyalty_visits(p_request uuid,p_policy_version uuid)`: current owner, exact retry identity, current policy, and actual recent cron-success gate. Returns activation ID/version/cutoff.
- `get_my_canonical_service_visits()`: authenticated caller's own earned/reversed/net service visits. It accepts no customer ID and exposes no customer/invoice identity. Legacy points remain separate; redemption is false.
- `drain_loyalty_visit_event()`: service_role or postgres only; one event per transaction. The private cron entry is not executable by application clients.

## Local acceptance

Root controls migration application and test execution. Apply engine `20261114133029_canonical_loyalty_visit_earning.sql`, then registration `20261114143011_register_canonical_loyalty_visit_consumer.sql` locally after review. Do not synchronize incomplete migration history blindly or push to hosted Supabase.

`tools/canonical_loyalty_visit_e2e.py` runs `supabase/tests/canonical_loyalty_visits.sql` inside rollback and checks all public/private row-count/content fingerprints. Core fixtures intentionally use private transaction-local activation to test reconciliation without pretending a scheduler run occurred. Public activation is separately tested to reject metadata-only readiness. The SQL covers both sequential fact orders, old snapshots, duplicate invoices, cash confirmation, immutability, refunds, poison retry fairness, current roles and own-only summaries.

After observing a real successful cron execution, run the actual multi-session helper:

```sh
python3 tools/loyalty_visit_concurrency.py \
  --runtime /Users/user/Documents/Codex/2026-11-12/v/work/runtime \
  --proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/loyalty-concurrency-proof.local.json \
  --observe-cron
```

It reuses `PsqlSession`, observes real waits, and exercises overlapping completion/payment in both commit orders, two workers, worker rollback/retry, and both refund/award race directions. The optional cron case waits for a real scheduled posting without manual draining of that case. It requires an empty preexisting queue. Tagged synthetic QA data is retained fully refunded with inactive branch/service/offer/policy; it never deletes history. All preexisting application rows must remain unchanged, except exact monotonic BKG/INV counter consumption for the retained new QA documents. Counters are never reset.

Record actual SQL, concurrency and scheduled-posting results before claiming automatic operation. Redemption stays disabled until pre-invoice quote/policy integration supports it without mutating issued invoices or before-discount commissions.

## Recorded local verification

Root reported rollback SQL acceptance passed with matching public/private fingerprints. Root also executed `tools/loyalty_visit_concurrency.py --observe-cron`: both actual commit orders, two-worker advisory wait, rollback/retry, both refund race directions and real scheduled posting passed. Evidence is saved privately as `resume-loyalty-concurrency-proof.json`. Tagged QA cash/visits were neutralized and the branch/service/offer/policy were deactivated; all preexisting business rows remained unchanged except the expected seven BKG and seven INV counter increments for retained QA records. This is local evidence, not a production deployment or a throughput test.

The additional 20-second lock-bound migration has its own rollback assertion and `tools/loyalty_visit_lock_timeout.py` acceptance helper. Root controls its application and execution; it does not require rerunning the full lifecycle suite. The helper retains one processed synthetic private outbox event and creates no business fixtures.
