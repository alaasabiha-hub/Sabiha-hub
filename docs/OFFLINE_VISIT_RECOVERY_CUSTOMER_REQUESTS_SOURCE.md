# Customer previous-visit recovery request: prepared source slice

CLI-created migration `20261114225006_offline_visit_recovery_customer_requests.sql` and `supabase/tests/offline_visit_recovery_customer_requests.sql` are SOURCE ONLY, unapplied and unexecuted. The already-applied inbox migration222258 is unchanged. No library/main/build/handoff, old claims, trusted links or history logic is changed.

This slice accepts an actual customer's request for information matching. It does not search legacy records, create a canonical claim, bind a profile, approve anything, issue credit or change invoice access. There is no owner action, candidate-list, phone matching, frontend route or public event-creation endpoint.

## Minimal actual API

* `submit_visit_recovery_request(p_request uuid,p_consent jsonb)` accepts ONLY the stable nonce and exact consent `{accepted:true,version:"visit-recovery-v1",language:"ar"|"en",text:<fixed server notice>}`. The internal fixed notice explicitly says the request does not automatically link records or grant access/rewards. No caller-supplied email, phone, requester/profile ID, old receipt or free-text payload is accepted.
* `get_my_visit_recovery_request(p_case uuid default null)` returns only the caller's opaque own case reference/status/time, whether current account details still match the original snapshot, and fixed bilingual pending texts. Null discovers the own existing case. Foreign/unknown IDs have identical `{state:"unavailable",case:null}`. Own reads still require current real session, confirmed email and valid actual registered phone.
* `get_visit_recovery_request_for_review(p_case uuid)` requires a current active owner with actual Auth session. Returns only case reference/status/time and identity-current flag; no customer ID, raw or hashed contact data, profile candidates, amounts, visit history or tokens. Managers/cashiers cannot use it. Opaque case IDs originate from owner-pool inbox notices, not a public directory.

All available projections say `approval_available:false`, `canonical_claim_created:false`, `link_created:false`.

## Real identity and idempotency

Identity uses the APPLIED `private.app_inbox_actor()` real Auth/session/active-role locks, followed by current `auth.users.email/email_confirmed_at` and the customer's ACTUAL `public.customers.phone` under a customer-row share lock. Registered phone is normalized with the existing EG normalizer and stored only as a SHA256 domain-separated fingerprint; email is stored only as its normalized SHA256 and actual confirmation time. An observed registered phone is not proof of phone ownership and never links an old identity.

A global submission nonce lock precedes identity locks, then a customer-specific mutex serializes case selection/creation. A partial unique requester index enforces one awaiting-matching envelope even under simultaneous different nonces. Same nonce/unchanged consent reuses the actual case; same nonce/changed consent rejects. Another nonce while an envelope exists maps to it without replacing the original fingerprints or consent and emits no new notices. Changed valid registered details produce `identity_current:false`, not automatic re-matching or re-binding. An unconfirmed email, nonexistent/expired session, invalid phone, deleted/banned account fails closed.

Each newly created case appends exactly one `recovery_received` event to its exact customer and one `recovery_submitted` event to the current owner pool via the existing PRIVATE inbox append helper. Case, nonce receipt and BOTH events share one transaction. A failure on the second event rolls back the case, receipt and first event. No notifications are backfilled and no existing order notification rows are reused or altered.

## Source fixture and remaining gates

The isolated rollback source selects existing real sessions/customers/owner/manager; no Auth accounts are created. It covers fixed consent/extra-key rejection, same/new nonce replay and one open case, exact2 events, cross-account/owner-only reads, fake-session rejection, temporary registered-phone and email-confirmation drift restored inside subtransactions, changed consent, private grants, append-only records and forced second-inbox-event atomic rollback. Existing canonical claim/link counts remain unchanged. It has NOT run; no SQL/runtime result is claimed.

Root must review/apply/static-check/rollback-test and later prove actual simultaneous same/different-nonce submissions using existing local accounts and legitimate windows. No existing inbox/claim/history acceptance needs repeating wholesale.

There is intentionally no close/amend/more-information/reject/approve operation in this slice. Until durable action/close fences and the canonical proof bridge follow, a future client must retain an uncertain submit UUID and recover rather than treating absence as permission to abandon/reset it. This source has no client implementation. Later owner actions must preserve original fingerprints/events, use immutable explicit evidence, and invoke the existing canonical claim/link engine rather than inventing automatic phone-match approval.
