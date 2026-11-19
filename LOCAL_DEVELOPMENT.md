# Sabiha Hub — local integration, 12–13 November 2026

Existing branches, files and backups were retained. No deployment, GitHub push or
hosted database mutation was performed. All credentials and test customer records
used in this phase belong to an isolated local stack.

## Preserved sources

- Flutter: `/Users/user/development/sabiha_hub`, branch `codex/integrated-ai-platform`.
- Streamlit: `/Users/user/Documents/Codex/2026-11-12/sabiha-hub-github-supabase-streamlit/work/sabiha-hub-streamlit`, branch `codex/streamlit-supabase-persistence`.
- Restore archives: `/Users/user/Documents/Codex/2026-11-12/v/work/checkpoints/phase2`.
- The earlier progress report remains intact. This phase's report is in the task's `outputs` folder.

## Running development services

An isolated Lima VM (`sabiha-local`) runs Docker and real Supabase Auth,
PostgREST, Storage, Edge Functions, Postgres and Mailpit. The sandbox project is
`/Users/user/Documents/Codex/2026-11-12/v/work/runtime/supabase-local`.
It is not linked to a hosted project. API: `http://127.0.0.1:54321`;
Mailpit: `http://127.0.0.1:54324`; Streamlit: `http://127.0.0.1:8501`;
Flutter web: `http://127.0.0.1:8080`.

Docker environment for this sandbox only:

```sh
export PATH=/Users/user/Documents/Codex/2026-11-12/v/work/runtime/docker-cli/docker:$PATH
export DOCKER_HOST=unix:///Users/user/Documents/Codex/2026-11-12/v/work/runtime/instances/sabiha-local/sock/docker.sock
export DOCKER_CONFIG=/Users/user/Documents/Codex/2026-11-12/v/work/runtime/docker-config
cd /Users/user/Documents/Codex/2026-11-12/v/work/runtime/supabase-local
npx --yes supabase@3.1.0 start --exclude studio,imgproxy,postgres-meta,logflare,vector,supavisor,realtime
```

To stop services while retaining their data, run `supabase stop` in that directory.
Never add `--no-backup`, run `db reset`, or apply the bootstrap to an existing database.
The VM itself can be stopped with the isolated Lima executable and matching
`LIMA_HOME=.../work/runtime/instances`; this also retains its disk.

`tools/prepare_local_stack.py` prepares a **fresh, separately initialized** sandbox.
Its generated bootstrap excludes Auth/Storage test stubs. The real local database
was initialized once using that file, including the existing Auth triggers captured
through read-only metadata queries. SQL test fixtures are not production migrations.

Private local status, synthetic test accounts and isolated Streamlit secrets are
under `.../work/runtime`, with restricted permissions. Do not publish them.
The website process uses a separate synthetic JSON file via `SABIHA_DATA_FILE`;
existing business files and `.streamlit/secrets.toml` were not replaced.
Both clients reject non-local Supabase endpoints in this review build.

## Implemented in this phase

- Auth signup/recovery OTP, refresh/logout and verified-customer synchronization,
  including actual email delivery through Mailpit. Mobile accepts numeric 6–8 digit OTPs.
- Stable Auth IDs for staff assignments, same-name isolation, immediate inactive
  account revocation, manager assignment UI and employee-only assigned tasks.
- Shared website login for active owners/managers/employees. Non-owner queries use
  their own JWT. Staff provisioning is server-side; clients cannot promote themselves.
- Owner-only aggregate sales/refunds/commission/expenses reports shared by mobile
  and website, date/timezone selection, daily/payment breakdown and CSV export.
  Net is explicitly before tax; refunded invoices are excluded once.
- Private document workflows and an owner document assistant: explicit consent,
  approved extracted fields only, bounded retrieval, validated source references,
  no automatic record mutation. This is not full-file vector semantic search.
- Push dispatch error handling, timeouts, consent recheck and invalid-token disabling.
- Local Android networking, explicit release signing configuration, iOS push
  entitlements and local networking. Existing application IDs remain placeholders.

## Verification commands

From Flutter checkout:

```sh
flutter analyze
flutter test --no-pub
(cd test/database && npm test)
npx --yes deno test --allow-env supabase/functions/tests/contracts_test.ts
python3 tools/local_stack_e2e.py /path/to/local-status.json --credentials-out /private/test-accounts.json
python3 tools/auth_otp_smoke.py /path/to/local-status.json
python3 tools/mail_delivery_smoke.py /path/to/local-status.json
flutter build web --no-pub --dart-define-from-file=local-config.local.json
flutter build apk --debug --no-pub --dart-define-from-file=local-config.local.json
```

From Streamlit checkout:

```sh
python3 -m unittest discover -s tests -v
python3 tools/real_site_smoke.py /private/test-accounts.json /path/to/local-status.json
```

Native integration passed on a separate Android API 35 emulator:

```sh
flutter test integration_test/local_flow_test.dart -d emulator-5554 --no-enable-impeller --dart-define-from-file=integration-config.local.json --no-pub
```

The headless test flag does not change release rendering. The delivered debug APK
is rebuilt from `lib/main.dart`, not the integration runner. It contains only a local
public client key and uses localhost. Connect a development phone/emulator with
`adb reverse tcp:54321 tcp:54321` to reach the Mac. Never ship this local APK to a store.

## External requirements and final release gates

- iOS compilation currently fails because Xcode 16.4 provides Swift 6.1, while the
  existing Firebase 13.1.1 dependency needs Swift tools 6.2 (Firebase's supported
  Xcode minimum is 26.2). Update Xcode through an authenticated Apple installation;
  Firebase dependencies were not downgraded to conceal this blocker.
- Provide an OpenAI development key/billing/model access to verify actual provider
  output quality. Current tests mock AI and verify real missing-key/authorization guards.
- Configure a Firebase development project, client configuration and server service
  account; Apple Developer/APNs setup and physical devices are needed for real push
  delivery. Mock provider acceptance is not proof of phone delivery.
- Choose final Android/iOS bundle IDs, supply Android release signing and Apple
  signing/provisioning, then validate physical devices and store builds.
- Review the prepared production migration/data plan and grant final approval before
  enabling hosted endpoints or deploying. Legacy ambiguous staff names are retained
  without granting access and need explicit owner assignment to verified accounts.
- The unified report covers shared database invoices/expenses. Historical local
  records must be reconciled before expecting a complete production ledger.
- Old-document fingerprint backfill and complete file-text/vector indexing remain
  optional follow-up work; no existing customer file was rewritten.

Existing persistence safeguards remain: atomic writes, content-hash backups,
corruption protection and stale-session rejection. Do not commit secrets, signing
keys, customer files, runtime folders or backup archives.

## Phase 3 continuation — 13 November 2026

Approved scope/status is tracked in `docs/IMPLEMENTATION_STATUS.md`. The original
silver/navy image supplied by the owner is copied unchanged into both applications.
New modules cover delivery/pickup/support, branch hours/resources/prices/transfers,
service reviews/approved photos/private complaints, and cashier shifts/payments/PDF.
All of these are local review workflows, not a declaration of launch readiness.

New real-service scripts (synthetic accounts only):

```sh
python3 tools/delivery_e2e.py /private/test-accounts.json /private/local-status.json
python3 tools/branches_e2e.py /private/test-accounts.json /private/local-status.json
python3 tools/customer_care_e2e.py /private/test-accounts.json /private/local-status.json
python3 tools/shifts_e2e.py /private/test-accounts.json /private/local-status.json
```

The website now runs with an isolated Python 3.12 environment at
`/Users/user/Documents/Codex/2026-11-12/v/work/runtime/python-site312`.
Its direct dependencies are pinned in the site's `requirements-local.txt`, including
ReportLab and Arabic shaping/bidi support. Existing global Python installations and
the original requirements file were preserved. Use that environment for AppTest and
Streamlit verification. Streamlit's existing legacy JSON/POS path still requires
complete branch-aware reconciliation before production migration.

`dispatch-order-notifications` uses its own `ORDER_NOTIFICATION_DISPATCH_SECRET` and
`x-order-notification-secret` header. Order push preference is independent of
marketing preference. The customer inbox works without Firebase; actual phone push
requires the development Firebase/APNs setup and an approved scheduler. Never claim
provider mocks or a pending outbox as successful phone delivery.

### Encrypted local backup drill

`tools/local_backup.py` accepts only the isolated loopback API and a Unix Docker
socket. It backs up public/private/Auth/Storage DB schemas plus Storage object bytes,
then encrypts the archive with AES-256-GCM. The 0600 key must be outside the backup
folder. The drill creates a new randomly named database; it has no overwrite/drop
path for an existing database. The only dropped schema is the empty public schema
inside the just-created test database. Original data and prior backups are retained.

```sh
/path/to/python312 tools/local_backup.py \
  --status /private/local-status.json \
  --backup-dir /private/backups/encrypted \
  --key-file /separate/private/backup-key.local.bin \
  --docker /path/to/local/docker \
  --restore-test
```

Set the isolated `DOCKER_HOST` and `DOCKER_CONFIG` shown above. Install the tool's
pinned cryptography dependency from `tools/requirements.txt` in an isolated environment.
The successful local drill restored database schemas/data and checked decrypted
Storage bytes against hashes and restored object metadata. It did **not** bring up a
second Storage service and prove restored-file downloads through that service.
Global platform roles/extensions and infrastructure configuration need a complete
production disaster-recovery plan. No periodic OS job, external copy or paid backup
service was installed. No production restore is allowed without explicit approval.

The observed restore/check time on the small synthetic dataset was about four
seconds; this is not a production RTO/SLA. RPO depends on the future approved backup
schedule and successful external retention. Losing the separate encryption key
makes these encrypted backups unrecoverable.
