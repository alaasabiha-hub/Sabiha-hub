> Latest isolated-clone acceptance: migration 20261115065431_active_staff_role_live_session.sql closes stale-session staff-role authorization with 42501 for authenticated identities without a valid session. Five actor roles, authorized nonowner cashier, same-branch noncashier, foreign-branch denial, metadata rejection, exact ACL/OID preservation and rollback row integrity passed. Evidence: staff-role-session-review-proof.json and staff-role-session-clone-apply-proof.json. Custom local PostgreSQL advisor returned no WARN/ERROR; this is not a complete platform audit. Original application database and production unchanged.

> Root acceptance:53547,54335 and55241 passed isolated-clone SQL/static/authorization tests. Published reads preserve all100 documents and live owner/customer summaries100/69; missing/malformed/foreign/nonexistent/expired/deleted sessions and banned accounts are denied. Print request/claim/finish and raw granted printer/job/attempt paths now require the live session; existing full invoice row/snapshot column ACL denial is preserved. Exact table/column ACLs and original ownership/branch restrictions were not broadened. Actual READ ONLY GET-style queries passed. All business/Auth data stayed unchanged after probes. These migrations remain absent from the original local app database and production. Evidence:invoice-artifact-boundary-review-proof.json and invoice-artifact-boundary-clone-apply-proof.json, alongside earlier document-session proofs. This is scoped invoice-artifact acceptance, not a systemwide security or physical-printer approval.

Typed offline reward document session boundary

Source-only follow-up: 20261115053547_typed_reward_document_live_session.sql.
No application, database test, production change or public reward activation was performed by its author.

Scope is an actual invoice linked to offline_walk_in_subjects with non-null reward_issue_id. For that scope the existing document reader now requires a confirmed, nondeleted, nonbanned Auth user and a persisted session belonging to that same user, with no elapsed not_after. Missing, malformed, unknown or another user's session denies with 42501. Shared locks serialize identity/session deletion and existing staff authorization changes. Existing invoice authorization still decides access: legitimate cashier/manager/owner access is preserved; a valid unrelated customer session does not grant access.

The installed document body is renamed intact, its client and service-role execute privileges are revoked, and a narrow private wrapper delegates unchanged for every other document. No can_read_invoice, RLS, invoice, snapshot or published document token is changed. The published resolver's private implementation retains its OID/ACL but reparses its delegation and is volatile for current session checks. Private print-job routines should be checked/reparsed if cached delegation after the rename is relevant; this change explicitly refreshes the published document resolver.

Root acceptance on the isolated clone:
1. Include supabase/tests/typed_reward_document_session_assertions.sql within an outer transaction ending ROLLBACK.
2. Supply actual owner claims and its current QA session, actual typed reward token, actual foreign session UUID, and an authorized non-typed token to pg_temp.assert_typed_reward_document_sessions.
3. This helper calls the public resolver as authenticated. It checks valid access, four invalid claims, non-typed exact golden responses, and rollback-only expiration/deletion of the QA session. It verifies valid access again after restoring those nested mutations.
4. Independently use the real unrelated customer's existing session to assert typed denial. Check legitimate branch-authorized nonowner access if such an actor is available.
5. Run all new functions through the existing static checker before application. No claim of executed acceptance is made here.

Session presence enforces explicit session deletion/sign-out and not_after; it does not claim independent complete inactivity-policy enforcement. No session tokens or document bodies belong in proof logs.
