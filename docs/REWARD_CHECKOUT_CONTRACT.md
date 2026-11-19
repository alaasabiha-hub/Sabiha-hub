# Canonical booking reward checkout — development contract

Source A `20261114150906`, B `20261114150907`, and the separate reward-reader migration must all pass local acceptance before enabling any rule version. No owner activation or historical adoption is seeded. Walk-in, product rewards, partial redemption and stacking remain unsupported. Money stays EGP; visits have no invented cash conversion.

## Public own-customer APIs

`get_service_reward_options(p_service uuid,p_branch uuid)` returns `redemption_enabled`, `unit:service_visits`, `programs`, and unsupported-capability flags. Each program has `policy_version_id,rules_version_id,offer_id,branch_id,threshold_visits,reward_service,rules,terms_snapshot,available_visits,pre_rule_visits,eligible,blockers`. Blockers contain `owner_review_required,outstanding_refund_debt,eligible`. Different programs can use the same visits; never add their counts.

`quote_service_reward(p_request uuid,p_service uuid,p_branch uuid,p_vehicle uuid,p_date date,p_time time,p_policy_version uuid,p_rules_version uuid,p_notes text default null)` creates an immutable ten-minute maximum quote without reserving visits. Success includes `eligible:true,quote_id,fingerprint,gross_amount,reward_discount,amount_due:0,currency:EGP,threshold_visits,terms_snapshot,expires_at,adoption_required`. Four explicit rules are at `terms_snapshot.rules`. Quotes use actual reward-service price and specific actual earning lots. Old earning cohorts retain original expiry; unbound pre-rule visits require explicit quoted adoption. An expired retry keeps the snapshot but returns `eligible:false,reason:quote_expired`. Other blocked reasons include `checkout_not_fully_installed,actual_activated_reward_terms_required,refund_review_or_offset_required,actual_service_vehicle_or_branch_unavailable,appointment_unavailable,insufficient_actual_eligible_visits,frozen_expiry_passed`.

### Durable preparation, retry, recovery and close — both modes

Persist only the placement request UUID locally. All placement fields live on the authenticated customer's server attempt. Freeze all parent details and both mode selectors as soon as placement becomes uncertain, including ordinary full-price bookings.

`prepare_service_booking_attempt(p_request uuid,p_mode text,p_payload jsonb)` prepares exact immutable fields. `p_mode` is `normal` or `reward`.

Normal payload has exactly `p_service,p_branch,p_vehicle,p_date,p_time,p_expected_price,p_notes`. UUID/date/time/numeric values are normalized by the server; empty notes normalize to null. Reward payload has exactly `p_quote,p_fingerprint,p_accept_terms,p_adopt_existing_visits`; both flags must be explicit and adoption must be true when the quote requires it. Save/reuse the returned normalized `payload`, not a freshly read form.

`get_service_booking_attempt(p_request uuid default null)` returns `state,request_id,mode,payload` and either `result` or own-only `form_context` for an open reward quote. Null request recovers the latest unresolved/unacknowledged own attempt. `state` is `open,succeeded,closed,absent,different_mode,manual_review_required`. A succeeded result contains current booking/payment/redemption status. `absent` never proves a delayed request cannot arrive.

`close_service_booking_attempt(p_request uuid)` is the only authoritative abandon operation. It creates a permanent tombstone even for an absent request. Both normal and reward creators check this under the same nonce lock. If booking creation won first, close returns `succeeded` instead of cancelling it. A delayed prepare/create cannot reopen a closed request. Unlock the form only after `closed`, or after displaying a successful receipt and acknowledging it. Different-mode/manual-review responses stay blocked pending review.

`acknowledge_service_booking_attempt(p_request uuid)` returns `state:acknowledged,request_id` only for an own successful receipt. It does not cancel or change invoices.

Normal placement remains the original eight-argument `place_customer_service_booking` RPC. Prepared normal calls pass the exact server payload. Legacy callers without preparation remain compatible, but closed/wrong-mode attempts are always enforced.

Reward placement is `place_customer_reward_booking(p_request uuid,p_quote uuid,p_fingerprint text,p_accept_terms boolean,p_adopt_existing_visits boolean default false)`. It requires the prepared matching reward attempt. Successful exact retries return the original receipt before quote expiry checks. New placement rechecks actual price, appointment, actual refunds, lot availability, frozen terms and consent atomically. It returns `booking_id,order_id,invoice_id,booking_number,invoice_number,quoted_price,gross_amount,reward_discount,amount_due:0,currency:EGP,payment_status:covered_by_reward,collectible:false,quote_id,rules_version_id,policy_version_id,visits_consumed,rules,source_channel:booking,branch_id`.

For definitive SQL errors, retain the attempt until explicit server close succeeds; a transport failure never unlocks it. SQL `40001` means an unconsumed quote expired/changed, `22023` invalid consent/payload or mode, `55000` closed/missing attempt or unavailable program/debt; `42501` denies access. Recover first after any uncertain response, and use exact prepared fields for retry. Do not infer failure from error text or an absent lookup.

`get_customer_reward_booking` and `acknowledge_customer_reward_booking` are compatibility aliases for generic recovery/acknowledgement.

### Wallet and immediate refresh

`get_my_reward_wallet()` synchronizes actual refunds and returns `unit,programs,pools_overlap:true,global_spendable_balance:null,consumed_reward_visits,refund_offset_visits,redemption_supported_channel:booking`. Each program reports immutable rules/pool identity, `threshold_visits,unused_valid_visits,adoption_required_visits,blockers`. Refresh after placement, cancellation and recovery. Existing canonical `net_visits` remains lifetime earning minus refund, **not available balance**. Never combine these with legacy points.

## Owner controls

`activate_loyalty_redemption(p_request uuid,p_rules_version uuid)` explicitly activates saved rules only after all readers/backend and actual recent earning scheduler execution exist. Retry is idempotent and current active-owner authorization always applies. No activation occurs by saving rules. New booking earning bindings capture the latest activated rule for that frozen earning policy; existing bindings stay unchanged.

`list_reward_refund_reviews(p_branch uuid default null)` synchronizes actual refund facts and returns owner-only review/debt rows. `resolve_reward_refund_review(p_request uuid,p_review uuid,p_note text)` acknowledges a freeze with an audit note. It never mints visits or waives debt. Eligible future bound visits within the same actual offer+branch offset debt. A restored cancelled reward releases original claims/offset claims without reviving refunded/expired visits; forfeited cancellation preserves debits.

## Financial proof and integration

The internal creator has no client/service execute grant. Receipt, allocations and cover event precede final invoice INSERT in one transaction; the invoice FK is deferred. Final invoice due is zero and discount equals actual gross; original order-item amount and booking quote remain gross. Commission basis remains `invoice.total+invoice.discount`. No fake cash/card sale is created. Server-only `reward_snapshot` cannot be appended to or changed on an issued invoice.

`private.reward_invoice_coverage(text)` is trusted internally only after checking consent, quote/receipt identities, actual unique allocations, ledger witness, zero amount, original gross, no payment events, and coherent active/void states. Reader code must classify coverage only from this helper; normal zero invoices are never assumed rewards. Cancelled/void states take precedence.

The legacy finalizer must preserve old replays but reject new canonical earning-bound orders and actual reward coverage before selecting an unrelated unmanaged offer. Old invoices, historical snapshots, balances and commissions are not backfilled or repriced.

## Validation status

A+B source is not applied by this agent. `supabase/tests/canonical_reward_checkout.sql` is a rollback-only acceptance fixture including real earning/cash/refund, four explicit rule combinations, adoption, quote/claim/recovery, late tombstones, debt/review resolution, cancel restore/forfeit and reader assertions. Parent owns application and execution; no success is claimed until those checks and two-session concurrency pass.

Refund-sensitive synchronization and reward placement use a twenty-second database lock timeout and require READ COMMITTED. A `55P03` lock timeout keeps the prepared attempt unresolved; recover or retry exact server fields, then use authoritative close if abandoning. Synchronization locks invoices backing active claims in deterministic invoice order, and locks any newly discovered offset candidate before re-reading its actual refund and expiry. This includes refund races on offset debt credits, not only the visits selected by the new quote.

The additive owner-reference migration `20261114155346` enriches review rows with actual `customer_name,invoice_number,booking_number,created_at,service_name,redemption_status`. Booking number may be null for a future non-booking channel; clients use a labelled reference fallback. Authorization remains active owner only. The original UUID fields remain stable.

Parent verification on 2026-11-14: A/B/reader C and the three focused follow-ups applied locally. The complete rollback acceptance passed all four rule combinations, deferred coverage constraints, owner-reference/reader/readiness/legacy-replay assertions and forgery boundaries. Public/private row fingerprints were unchanged (`044fda…`). Local `plpgsql_check` found no actionable error after the targeted namespace fixes; its sole cross-table trigger warning is guarded by `TG_TABLE_NAME`, and both runtime branches were exercised. The two-session acceptance helper remains a separate required proof; no production activation or hosted action is implied.

Cohort-order follow-up `20261114161505` prevents choosing an older activated rule to consume a newer-bound credit. A selected rule must be at least as new as the earning's immutable bound rule. A newer selected program may use older credits within its explicit policy/offer-branch pool, with newly quoted benefit terms and original credit expiry preserved. An unbound pre-rule credit can be adopted only through the latest activated rule of the selected earning policy, with the existing explicit adoption consent. No historical bindings are seeded or changed. The targeted rollback `supabase/tests/reward_rule_cohorts.sql` checks both directions, old-program availability for its actual cohort, expiry preservation, actual quoted placement under newer consented terms, and explicit offer/branch pooling across policy versions.

Parent subsequently reported the real two-session reward checkout suite passed, including the offset-credit refund race; the cohort-order tightening is verified separately with the focused rollback fixture rather than repeating unchanged concurrency cases. Its validation status must be taken from the parent-run local proof, not inferred from migration creation.

Customer-copy privacy follow-up `20261114162047` explicitly whitelists quote/consent response fields, nested offer/service/rules and allocation credit provenance. Audience UUID arrays and unknown internal metadata remain private, including during prepared-attempt recovery. Eligibility still evaluates the original immutable private audience; full private terms, quote hashes and fingerprints remain unchanged. The focused rollback `supabase/tests/reward_targeted_terms_privacy.sql` checks two included audience members, an excluded customer, fresh/cached quote/options/recovery/wallet copies, nested unknown metadata rejection and successful placement using the original fingerprint. Parent executes this before browser acceptance; migration creation alone is not proof.

Parent local verification: the cohort-order migration and its focused rollback passed with identical before/after fingerprint `1d0a7b…`. The customer-copy privacy migration and multi-target rollback also passed with identical before/after fingerprint `1d0a…`; frontend browser acceptance was then released. These follow-ups leave existing invoices, private quote fingerprints and historical bindings unchanged.
