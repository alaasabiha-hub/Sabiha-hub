# Free offline customer claim — implementation contract, not acceptance

User correction: cashier never handles customer email/password/Auth. Current app email/password/phone registration and email confirmation stay unchanged. No paid SMS dependency. Existing customer/vehicle/booking/invoice UUID primary keys and relationships remain unchanged.

## Proof and authority

A cashier-entered contact is observed, not verified. Normalized phone, name and plate can locate intake candidates but cannot authorize reading old history, redeeming benefits or transferring ownership. Email confirmation proves the new app account email, not the old car/customer record.

New offline enrollment may issue a server-random receipt secret once. Store only its cryptographic hash; do not persist the raw secret in retry storage, logs, analytics or a recoverable registration result. Replaying registration must not reissue a secret. Reusing an existing intake profile cannot replace its secret. Lost-response or lost-receipt cases go to owner review.

Future linking requires all of: an authenticated app account with actual server-confirmed email (not public profile flags or editable metadata); fresh customer consent bound to the profile/contact version/account/request; proof of the originally issued receipt secret when available; and a separate active-owner review/approval. The cashier who issued a receipt cannot alone approve transfer. A secret is continuity evidence, not an absolute identity guarantee; suspected theft, shared/recycled numbers and conflicting accounts remain blocked for review.

Legacy records without a receipt and lost-secret claims require in-person owner review under a documented evidence procedure. No automatic fallback to phone/name/plate matching. A generic discovery response must not reveal whether another person has history, points, invoices, cars or an existing account. Rate limits apply before candidate discovery and secret verification.

## Transactions and revocation

Bind challenge/decision to immutable profile ID, claimant Auth UUID, contact version, reviewed evidence reference, purpose and expiry. Lock profile and claimant in a fixed order; consume approval once with an exact request receipt. Concurrent claims cannot link two accounts or move ownership. Store audit decisions without raw secrets or unnecessary personal documents. Reject inactive owners, stale contact versions, changed accounts and mismatched payloads.

Changing a contact never silently reassigns previous history. Keep observed-contact history separate from verified links. Conflicts between two app accounts require review; no automatic merging or UUID rewriting. Revoking a link removes access while preserving original visits/invoices/loyalty ledger.

## Visibility and finance dependency

A reviewed link grants only explicitly integrated readers. Every customer history, vehicle, invoice/QR, private image, reward balance and export path must independently enforce the trusted active link. Existing auth.uid-based accounts continue unchanged. Do not enable the link until all intended read paths pass cross-customer tests.

Walk-in visits use an independent business customer identity without fake bookings/Auth users. Accrual needs completed service plus trusted confirmed payment; redemption needs transaction-specific customer approval and current owner rules. Shared-source allocations and refund/cancellation idempotency must be tested before activation.

## Acceptance still required

Enrollment without email; exact/recovered registration; duplicate and shared-phone candidates; receipt loss/theft; verified email with wrong receipt; stale/changed/recycled phone; owner/customer/cashier isolation; concurrent claims; revoke/relink; historical UUID invariance; actual Flutter visibility of prior visits/cars/invoices/rewards. No production edits or SMS charges.

Current status: contract only. Private enrollment foundation and Flutter module are in development. Claim/link/history adapters and Walk-in finance are not implemented or accepted by this document.

Auth reference reviewed: https://supabase.com/docs/guides/auth/phone-login . Phone possession is distinct from continuity of a historical business identity; the free flow above does not send SMS.
