# Local service-work concurrency proof — source frozen, not executed

`tools/service_work_kernel_concurrency.py` defaults to PLAN and makes no network/database calls in that mode. Python compilation and PLAN entrypoint are the only checks run by its author. Root must separately release one `--execute` run against the already reviewed local kernel185821 + followup194453. No old SQL/Dart suites, build, or production access are included.

## Preconditions and exact bounds

Use the existing owner, manager, other_employee, employee and customer credentials privately from the local runtime. No Auth creation, contact disclosure, HR writes or contract renewal. Explicit `--contract-state` and `--contract-proof` must identify the accepted financial-concurrency journal/proof inside runtime. The manager/other_employee employment row hashes must still match that journal and be eligible on the actual Cairo date. **Expired/end-date or changed employment stops before business writes**; root must review prerequisites rather than extending them automatically. Existing manager is a legitimate configured worker; roles are checked from current DB state.

Require no outstanding own work/financial/booking command and global canonical outbox empty. Sign-ins precede immutable identity and public/private row baselines. Run only while actual Cairo time is 00:01–22:50, retaining bounded time for the fresh 30-minute service and future booking. Root grants exclusive database write ownership while fingerprints are measured.

Create only a new tagged branch, all-day actual branch hours, capacity-one wash resource, deduplicated branch memberships, public sedan service priced120 with duration30, and separate consented private offline intakes through the actual manager registration RPC. Secret exists only in transient HTTP memory and is immediately discarded; it is never printed, journaled or recovered. Use an existing customer-owned vehicle with no nearby conflicting active bookings; do not change it. Normal booking RPC receives an explicit future QA minute accepted by its actual guard; this does not claim UI slot-list acceptance testing.

## Cases

1. Two actual authenticated SQL sessions execute the same prepared walk-in start UUID. Observe session2 blocked by session1, commit1, compare identical work event and exactly one physical span.
2. Booking takes the last planned slot first; concurrent walk-in start must actually wait and reject55000 after booking commits. Close/ack the failed start and cancel only the eligible pending unpaid customer booking through its existing RPC.
3. Walk-in takes the last physical slot first; concurrent normal customer booking must wait and reject the actual capacity P0001, with no booking/invoice committed. Close its durable customer attempt. Quality-check continues to hold the bay until actual complete transition.
4. Change a new booking's dispatch after prepare: execution40001 and zero work action. Close the command, restore only that new QA assignment and cancel through the customer RPC. Actual HTTP unassigned employee context and employee delivery are denied42501.
5. A normal booking has employee assignment only on its actual booking, not copied into its paired order. Employee starts and enters quality-check using the canonical API. Raw booking completion and raw paired order completion reject55000. Hold canonical completion transaction open: an independent read still sees booking in_progress/order quality_check. Same-nonce second completion waits; after commit both are completed and exactly one span is closed. This tests atomic visibility, replay and preserved booking-side authority.

No collections, refunds, fake booking for walk-ins, wage/rate edits, source loyalty updates or manual occupancy updates. This is local protocol QA, not physical service evidence.

## Cleanup and proof

A0600 journal is written before mutations and stores only fresh IDs, actor IDs, tags and hashes; no tokens, phone/name payloads, raw secret or HTTP bodies. A finally block rolls back/closes only owned sessions, recovers/fences known commands, cancels only eligible received/pending unpaid work, finishes only known tagged QA active work through quality-check/completion APIs, and hides only the new branch/service. Completed unpaid QA invoices are retained honestly; do not synthesize cash/refunds/cancel/void to remove completed records. Failed/ambiguous cleanup is explicitly reported for manual review, with no automatic rerun.

If an outbox job appears, assert every pending job belongs to a known newly created QA order before calling the actual worker. No manual processed/earning state. Require outbox empty and unchanged canonical/legacy loyalty ledger afterward.

Require all preexisting public/private rows unchanged (document counters excluded and separately checked), original Auth identities unchanged, borrowed HR rows identical, global payment ledger unchanged, new invoice money/document snapshot hashes unchanged, no open new QA span, and INV/BKG counter deltas exactly equal actual new invoices/bookings. Failed inserted transactions must allocate no lasting numbers. Preserve all QA/audit rows; no deletion.

## Invocation (root review/release required)

```sh
python3 tools/service_work_kernel_concurrency.py
python3 tools/service_work_kernel_concurrency.py --execute \
  --contract-state /Users/user/Documents/Codex/2026-11-12/v/work/runtime/walkin-financial-concurrency-state.json \
  --contract-proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/walkin-financial-concurrency-proof.json \
  --state /Users/user/Documents/Codex/2026-11-12/v/work/runtime/service-work-concurrency-state.json \
  --proof /Users/user/Documents/Codex/2026-11-12/v/work/runtime/service-work-concurrency-proof.json
```

Existing output paths cause refusal; archive evidence explicitly before an approved retry. SQL session/HTTP failures are sanitized to stage/class/code, never raw transcript or request/response body. This harness does not enable loyalty, ETA, tax certification, guest claim access, active stop/refund, or queue UI acceptance.
