# Offline customer identity: additive foundation and staged integration

Date: 2026-11-14. Status: the private foundation migration was applied LOCAL once by the parent; three PL/pgSQL functions passed static checks. The parent verified rollback acceptance and actual two-session dedupe/idempotency: all prior public/private rows stayed unchanged, one private profile/car pair was created across concurrent requests, and only the first response contained a raw secret. Tagged private QA intake/audit records from concurrency acceptance are retained; no Auth or financial records were created. The broader architecture below is a staged plan. Current reward checkout remains unchanged. A registration foundation does not establish walk-in earning, guest redemption, account linking, or historical app visibility.

## Verified current constraints

The parent captured catalog metadata without customer/phone rows in task runtime `offline-customer-identity-schema.txt` and `offline-customer-identity-constraints.txt`. Repository references below establish application behavior; catalog snapshots establish the baseline constraints that predate migrations.

| Existing object | Actual constraint/behavior | Consequence |
| --- | --- | --- |
| `public.customers.id` | UUID primary key, not null; `customers_auth_user_fkey` references `auth.users(id) ON DELETE CASCADE` | An independent offline UUID cannot be inserted here. Keep the FK and every existing customer UUID. |
| `public.customers.email` | Text, not null, `customers_email_key UNIQUE(email)` | A guest without email cannot fit this table without changing its contract. Do not fabricate an email. |
| `public.customers.phone` | Text, not null, `customers_phone_key UNIQUE(phone)` | Raw text uniqueness is not normalized-phone identity verification or a safe global dedupe rule. Preserve existing values and constraints. |
| `public.vehicles.customer_id` | UUID not null, FK to `customers(id) ON DELETE CASCADE` | New offline cars need independent private references; do not insert an Auth dummy or reassign an existing vehicle. |
| `public.vehicles` | UUID PK; `UNIQUE(customer_id,plate_number)`; year null or 1950–2100 | Plate is scoped to an existing customer, not a unique person identifier. Preserve existing vehicle UUIDs. |
| `public.bookings.customer_id` | Nullable FK to `customers(id) ON DELETE CASCADE` | Nullability does not make an offline customer eligible for current customer-owned RPCs or loyalty. |
| `public.business_orders.customer_id` | Nullable FK to `customers(id) ON DELETE SET NULL` | Name/phone snapshots can exist without an Auth customer, but the current reward engine requires stronger canonical identity and source facts. |
| Existing own-customer RLS | `customers.id = auth.uid()`; `vehicles.customer_id = auth.uid()` for reads/writes | A new verified link will not automatically make offline history visible through these policies. Do not broaden them during foundation work. |
| Other customer FKs | Legacy loyalty, marketing, coupon redemptions, fulfillments, notifications, reviews, complaints, inspections and private canonical rewards reference `customers(id)` | They cannot silently consume an offline-profile UUID. No PK/FK rewriting or blanket identity merge. |
| Canonical loyalty | `canonical_loyalty_visits.customer_id NOT NULL` references `customers`; booking/order/invoice and actual cash sale are required. Reward quotes, redemptions, claims, reviews and service attempts also FK `customers` | Existing app earning/redemption must stay operational and separate until an audited walk-in adapter exists. |
| Auth-linked operational fields | Staff/actor IDs, payment-policy creators, Paymob creators and push-token users reference `auth.users` | These identify the acting staff/Auth principal; they must not be repurposed as an offline customer. |

Sources: `supabase/local/auth_baseline.sql`; `20261113045438_branches_schedules_and_capacity.sql`; `20261114133029_canonical_loyalty_visit_earning.sql`; reward A/B migrations `20261114150906` and `20261114150907`.

### Current phone and Auth behavior

`handle_new_auth_user` creates `customers.id = NEW.id`, copies phone from **user-editable metadata**, uses email, and has a missing-phone display fallback. `sync_customer_email_verified` observes `email_confirmed_at`, not verified phone continuity. Flutter signup uses email/password and phone metadata; its OTP flow is email signup verification. Customer login checks the profile by `id = user.id`; profile editing writes `customers.phone` directly. These values are contact/display data, not phone-ownership evidence.

Relevant code: `lib/main.dart` customer login, signup/email OTP and account update; `supabase/local/auth_baseline.sql`. Current no-app planning must not reinterpret these fields as verified or mass-normalize/backfill them into trusted identity.

The chosen free future link contract is [OFFLINE_CUSTOMER_CLAIM_CONTRACT.md](OFFLINE_CUSTOMER_CLAIM_CONTRACT.md): actual confirmed-email Auth plus the original enrollment receipt secret, explicit customer consent and separate owner approval. No paid SMS dependency or cashier handling of email/password/Auth is allowed. Existing app registration and email confirmation remain unchanged. No phone verification, account linking or guest redemption is claimed operational.

## Smallest safe foundation to implement first

Add a private independent UUID anchor and staff-only registration workflow. Keep all existing Auth/customer/vehicle/financial tables and their FK/RLS contracts unchanged. No dummy Auth accounts, fake credentials, fake emails or historical rewrites.

Proposed private tables (names are a migration contract proposal):

| Table | Purpose and important fields |
| --- | --- |
| `offline_customer_profiles` | `profile_id UUID PK`, actual name/key, `created_branch_id`, `created_by` Auth staff, `created_at`, `identity_verified=false`. No Auth account required; the profile UUID is permanent. Foundation creates only unverified profiles; ambiguous reviews create no new profile until an explicit owner separate-person decision. |
| `offline_customer_contacts` | Independent contact UUID, profile FK, original contact text if needed, canonical E.164, explicit country input/normalization version, status `observed_unverified`, timestamps and actor. Index normalized phone for candidate search; **do not make phone globally unique**. Foundation cannot write a verified status. |
| `offline_customer_car_refs` | Independent car-reference UUID/profile FK; actual plate plus normalized search key, entered brand/model and optional valid year/color. These are intake references, not proof of ownership or existing `public.vehicles` rows. Preserve independent UUIDs and normalized intake snapshots with profile-scoped plate uniqueness for retries. |
| `offline_customer_registration_requests` | Stable request UUID, staff actor/branch, exact normalized payload, fixed operational consent text/version/language and hash, server time and safe result. Immutable registration and consent receipt; no raw secret in stored result. |
| `offline_customer_enrollment_receipts` | Permanent enrollment receipt UUID/profile/request reference and only a 32-byte SHA-256 hash of a server-random 32-byte secret; issuer and server time. Secret is returned once on a newly created profile, never on reuse/recovery. No linking or verification operation exists yet. |
| Existing `business_audit_log` | Profile/contact/car registration actions and before/after metadata, with sensitive contact values masked/omitted from general logs. Detailed contact data stays in the private registry. |

All tables have RLS enabled and no direct `anon/authenticated/service_role` table access. Expose narrowly scoped security-definer functions through public security-invoker wrappers, pinned search paths and active staff/branch checks. A cashier permission or active owner/authorized branch manager is required; ordinary employees and customers cannot create or enumerate profiles. Staff Auth identity remains the actor, not the customer owner.

Initial capabilities must say exactly: `offline_registration=true`, `phone_verification=false`, `guest_redemption=false`, `auth_linking=false`, `walk_in_loyalty_accrual=false`. No provider/ledger integration is inferred from saving a profile or consent.

### Frozen foundation RPC contract

Migration: `20261114163329_offline_customer_registration_foundation.sql`; root applied it LOCAL and verified rollback/static/two-session acceptance. Proofs are `work/runtime/offline_customer_registration-stage-proof.json`, `offline-intake-static-proof.json` and `offline-intake-concurrency-proof.json` in the task workspace. Five private tables and two public security-invoker RPC wrappers; no email fields, no new Auth account and no shared Flutter changes in the backend slice.

- `register_offline_customer(p_request uuid,p_branch uuid,p_name text,p_phone text,p_country text,p_car jsonb,p_consent jsonb,p_duplicate_action text default null,p_review_reason text default null)`.
- Name is actual trimmed/collapsed text, 2–120 characters. Explicit country context is `EG`; normalization translates Arabic/Indic digits, formatting spaces/parentheses/dots/hyphens, `00` international prefix, Egyptian national mobile `01` plus nine digits or landline `0[2-9]` plus eight digits to canonical `+20` form. Canonical format is `+[1-9][0-9]{7,14}`. This is formatting support, not carrier/phone ownership validation.
- Car keys: required `plate_number`; optional `brand,model,year,color`. Plate input ≤40, normalized uppercase letters/digits without spaces/hyphens, 2–32 characters. Brand/model ≤80, color ≤40; absent information remains null. Year is an integer 1950–2100. No invented email or dummy car values.
- Consent is exactly `{accepted:true,version:"offline-registration-v1",text:<fixed notice>,language:"ar"|"en"}`. Server helper `private.offline_registration_notice(text)` supplies the exact fixed operational notice; it has no client execute grant. UI shows the localizable text and an unchecked checkbox, not a freeform policy editor. This is not marketing, account linking or redemption consent.
- DB active cashier/owner and branch checks run before access. A request lock and normalized-phone lock serialize writes, with READ COMMITTED required and a 20-second lock timeout. Exact normalized actor/request/payload retries have no duplicate profile/car/secret issuance.
- Reuse is **intake dedupe only**: one private normalized-phone candidate, same authorized branch, normalized name and exact normalized car reference. It is not identity verification or permission to read prior history, claim ownership or spend rewards. Reuse never resets or reissues the original enrollment secret.
- Any legacy public contact match, multiple contacts, cross-branch match or differing details yields generic `review_required`; no legacy profile/name/email/balance/history is disclosed. The normalized-contact registry is deliberately nonunique.
- Owner-only `p_duplicate_action="create_separate"` with an explicit 10–500-character reason records a distinct unverified profile. Cashiers cannot override review. It does not merge or transfer anything.
- Safe response fields: `request_id,status,offline_profile_id,car_ref_id,phone_masked,identity_verified:false,review_reason_code,enrollment_receipt_id,enrollment_secret_issued,enrollment_secret_recoverable:false,enrollment_receipt_status,capabilities`. Status is `created_unverified`, `reused_unverified` or `review_required`; review has no profile/car refs. No balances, histories, emails or full legacy rows.
- `enrollment_secret` is a raw 64-character hexadecimal secret **only on the first successful new-profile response**. Only its hash is stored. Replays, reused profiles, review and recovery return null. A lost response cannot recover/reissue it; `issued_not_recoverable` is explicit and future owner review handles loss.
- `get_offline_customer_registration(p_request uuid)` recovers only that authorized actor's own branch-scoped safe receipt. An absent lookup returns `definitive_failure:false`: it does not prove that a delayed request cannot arrive. There is no prepared-payload or close/tombstone API in this minimal registration slice; uncertainty freezes the same UUID/payload. After restart with only a UUID and an absent receipt, recheck or review instead of silently issuing a new identity.

Local retry persistence stores only the staff-scoped request UUID. Phone/name/car/consent payloads and raw enrollment secrets are not persisted locally or in logs/analytics. The raw secret is excluded from DB registration/audit results and candidate/recovery endpoints. Foundation capabilities for verified identity, guest redemption, app linking and walk-in accrual remain false.

## Dedupe, verification and continuity are different operations

1. **Candidate matching:** normalized phone, name and car hints help the cashier find possible duplicates. Phone can be shared, mistyped or recycled; plate can be transferred or used by another person. Preserve ambiguous candidates and send them to review. A concurrent duplicate registration should yield a candidate/review outcome rather than a second automatic insertion.
2. **Current app principal:** future claim verification reads actual Auth `email_confirmed_at` (or equivalent trusted Auth server state) for the current signed-in user. Editable `public.customers.email_verified`, user metadata and cashier declarations are not proof. This confirms the app email, not ownership of a historical offline profile. No paid SMS or phone verification is required by the selected free contract.
3. **Historical continuity:** a matching/current phone does not establish ownership of past offline history or rewards. The customer presents the original enrollment receipt secret, and an active owner must approve the request even when the secret is present: the issuing cashier may have seen it. Lost/stolen secrets and shared/recycled contacts need independent owner continuity review; there is no phone-only fallback or automatic ownership transfer.
4. **Transaction authorization:** a guest redemption challenge additionally binds the exact profile, quote/fingerprint, branch, car/service, actual visit debit, terms/expiry and explicit consent. A general registration consent or confirmed email alone cannot authorize later spending.

Foundation enrollment issuance is server-random and hash-only. It is not a claim or verification. Future reissue/revocation and claim consumption require separate explicit owner-reviewed operations; registration retry never reissues it. Never log the secret or put it into a public directory. A printable enrollment receipt is distinct from an invoice payment QR.

## Future no-app service and loyalty path — not delivered by foundation

A cashier can eventually create a walk-in service/order with independent offline-profile/car references, actual configured service/price, real consent and an authenticated staff actor. Existing nullable `business_orders.customer_id` is not a replacement for a typed offline identity reference.

Required additive work before claiming accrual:

- A canonical walk-in service identity and actual completed-service source, with the independent profile FK and explicit channel. Do not fake an app booking/customer row to satisfy existing constraints.
- Freeze the owner's actual enabled branch/service/offer/rule version at intake. Current app-only policy snapshots and `customer_id=auth.uid()` writers cannot silently cover guests.
- A compatible earning adapter/ledger identity model referencing real paid service/order/invoice facts. Current earning rows require `customers` and booking IDs, so this is a genuine separate stage. One earning per actual invoice/service source; refunds append reversals; no legacy-point conversion.
- A clear owner opt-in for which actual walk-in services count and whether cross-channel pooling is allowed. Existing rule choices do not imply a new source channel is enabled.

Before guest redemption, integrate the free continuity/owner-review design and independently trustworthy transaction authorization, explicit transaction consent, policy/rule-bound quotes, globally exclusive source-credit allocations across app and offline channels, deterministic refund locks, the same tombstone/recovery protocol, initial zero-due covered invoice, before-discount commission basis and honest receipt states. No zero cash/card events. Missing continuity/approval integration or an unsupported source/adoption rule fails closed. No paid SMS fallback is introduced.

An additional offline credit ledger cannot be exposed as redeemable through the existing `reward_credit_claims.earning_id` FK by pretending it is a `canonical_loyalty_visits` row. Choose an audited typed-source allocation adapter/generalization with exactly one real source and global active-claim uniqueness. Do not copy a visit into both ledgers or sum overlapping pools.

## Later verified Auth claim, preserving every existing UUID/FK

Add a separate link-request workflow and a verified link table from the permanent offline `profile_id` to a real `auth.users.id`. Preserve the independent profile, car references, order/invoice IDs and all original foreign keys. No Auth user is manufactured for a guest and no public customer UUID is replaced with a newly created Auth UUID.

- The customer signs in to a real Auth account and starts a single-use request bound to that current session, the exact offline profile, current contact version and continuity factor.
- A trusted server reads the current Auth account’s actual confirmed email/version, verifies the original secret against its hash, records fresh linking consent and requires separate active-owner approval. The cashier never handles email/password or approves transfer alone. An active link to another Auth user, multiple candidates, staff/customer identity conflict, changed phone, lost secret or weak evidence returns review; it never auto-merges by phone. Actual Auth confirmation and contact/request versions are rechecked before owner finalization.
- Consume challenge and request exactly once, under profile/contact/auth-link locks. Retry returns the same result; request reuse with changed data is rejected. Two principals cannot claim the same profile concurrently. Replay, expiry, session/account changes and challenge reuse fail closed.
- Keep operational actor `auth.uid()` distinct from business customer ownership. Initially permit a tightly scoped verified owner-link read RPC for the linked offline record only. Existing `id=auth.uid()` RLS stays unchanged until its individual reader/writer has an audited adapter.
- Existing app users may already have a separate `public.customers` row and history. A verified link must not delete/rekey that row or silently combine two people, balances, targeted offers or contact/marketing consents. Present separate identities/programs until an explicit conflict/adoption resolution is approved and consented.
- Existing app registration/email confirmation stays unchanged; offline private contacts do not occupy `public.customers` unique phone/email keys. Existing public-account phone/email conflicts still follow the existing error/review path. Future linking and customer-context readers are separate audited adapters, not a replacement for signup or a reason to weaken current FK/uniqueness rules.
- Auth deletion currently cascades through `customers` to some existing business relationships. The new independent offline anchor/link must not inherit that destructive identity lifecycle; any unlink/revoke behavior is append-audited and preserves business history. Broader historical retention changes require their own reviewed migration.

### Phone changes and disputes

Observed contact changes append a new contact version; they do not transfer ownership or rewrite historical invoice snapshots. Verification is scoped to the specific version. Replacing a verified contact, losing an enrollment factor, a shared/recycled number, existing Auth ownership or conflicting car evidence requires a controlled review queue. An owner decision records evidence, reason, actor and customer consent and must not silently reset visit debt or spend another customer's lots. Old links/challenges are revoked or superseded, not deleted. A confirmed app email or staff-entered phone never converts to verified historical ownership automatically.

## Compatibility alternatives and concrete cost

| Approach | Cost and boundary |
| --- | --- |
| **Recommended foundation: independent private offline profiles** | Additive private schema/RPC only; existing Auth customer PK/FK/RLS and running checkout stay unchanged. Useful registration/dedupe/consent now. Walk-in finance, verification, Auth claim and app visibility explicitly remain disabled. |
| **Later adapters with verified-link/customer-context resolver** | Audit every direct Auth equality, all own-customer RPCs, storage policies and app profile/vehicle calls; add scoped adapters before exposing each offline history type. Preserve IDs and existing FKs; typed offline walk-in/earning references and source-allocation handling are necessary. This is the larger end-to-end stage. |
| **Replatform `customers` by removing its Auth FK/relaxing unique identity fields** | Not authorized and not selected. It changes the contract used throughout current app, Auth triggers and cascades. It is not required for the proposed foundation and must not be slipped into an additive registration migration. |

## Owner controls and AI boundary

Owner controls must explicitly configure branch cashier/reception permissions, registration consent text/version/language, candidate/review policy, free enrollment/confirmed-email/owner-approval claim factors and independent redemption authorization, operational retention/access controls, actual walk-in earning/redemption terms and any cross-channel adoption rules. A disabled/unconfigured capability remains disabled; no generic points/currency conversion or made-up thresholds.

AI can summarize authorized, preferably aggregated counts of unverified profiles, candidate collisions, review age and evidence completeness. It may suggest review priority. It cannot verify a phone, approve a link/merge, choose an identity from name/plate, change RLS, waive debt, allocate rewards, create financial facts or send marketing without the relevant consent. Raw phone, OTP/enrollment secrets and broad cross-customer detail are excluded from AI prompts/logs. Existing owner AI provenance/budget/approval boundaries still apply.

## Acceptance and dependency matrix

**Foundation, rollback SQL:** anonymous/customer/ordinary employee denied; inactive staff and wrong branch denied; cashier permission enforced; private table grants/RLS; actual input bounds and normalization; no defaults for consent; duplicate candidate ambiguity; same UUID exact retry; changed actor/payload rejection; concurrent normalized-contact registration resolves to candidate/review rather than automatic merge; private car-reference isolation; audit/consent immutability. Fingerprints prove no Auth/customer/vehicle/booking/invoice/ledger changes, no link, no verified contact, no fake account and no earning/redemption activation.

**Foundation UI:** AR390/EN1440 registration, masked candidate decision, explicit consent, car details, no false “verified” or reward balance; lost-response retry identity retained without local personal data.

**Verification/link stage:** actual Auth email-confirmation checks; bounded enrollment-secret attempts/rates; one-use token and quote/session/profile/contact-version binding; same phone/different person, recycled phone, stolen old token, phone change during claim, unconfirmed/public-flag-only email, expired/session-switched request, issuing cashier acting alone, inactive owner review, simultaneous claims and existing linked Auth conflict. Prove no cross-customer read or transfer by user metadata/phone/plate alone.

**Walk-in finance stage:** actual completed/paid eligibility; correct source/rule binding; no duplicate invoice/visit on retry; refund-before/after-claim races; shared app/offline allocation uniqueness; explicit consent; zero-due coverage only with valid backing; old invoice/commission/QR invariance; cancel restoration/forfeit and review/debt behavior. Existing booking-reward regression remains required.

**App visibility stage:** each exposed history/profile/vehicle/photo/storage reader independently proves verified-link ownership and rejects another customer's link/profile UUID. Verify existing Auth UUID accounts still work and all old PK/FKs and records remain unchanged.

Dependencies: server-verified actual Auth email confirmation, server-side hash verification/rate limits and one-use request binding, explicit owner continuity/consent decisions, audited per-reader identity/source adapters and complete walk-in financial acceptance. No paid SMS service, cashier email/password collection or fake Auth account is required or permitted. Foundation saves alone satisfy none of the future claim/redemption gates.

## Proposed next approval boundary

The parent authorized/applied the private registration foundation and verified its rollback/static/concurrency acceptance. The isolated cashier Flutter module remains a separate validation/publication step; future claim/link/reader and walk-in finance are still not implemented by this foundation. Do not change existing Auth trigger, PK/FKs, RLS, shared Flutter or active checkout in that slice. Report capability flags as disabled for verification, links, walk-in earning and redemption until their own implementations and acceptance pass. No deployment, production writes, paid SMS or external challenge sends are included by this plan.

## Next stage: reviewed claim evidence (source only)

The additive claim migration is `20261114165702_offline_customer_claim_review_records.sql`; its rollback fixture is `supabase/tests/offline_customer_claims.sql`. It does not change existing customer UUIDs, Auth creation, public customer/vehicle RLS or any financial reader. This stage records reviewed evidence only. Every response keeps `history_visible`, `wallet_access`, `guest_redemption` and `reader_bridge_implemented` false. Local application and tests remain root-controlled and are not asserted by this source note.

The five authenticated RPCs are:

- `request_offline_customer_claim(p_request uuid,p_receipt uuid,p_secret text,p_mode text,p_consent jsonb)`: modes `original_receipt` and `lost_secret_review`. Exact same nonce/payload retries recover only the caller's status. A new nonce is limited to five attempts/hour and twenty/day for both the actual Auth actor and receipt, including failures. Wrong/unknown/consumed/rate-limited receipt proofs return the same `verification_failed` status and normally commit their attempt evidence. Unknown/lost entire receipt discovery is deliberately absent.
- `get_my_offline_customer_claim(p_request uuid)`: only the requesting account's state, no historical customer data. Rechecks real Auth email confirmation/hash and the complete observed-contact set. An approved evidence record returns `approved_pending_reader_bridge`; that is not history or reward access.
- `list_offline_customer_claim_reviews(p_branch uuid default null)`: active owner only, latest 100 minimal review entries, no raw secret, email or phone. Includes claim/claimant/profile references, name/branch, proof mode, account/contact freshness and timestamps.
- `decide_offline_customer_claim(p_request uuid,p_claim uuid,p_decision text,p_reason text,p_evidence_type text default null)`: active owner only; decisions `approve_with_secret`, `approve_exception`, `reject`, `hold`; reason 10–500 characters. Normal approval requires original proof. Exception requires explicit lost-secret consent plus `in_person_original_service_documents` or `in_person_independent_continuity_witness` and actual separately recorded continuity evidence in the reason. A phone match is not a supported evidence type. Owner approval is a trusted, audited business decision; software cannot independently establish the truth of an in-person attestation.
- `revoke_offline_customer_link(p_request uuid,p_link uuid,p_reason text)`: active owner only, exact audited retry. Original evidence remains immutable; only a first server-stamped revocation is permitted. Revocation never makes the original receipt secret reusable.

Claim consent must have exactly `accepted:true`, `version:'offline-claim-v1'`, `language:'en'|'ar'` and the exact text from the private server helper `private.offline_claim_notice(language)`. This is distinct from reception consent. Receipt proof is SHA-256 checked through a fixed 32-byte XOR/OR loop; plaintext proof is never stored. Pending review expires after 24 hours. Approval rechecks actual `auth.users.email_confirmed_at`, actual email hash, public customer identity, bans/deletion and a hash of the entire current contact set. It also locks contact writes during the final check. No editable public flag or user metadata can prove email confirmation.

Two different actors cannot race one nonce: a global request lock precedes actor and receipt locks. Final approval serializes actor/profile ownership and uses unique active actor/profile indexes plus permanently unique consumed receipt evidence. Conflicts cannot move a UUID or silently merge accounts. Lost receipt, a revoked link needing new evidence, and conflicting accounts remain owner-assisted cases outside automatic self-service. A later typed reader bridge still needs independent cross-customer tests before any old history, images, wallet or redemption becomes available.
