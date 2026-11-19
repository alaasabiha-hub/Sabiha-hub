# Disabled foundation — source compatibility review

2026-11-15. Read-only source review plus an authorized correction to the **unapplied**211249 draft and its fixture. No DB call, application, accepted test rerun, library edit or build. Source conclusions below are not a live SQL pass.

## Real issue found and fixed before application

Adding `offline_channel_terms` changes `to_jsonb(old_policy_row)`, even when the value is NULL. Original `get_loyalty_policy` returns that whole row as `current`; original `save_loyalty_policy` uses it for both new-save and exact-replay replies. Consequently, unchanged stored column values alone were insufficient to guarantee the old JSON contract.

The draft now adds `private.legacy_loyalty_policy_response(private.loyalty_policy_versions)`, an explicit projection of the ten original fields: version_no,version_id,branch_id,offer_id,eligible_service_ids,enabled,policy_snapshot,request_payload,created_by,created_at. Only the three whole-policy serialization sites in get/save are redirected to that projection; their owner check, locks, validation, request-payload comparison, policy insertion and grants remain the original code. No existing stored snapshot/result/hash is changed. NULL-valued original keys remain present, just as before. The new column is not silently added to old owner API replies; future offline configuration needs its own explicitly versioned contract.

Prior draft, fixture, scope document and original manifest are preserved at `work/runtime/source-drafts/offline-service-visit-before-policy-projection/`. Original migration SHA was20aefb283e2d337c8cfc8812c9b0d7c6c859f2911ab0a9144ed93d4e00b7cfac. Updated manifest records the new hashes.

## Exact latest prepared source inspected

| Path | Serialization / compatibility finding |
|---|---|
|112706 `get_loyalty_policy`, `save_loyalty_policy` | Actual whole-policy response issue above; draft projection fixes new/read/replay outputs without changing stored JSON. `request_payload` equality remains the existing explicit legacy payload. |
|133029 `activate_loyalty_visits` | Reads named policy fields/version, returns `to_jsonb(a)` for **loyalty_visit_activations**, a table not altered. Exact request replay precedes scheduler freshness check as already accepted. No whole policy digest. |
|133029 `evaluate_loyalty_visit`, `reconcile_loyalty_visit` | Named policy/binding/booking/invoice/payment fields; frozen `policy_snapshot` JSON and explicitly built `facts`. Canonical rowtype expands but no whole-row JSON/hash/composite equality is used. Existing credit IDs/facts and explicit insert columns remain unchanged; source_channel defaults booking and old customer/booking fields satisfy conditional checks. |
|145141 rule save;151246 latest rule context | New rule terms are explicitly built from named policy fields and `v.policy_snapshot`; stored `terms_snapshot`/request results remain untouched. Whole rule-row JSON concerns **loyalty_redemption_rule_versions**, not the altered policy table. |
|162047 latest `quote_service_reward` / public quote sanitizer | Fingerprint hashes explicit payload, stored rule terms, earning ID array, allocation snapshot/credit_terms, gross and deadline. No whole policy/earning-row hash. Replay uses the existing stored quote/fingerprint and own payload. Quote table unchanged. |
|150907 `place_customer_reward_booking`, creator and coverage | Compares stored quote fingerprint, explicit payload, actual earning IDs and exact `reward_credit_terms`; no whole policy/credit record digest. Issued coverage/document snapshot inputs remain unchanged. |
|161505 latest `reward_credit_terms` | Explicit original/selected rule IDs, version ordering, frozen expiry and latest-activated adoption rule. Added policy/ledger columns are neither serialized nor part of credit_terms; old cohort rules and expiry remain identical. |
|155548 latest `sync_customer_rewards`;150906 lots/refund/claim guard | Named customer/earning/invoice/refund/offer fields and existing facts JSON; claim UPDATE whole-row check serializes **reward_credit_claims**, a table not altered. No whole canonical/policy hash. Existing expiry, debt, restore/forfeit and refund identity logic is unchanged. |

No positional `ROW(...)::private.loyalty_policy_versions` or `::private.canonical_loyalty_visits` constructor was found in reviewed source. No altered-table whole-row serialization feeding a stored rights/quote fingerprint was found beyond the owner response sites. This is a migration-source inventory; root should compare actual function definitions/static checks before application if manual server-only refreshes differ.

## Fail-closed and remaining risks

The existing claim guard contains a nullable comparison `e.customer_id<>new.customer_id`. It must not be reused for active offline credits: NULL would not prove owner equality. The proposed stage remains safe only because EVERY offline credit insert and every runtime enable attempt is fenced, so no NULL-customer credit can exist through this draft. Typed owner equality across claims/refunds/quotes and every existing writer is an explicit mandatory dependency before any future relaxation. This review does not authorize activation or claim the typed allocator complete.

Schema-level row fingerprints necessarily change shape: old ledger rows gain NULL offline fields and source_channel booking; old policy rows gain NULL offline_channel_terms. Pre/post-DDL **test** fingerprints must project original columns while retaining every old value; do not rewrite production rows/hashes to manufacture equality. Stored facts/terms/quote fingerprints are not recalculated. Immutable row triggers continue to reject history/owner changes. FK/index retention and PostgREST schema cache/static checking remain local application checks.

The fixture now captures independent golden old policy JSON (`to_jsonb(row)-offline_channel_terms`), checks existing owned exact-save replays and active-current reads, checks normal new-save/replay/read against that golden projection, and proves all original policy JSON/facts/payload remain unchanged after additional fixture versions. It also retains the prior disabled-source/ledger/function-definition assertions. It does NOT recreate or rerun accepted earning/refund tests. Root executes this new focused source only after the current exclusive browser window.
