# Committed proposal/acceptance race acceptance — source only

tools/recovery_proposal_concurrency.py is PLAN by default. It has performed no DB/Auth/HTTP call. Root must review, save the current encrypted backup, hold other DB writers, and approve execution. Existing 21959 and later applied migrations are untouched.

Sequence:
1. Action prepare: preflight TWO original dedicated local QA customers from the existing private recovery-bridge-fixture.private.json, current real persisted owner/customer sessions, valid current phone, confirmed/unbanned accounts, no open case/active link and actor budgets ≤3/hour and≤18/day. No new Auth, login, session refresh, role/phone change or quota reset.
2. Prepare one fresh nondefault tagged branch and ONE fresh private intake per actor. Their actual registered phone necessarily matches a public Auth customer, so this uses the **existing owner** registration RPC's explicit create_separate review with a QA reason. This is a real unverified intake/audit, not a manager permission bypass or phone-ownership claim. No raw enrollment secret is selected or persisted; result stays in the setup SQL local.
3. Action run: four sequential genuine customer case → owner bounded lookup → independent-evidence proposal fixtures. It distributes only ONE successful new canonical claim to each actor. Existing notices are read before restricted roles or via the actual opaque customer proposal response. Actual RPCs execute under authenticated with real actor/session claims; there is no customer impersonation by owner and no forged JWT.
4. Action cleanup is safe for unfinished known cases. The tool also invokes bounded known-ID cleanup after run failure/success.

The four cases observe actual pg_blocking_pids before releasing the first transaction:
* Acceptance commits, then waiting same-request customer close returns business-won receipt.
* Customer close commits, then waiting late acceptance is fenced before claim creation.
* Acceptance commits, then waiting owner proposal close returns business-won outcome.
* Owner proposal close commits, then waiting late acceptance is fenced before claim creation.

Every request/proposal/query/case-submission/registration and cleanup command UUID plus full preexisting public/private/Auth row fingerprints and number counters is journaled0600 **before producer dispatch**. Server-generated profile/case IDs are discovered only from those exact actual registration/submission receipts. Action recover waits on the setup's dedicated mutex before exact tagged discovery, never blindly reissues a producer. An absent/partial uncertain setup stops for root review. Per-case passed checkpoints are retained; cleanup fences remaining requests, so a finished/failed journal is not a license to recreate or repeat accepted races.

Cleanup first closes each exact acceptance request (settling any delayed creator), then its exact owner proposal. It verifies submission actor/case and actual claim actor/profile before using the **existing prepared canonical reject** for mapped pending cases; unmapped cases use the existing prepared recovery reject. No approvals or links are created, and no old QA link is touched. Exact registration requests are settled, the tagged new branch is hidden, and new audit records/profiles/claims remain. There are no orders, services, invoices, payments, work or credits in this fixture.

Final proof requires all4 races, exactly2 new ordinary canonical claims, all new cases terminal, no new profile links, full old public/private/Auth hashes unchanged (including old HR), document counters unchanged, financial/Auth row counts unchanged, canonical outbox empty and branch inactive. Optional in-app hints emitted by the existing inbox trigger are normal server behavior; no managed Realtime table is edited by the tool.

This first harness deliberately does **not** claim contact-change, final approval or revocation concurrency. Those require another root-reviewed fixture/probe because this bounded test avoids creating any link. Existing rollback integration covers final canonical approval/revoke and contact drift; it does not replace those future two-session claims. Syntax and default PLAN checks only are performed by the author; actual race/cleanup evidence remains pending root execution.
