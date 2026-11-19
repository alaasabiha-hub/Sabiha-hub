# Existing canonical claim attachment — source bridge, not a new identity engine

CLI-created migration232751 and focused rollback fixture are UNAPPLIED/UNEXECUTED. Parent225809 is verified frozen SHA256 `a0a4b10742e1f6e57f3d036b7f877213bc40e1ba654563ab7f439b56c1a517d3`; no applied source is edited. Existing canonical claim creation/decision/revoke functions are not replaced. Their proof, quota, expiry, immutable evidence and nonce rules remain authoritative.

## Actual proposed path

`attach_my_visit_recovery_claim(p_request,p_case,p_claim)` accepts only three UUIDs. Claim must already belong to the current real customer; case must belong to the same customer and retain the exact CURRENT confirmed-email and registered-phone fingerprints. It calls no claim/profile/receipt/link creator, accepts no phone/profile target, and never compares registered phone to a legacy profile phone as ownership proof.

Lock order: attachment nonce → canonical `offline-claim-request:<claim>` → canonical Auth mutex → actual claim profile mutex → same contact-set SHARE freeze as canonical approval → actual Auth/session/customer identity locks → requester-envelope mutex → case row. No canonical request mutex is acquired after Auth. Existing canonical direct/prepared decision/revoke writers already take their own nonce/Auth/profile locks; their new AFTER INSERT hooks proceed only to the requester mutex and case. No case-locked wrapper calls a canonical writer. Unmapped legacy canonical writers return without any new case/session behavior.

A REAL profile-bound claim must reference its actual enrollment receipt/profile, actual customer actor and current canonical email/contact fingerprints. Original-receipt mode still needs original secret proof. Lost-secret mode is only a pending request until an actual owner `approve_exception` with the existing permitted independent in-person evidence type. A private one-to-one map cannot itself grant records or fabricate proof.

Unknown lost-secret pending shells deliberately have no profile. They stay UNMAPPED, with exactly the same opaque own-case pending response as a real pending attachment. No mapped/existence flags, profiles or candidate information are returned to the customer. Rejected, stale or previously revoked evidence also cannot create a live mapping. Exact attachment nonce replay does not repeat business events; changing case/claim under a nonce rejects. A true existing map cannot be replaced or transferred to another case. The unmapped225809 more-info/reject path remains usable for unknown/unapprovable shells, so no pending approvable canonical claim is orphaned.

## Canonical event authority and commit orders

AFTER INSERT on `offline_claim_decisions` and `offline_claim_revocations` covers ALL existing direct and prepared canonical writers, not only a new UI wrapper. For mapped cases:

* Actual hold → more_info and fixed customer notice.
* Actual reject → rejected and fixed customer notice.
* Actual approving decision + exact live trusted link + original proof or permitted independent exception + case/actor/email/contact consistency → linked and fixed approved notice. A terminal case aborts a later mapped canonical decision transaction.
* Actual revocation of that link → revoked/access-ended notice. Revocation remains allowed after phone/email/contact drift because it removes access; it does not grant it.

Event/source identity is the actual canonical request UUID. Append-only validated witnesses bind exact claim/case/link/decision or revocation, original event time and current transaction ID. The case identity guard permits linked/revoked only with such a witness. Case status, event, fixed inbox notice and the canonical decision/link/revocation are ONE transaction: inbox or validation failure rolls back the canonical write too. Replays do not insert another canonical row, hook event or notice.

Attach-first: real pending map commits, then the canonical decision hook sees it. Decision-first: the old unmapped decision creates NO guessed case event; a later explicit customer attachment verifies the actual existing unrevoked link and adds a NEW `attach_existing` event keyed to that attachment nonce, with the actual original decision reference/time retained separately. No historical notice is fabricated or backdated. A revoked/consumed old mapping cannot be imported into a new case.

Customer status texts reuse applied fixed bilingual templates. Before true approval, metadata remains opaque. After linked/revoked, projection reports actual attachment/current-link validity and explicitly says record access still needs fresh history scope/reader authorization. It does not assert that attachment created a new claim/link or grants automatic history, credit, rewards or ownership. Current owner case projections gain the actual canonical claim reference for routing to EXISTING canonical review actions; case-level approve remains unavailable, and mapped more-info/reject uses existing canonical hold/reject rather than the unmapped fallback.

## Source acceptance and limitations

The rollback source uses existing real sessions/accounts, temporary registered phones inside rollback, real isolated intake receipts and real canonical claim APIs. Registered account phones intentionally differ from private legacy profile phones. It covers foreign claim/case rejection, immutable-case phone drift, pending opaque attachment/replay, direct hold, prepared approval with forced inbox failure rollback, both logical decision/attach orders, independent lost-secret exception, true existing link import, revocation after drift, already-revoked evidence, canonical rejection then forbidden approval, unknown shell/no enumeration/unmapped rejection, one notice/event per canonical UUID and private writer grants.

This source has NOT run. Its sequential transaction statements establish logical ordering fixtures, not a claim of real concurrent commits. Root still must review/static-check/run rollback and actual two-session races: attach-first vs decision-first, revoke-first vs attach, fallback rejection vs attach, contact/phone drift and inbox rollback. Legitimate claim budgets are checked; no quota reset, new Auth account or production data change is permitted. No UI, receipt proposal/autofind or guest financial consent is implemented. This enables only the existing-receipt proof bridge once accepted; it does not complete every receipt-less recovery journey.
