# Shared offline earning/refund kernel — next source draft boundary

2026-11-15. Design/source review only; no DB/test/build/library changes, no new executable migration yet. Foundation211249 is locally applied and disabled per coordinating agent; its stored-snapshot/legacy-response compatibility remains intact. This plan precedes a writer draft because the current activation FK cannot safely represent the required independent offline channel.

## Concrete blocker before copying the writer

`canonical_loyalty_visits.activation_id` is still a required FK to `loyalty_visit_activations`. That activation was explicitly for future Auth bookings. Passing the existing ID into a new offline earning would silently extend its scope; creating a synthetic booking activation for a guest would do the same. Also, every foundation order snapshot has immutable earning_authorized:false. Neither a link, later activation nor new worker can reinterpret those rows as earned rights.

The next migration therefore needs independent **channel configuration/activation metadata**, not another credit ledger: immutable `offline_visit_channel_versions` referencing the same `loyalty_policy_versions.version_id` and an explicitly selected existing redemption rules version; immutable `offline_visit_channel_activations` with exact channel-version ID, active owner and real future cutoff. Capture full frozen policy/rules/eligibility terms, explicit actual service IDs and typed offline audience. Existing Auth policy versions, booking activation records, rules/cohort activation and their timestamps/results remain untouched. No owner public configuration/activation RPC in the component stage.

Add nullable `canonical_loyalty_visits.offline_activation_id` FK; make the old activation NOT NULL rule conditional: booking → actual existing activation and no offline activation; offline → no booking activation and exact offline activation matching its immutable order binding. Keep every original FK and old column value; no row updates. Extend the existing order snapshot with overlay/activation references and frozen overlay terms. Only a newly created actual source after its independent cutoff can be authorized; all existing false snapshots stay permanently false. Do not add an overlay version to the existing Auth policy JSON/fingerprint or use the previous nullable column to mutate old policies.

## Dispatcher and exact old bodies

Preserve the exact accepted PL/pgSQL bodies of133029 `evaluate_loyalty_visit` and `reconcile_loyalty_visit` as private booking adapters. Source-extract them mechanically, retain their body hashes, and keep existing public/private entry signatures. Replace the original function bodies with small dispatchers selecting an actual immutable `offline_walk_in_subjects` association (or existing typed earning for reversal), otherwise the booking adapter. Preserve the same `canonical-visit:<order UUID>` mutex. The old booking adapter's recursive call can go through the dispatcher; the lock is reentrant and source selection cannot change.

Do not rename the original function OIDs and assume existing cached callers now reach the wrapper: copy bodies to private adapter helpers, then CREATE OR REPLACE the original names. Existing drain/cron continue calling the same reconcile OID. No second scheduler, event table or client earning RPC. Evaluate is read-only; reconcile is the only real credit writer. All new helpers revoked from PUBLIC/anon/authenticated/service_role; trusted existing definer worker reaches them internally.

## Focused offline evaluator contract

`evaluate_offline_service_visit(p_order)` returns explicit immutable-source facts or `{eligible:false,reason}`. It accepts no customer/profile/payment/rate supplied by the app. Checks:

1. Actual typed service subject/order/invoice/branch/profile/car/service coherence; Auth customer and booking remain NULL, snapshot source and overlay version match. New source creation time ≥ channel activation cutoff, immutable earning_authorized true and independent policy/rule snapshots exist. Never capture on old jobs/old orders or consult today's mutable terms for already captured rights.
2. Actual guarded work is completed/delivered, not merely received/quality_check. The shared work kernel is the only work transition source. Actual branch/services/offer live eligibility controls **capture**, not retroactive cancellation of existing rights. A new disabled overlay stops future capture without changing older rights.
3. Exactly one eligible positive nonvoid invoice for that canonical order; no reward-covered invoice earns, no issued snapshot revisions. Exact full trusted cash sale on its branch shift; no pending electronic evidence, fabricated payment_method or synthetic zero-value cash event. Actual full matching refund blocks first earning even if outbox reversal has not run.
4. Return unit=service_visits, typed owner offline_profile, real source/order/invoice/sale/branch/policy/overlay/activation/rule references and original sale amount. No money conversion, legacy points or claimed profit. Configured commission proof remains the existing immutable per-worker Walk-in sidecar, never a caller-provided rate.

A short shared settlement-proof helper may be extracted only after proving booking behavior unchanged; initially reuse the same evidence conditions rather than broadly rewriting old financial SQL.

## Reconcile and refund adapter

Under canonical order mutex, lock necessary real invoice rows deterministically by invoice ID, without taking a shift lock afterward. Cash writers keep shift→invoice ordering and do not acquire the visit mutex. Require READ COMMITTED and20s lock timeout, so post-wait checks see committed refunds. No synchronous credit write from order/payment triggers.

If an offline earning exists, validate the actual matching full branch cash refund and append exactly one reversal referencing the original earning/typed owner/policy/independent activation. Reversal must work even after channel pause/runtime disable: stopping future earning cannot erase the obligation to reverse a genuine refunded source. Otherwise evaluate actual source after locks and insert exactly one earn using the existing per-order unique index. Recheck committed refunds after FK/lock waits and reconcile the same order again if necessary. No update/delete of credits, no transfer on linking, no extra visit per worker/event. Preserve existing idempotent reversal index.

Strengthen the shared insert proof to reject forged typed owner/source/activation/payment/reversal associations. Do not merely remove foundation's hard fence. Before offline claims/quotes are supported, a new private guard must explicitly reject attempts to allocate an offline earning through the legacy Auth `guard_reward_claim`: its current `e.customer_id<>new.customer_id` nullable comparison is not typed owner proof. Existing Auth claim paths remain unchanged. Bind the selected frozen rules to the existing `reward_earning_terms` only under an explicit overlay-rule contract; never choose mutable latest rules when an old job drains.

Update the existing enqueue function only for real authorized new offline bindings/work/invoice/payment/refund events. Same outbox unique source keys, one-event worker, skip-locked retry/backoff and scheduler. Unconfigured or received-only guest sources must continue to create zero jobs. No parallel guest reconciler queue or new cron job.

## Production-disabled component testing without a shipped bypass

The migration keeps the private production earning runtime false and its unenableable CHECK, no public activation RPC, no service-role direct writer grant, and no `test_mode` parameter/GUC/JWT metadata or privileged role exception in earning logic. Real source capture cannot authorize a new credit while this gate is false. Full wallet/consent/redemption/commission acceptance is still required before any later migration can relax it.

Positive component tests can exercise the **same actual writer** only inside an explicitly isolated rollback transaction: install the candidate schema/functions, temporarily drop the runtime false CHECK by DDL within that transaction, set the private gate, create explicit owner overlay/activation and real tagged received→cash→guarded-completed fixtures, then call the existing worker/reconciler. Rollback restores the gate/check/schema/data. This is test-owned DDL under a database owner, not an executable application backdoor. Root must review this test method before writing/running it; no weakening is committed by the production migration. Use genuine configured QA staff, no Auth creation, quota resets or employment edits.

Focused cases: default disabled/old false snapshots/past cutoff cannot earn; actual unpaid complete and paid received cannot earn; completed+full cash earns once across duplicate events/workers and both commit orders; exact same-owner reversal once with refund before/after drain; refund must still reverse when channel paused; invoice/refund wait bound and retry; wrong branch/profile/rule/channel or foreign quote allocation rejected; old Auth body/projection/fingerprint/cohort functions unchanged; outside rollback old rows/Auth/IDs/payment/invoice/commissions/counters unchanged. No accepted broad suite rerun unless an actual source change justifies it.

## Remaining public activation blockers

Independent owner channel configuration and accepted activation cutoff; unified typed wallet/claims/quotes/debt/refund sync; separate live-link wallet-read and transaction-specific spend consent; explicit offline reward-worker commission recognition; same canonical issuer/coverage/cancel/retry/close/ack; owner review for evidence conflicts; complete concurrency and AR/EN actual acceptance. Generic points remain a different unimplemented unit. Earning component success alone cannot turn these readiness flags true.
