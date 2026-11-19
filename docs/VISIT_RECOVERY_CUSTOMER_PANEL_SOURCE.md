# Customer request/status panel — source and mocked UI acceptance

`lib/visit_recovery_request.dart` exposes `VisitRecoveryRequestPanel(client: ...)` for an existing Profile/history host. It is NOT imported or routed by main and does not add an owner screen, inbox duplicate, frontend redesign, matching, claim attachment or data lookup by phone/profile. The existing shared inbox component remains separate.

The panel fetches the actual server `visit-recovery-v1` notice and requires an unchecked explicit consent checkbox. Submit sends ONLY stable request UUID and that exact notice/language/version/accepted body. Status label, receipt message and in-app notification notice come from the actual response, including the user-requested exact Arabic strings. No case/nonce UUID or ISO timestamp is displayed as a customer-facing label. Registered account drift is shown as requiring independent review, not automatic matching.

`VisitRecoveryController` and gateway/store interfaces are independently testable. Local storage contains only actor-scoped UUID, never consent, phone/email/profile/claim data. It refuses to overwrite another pending reference or clear a different expected UUID. In-memory retries preserve exactly the original UUID and consent, including storage/network failure. Restart recovers the exact server nonce: accepted→actual current receipt; absent→frozen with explicit safe close (never reconstruct consent or rotate UUID); closed→actual closed result. Close that loses to creation shows the received case, not cancellation. The user reviews accepted/closed receipt before local UUID clearing; a closed acknowledgement resets consent before a new explicit request is possible.

Every awaited result checks actor and epoch. The initial matching GoTrue session replay is ignored using the existing accepted helper; real Auth changes clear data/consent immediately and reject late results. Same-bound-actor refresh performs a fresh server check; another actor must reopen a newly scoped component. Authorization/protocol errors reveal no raw backend error or cached private data. No automatic background close or business submission occurs.

## Backend dependencies

Applied request225006 and owner-review225809 provide current notice/status projections. Restart helper migration `20261115001715_offline_visit_recovery_submission_restart_fence.sql` is another agent's frozen source dependency (SHA66a0adb5cccf7bf6f31a7baa977002e2d5b1bdc6a1413f5f626dddc5675114ab at notification); deployment/application status is ROOT-controlled and not established by mocked UI tests. Required exact APIs:

* `get_my_visit_recovery_request(p_case:null)`;
* `submit_visit_recovery_request(p_request,p_consent)` (normal available result; late closed nonce yields explicit closed envelope);
* `get_my_visit_recovery_submission(p_request)`;
* `close_my_visit_recovery_submission(p_request)`.

Accepted restart envelope must echo the exact UUID, stored consent and current available result. Closed must echo UUID, null payload/result and `definitive_failure:true`. Absent is explicitly nondefinitive. The component fails closed on mismatched or malformed results. Canonical bridge232751/receipt finder is not called, even when later available.

## Verification actually performed

Eight NEW targeted cases PASS in `runtime/visit-recovery-request-tests.log`: AR390/EN1440 explicit consent and exact receipt; stable storage+lost-submit retry; restart absent/lost-close/closed acknowledgement; creation wins and malformed/wrong nonce; matching initial Auth replay plus real signout/late result; denied access; UUID-only actor storage and exact-reference clearing. Targeted two-file analyze is clean. Client construction/disposal occurs outside Flutter FakeAsync with explicit widget unmount; no hanging process remains.

No DB calls, real Auth/account writes, financial writes, browser, web/native build, main wiring or old accepted suite reruns were performed. These are mocked source/widget proofs, not actual server/browser end-to-end acceptance. Root owns backend rollout, route integration and any later actual acceptance.
