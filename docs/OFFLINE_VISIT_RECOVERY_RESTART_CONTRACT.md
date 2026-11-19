# Customer recovery submission restart fence — source-only follow-up

The additive CLI-created migration is `20261115001715_offline_visit_recovery_submission_restart_fence.sql`. It does not edit applied225006/225809/232751, create claims/links, match phone/profile data, change ownership/read scope, delete cases or alter existing notifications.

## Exact RPC contract for the customer UI

Both new authenticated public SECURITY INVOKER wrappers accept only `p_request UUID` and call private guarded implementations. Both require actual current registered-customer identity/session through the existing `visit_recovery_request_identity`; no caller-supplied phone, email, profile, proof or staff metadata. They share `visit-recovery-submit:<UUID>` before identity locks with the original producer, use READ COMMITTED and20-second lock timeout.

`get_my_visit_recovery_submission(p_request)` returns exactly one envelope:

* Accepted: `{state:'accepted',request_id,payload:{consent:<EXACT stored consent JSON>},result:<CURRENT get_my_visit_recovery_request(original_case_id)>,definitive_failure:false}`. The stored request's payload is returned, not the case's potentially older consent or current-locale reconstructed notice. Current case status/identity/proof limitations come from the final existing getter/bridge.
* Absent: `{state:'absent',request_id,payload:null,result:null,definitive_failure:false}`. Absence never authorizes replacing the nonce, reconstructing consent or adopting the latest case.
* Closed: `{state:'closed',request_id,payload:null,result:null,definitive_failure:true}`. The exact nonce is permanently fenced and has no accepted submission.

`close_my_visit_recovery_submission(p_request)` has the same accepted/closed shapes. If the producer already committed, close returns its accepted receipt unchanged and never cancels/hides/updates the case, submission or notifications. If no submission exists, close inserts an immutable private nonce/actor/server-time tombstone. A delayed producer sharing that mutex sees closed and returns the closed envelope without creating a case, submission or notices. Foreign existing nonce ownership always denies42501; null nonce22023; unsuitable current identity/session42501. No consent or profile fields are returned for absent/closed states.

Original `submit_visit_recovery_request(p_request,p_consent)` keeps the exact final applied225809 logic and result for valid accepted paths, including strict fixed-consent validation, changed-payload22023, global nonce/current identity/actor-envelope lock order, reuse of awaiting_matching/more_info cases, original identity snapshots, receipt/notifications and idempotency. Only a new local variable and close-fence block are added after existing accepted-replay handling. A valid delayed call to an owned closed nonce returns the new closed envelope. Accepted history takes priority and is preserved.

## Client recovery rules

Persist only the submission UUID per account. After restart, query this exact reader. Accepted means the server retained the original payload and returns the current own case, so display that result and clear local uncertainty only after receipt handling. It is unnecessary to submit again; if an exact replay is needed use only the returned stored consent. Absent remains frozen until explicit close succeeds. Closed resolves that exact abandoned attempt; creating a new request must remain an explicit user action with actual fresh consent, never automatic nonce rotation. Permission/session failure or transport uncertainty retains the UUID. No secret, phone, payload or consent persistence locally is required.

## Review/verification status

Source-only parity check verified original225809 file SHA256 `a0a4b10742e1f6e57f3d036b7f877213bc40e1ba654563ab7f439b56c1a517d3`; removing the new declaration/fence reproduces its submit function exactly. No SQL was executed or migration applied by the author.

`supabase/tests/offline_visit_recovery_submission_restart.sql` is an unexecuted ROLLBACK fixture using existing confirmed customers and actual live Auth sessions. It can reuse existing open cases; invalid QA phone placeholders are populated only transaction-locally. Cases cover absent nondeterminism, close-first/delayed producer, submit-first/close accepted, immutable timestamp/tombstone, exact stored consent across locales/nonces, changed-consent rejection, no latest-case substitution, rollback of close, identity drift, invented-session/cross-actor denial and unchanged claim/link counts/notices. No new Auth/customer/identity evidence is fabricated. All fixture rows/contact changes roll back. This is sequential ordering proof, not a claim of real two-session race execution; mutex correctness/static checks and any actual concurrent acceptance remain root-controlled.

Root must review/apply/check grants and run the focused fixture before enabling the UI dependency. Existing owner review, canonical-claim bridge and history/wallet permissions remain authoritative and unchanged.
