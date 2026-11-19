# Private typed offline reservation component

Source-only migration `20261114225604_typed_offline_reward_reservations.sql` adds private reserve/release operations to the existing reward quotes and credit claims. It creates no credit ledger, scheduler, public spend API, reward invoice, cash event or Auth identity. Existing runtime earning/read flags remain untouched. No SQL acceptance or database application has been performed by the author.

## Typed ownership and compatibility

Existing rows default to `auth_customer`; conditional checks preserve their required customer/vehicle/date/time fields. Offline rows instead require the actual private profile, car reference, channel version and operator. The existing unique active claim per earning remains the occupancy authority. Offline holds use `kind=reserve`; reward consumption and offset/debt rows remain explicitly fenced. Added offline metadata in redemptions/refund reviews is deliberately unusable until those writers are implemented.

Old Auth quote replay, claim validation, refund-review iteration/resolution, coverage proof and invoice guard explicitly reject null or offline ownership. Auth reconciliation rejects null/noncustomer IDs. The existing explicit customer quote response projection stays unchanged; new private fields are not added to old customer responses. No stored quote/terms/fingerprint or historical invoice is rewritten. Schema additions do change whole-row JSON; preservation checks must project added columns away when comparing prior rows.

## Private contracts and locks

`reserve_offline_reward_candidates(request, profile, car, channel, expected_gross)` returns request/quote IDs, state, immutable fingerprint/expiry, held visits, and explicit consumption/issuer false. It requires a current actual active owner, READ COMMITTED, exact DB reward-service price, real same-owner candidate lots and original cohort/expiry. No history-link consent or phone knowledge grants this operation. All new functions are revoked from PUBLIC, anon, authenticated and service_role; there is no public wrapper or financial-consent bypass.

Locks acquire `reward-offline-profile:<profile>` before `offline-reward-reserve:<request>`, then source invoices in deterministic invoice order. Candidate facts are reread after financial lock waits. A changed request payload is rejected; the same nonce replays its result and cannot reserve again after release. Holds expire at the earliest of five minutes, original credit expiry and selected frozen benefit expiry. Expired/refunded holds are released before new allocation under the same owner lock. No background sweeper is installed; an idle expired hold can remain physically active until a new reservation/replay/release, while it cannot become consumption.

`release_offline_reward_reservation(request, reason)` audits and releases unconsumed claims once; actual source refund yields `refunded`, elapsed expiry `expired`, otherwise `released`. One-way claim release requires a same-transaction event witness. Deferred constraints prevent incomplete preparing commands or partial threshold holds from committing. An owner may release another owner's private component hold; creating/replaying it remains restricted to its original operator.

## Acceptance sources, not executed

* `typed_reward_schema_compatibility.sql`: outer rollback; missing privileges, Auth projection/required fields, null-owner and unimplemented offline issuer/debt rejection.
* `offline_reward_reservation_assertions.sql`: temporary helpers to attach to a real earned-credit fixture; reserve/replay/change rejection/release, original terms, no financial writes, actual full refund before reserve, and bounded real expiry. The expiry helper requires an original expiry within ten seconds; no fake clock or immutable-row edits.
* `offline_reward_reservation_concurrency.py`: Python syntax checked only. Default prints its plan. Root must provide a journal-proven QA fixture with exactly a threshold of real eligible credits before explicitly executing. It observes real lock waits for same-nonce replay and competing-nonce occupancy, releases only journaled holds, and compares every preexisting public/private row. It does not create/refund money or earn credits.

Root should run static PL/pgSQL checks, DDL plus rollback fixtures and reviewed two-session proof before any application. Existing accepted earning tests need not be repeated wholesale.

## Remaining boundaries

This is a usable internal reservation component, not completed offline redemption. Independent financial consent and current-session authorization, durable public attempt/close recovery, consumed allocations, refund debt/review/resolution, cancellation restore/forfeit, authoritative spendable wallet, zero-due typed invoice issuer and gross-before-benefit commission proof are still required. No customer balance or redemption capability may be advertised from this component. There is no credit transfer on account linking, no points conversion, no historical adoption and no automatic program activation.
