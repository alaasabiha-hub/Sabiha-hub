# Private inbox WebSocket acceptance — source-only plan

The default invocation of `tools/private_inbox_realtime_acceptance.py` performs no login, database access, network request, or credential-file read. Execution requires `--execute` and distinct fresh state/proof paths under the local runtime directory. Author checks cover Python compilation and this default plan only; actual acceptance remains pending root review and execution.

## Protocol and transport

The [official Supabase Realtime protocol](https://supabase.com/docs/guides/realtime/protocol) documents explicit `vsn=1.0.0` text-object framing, private join configuration, token authorization, join replies, broadcast envelopes, and Phoenix heartbeats. The installed Dart `realtime_client-2.13.2` supports v1 in `lib/src/constants.dart`; `realtime_channel.dart` supplies the private/broadcast/presence/access-token configuration and `realtime_client.dart` prefixes channel topics with `realtime:`. The harness explicitly selects v1 instead of interpreting v2 binary frames. Installed Python websockets 17.4 supplies the transport; no dependency installation is needed.

All HTTP/WebSocket traffic is restricted to the installed loopback gateway at 127.0.0.1:54321. HTTP environment proxies and redirects are disabled; WebSocket proxies are disabled. Actual current Auth JWTs are obtained from the existing owner and one existing confirmed recovery-fixture customer before the preservation baseline. No service-role token, forged claim, new Auth account, phone edit, role edit, or credential output is used. Heartbeats run every 15 seconds. Only join, heartbeat, and leave frames may be sent; there is no client publish operation.

## Bounded cases

1. Join each actual actor's private `app-inbox:<Auth UUID>` topic. Both replies must be successful.
2. Attempt the owner's topic using the valid customer session. Require an explicit authorization-denial join reply; close that socket before producing an event.
3. Establish all public/private/Auth row-hash, document-counter, managed-message-ID, and inbox baselines after logins and joins. Reject an active/linked customer case before mutation.
4. Persist a fresh submission UUID with 0600 permissions before the one actual customer submit. Use the server's current consent notice without persisting its text locally. Require the newly created unmapped case to differ from every prior case.
5. Require both own sockets to receive one hint and confirm the actual case/template/unread change through `list_my_app_inbox` and the own-case RPC. Broadcast content never grants authority.
6. Replay the exact submit nonce and consent. Require unchanged durable event/target counts and no additional hints during a bounded two-second observation window. This is a bounded replay observation, not a claim of universal exactly-once delivery.

## Payload and preservation

The application supplies only `{kind: inbox_changed}`. The installed managed `realtime.send` adds a random transport UUID. The harness permits exactly `kind` and `id` on the wire and verifies the UUID against the actual managed message row. It rejects business case/source/event/actor identifiers, arbitrary fields, and raw content. Raw frames, responses, tokens, credentials, consent text, and profile data never enter proof or journal files.

Read-only PostgreSQL checks hash rows inside the database; no user/Auth rows leave it. Every prior public/private/Auth row and all document counters must remain unchanged after the initial logins. Only scoped new recovery submission/case/review/decision, inbox-event/hint-target and managed-message rows are allowed. No financial records, contracts, loyalty records, or public records are created.

## Finally and uncertainty

The journal records both submission and review UUIDs before their mutation. Cleanup first closes the exact submission nonce, which either fences a late unknown producer or returns the actual accepted new case. Before owner rejection, the harness rechecks own customer, new-case identity, unmapped state, actual current status, and the exact saved owner-command payload. It never rejects an old or mapped case. Audit rows are retained; nothing is deleted. All sockets close even after a failure. Any uncertain cleanup is reported for manual recovery using the journal; there is no automatic second producer, identity rotation, or rerun.

Execute only in a root-released exclusive local writer slot. Existing two customer choices are `--customer-index 0` and `1`; do not create or modify an account to satisfy a preflight. State/proof files must be fresh and distinct. A failed run must be reviewed and archived before any separately authorized retry. No Flutter/build/deploy or app-badge acceptance is implied by this backend harness.
