> Local acceptance update: catalogue migration32036 is applied only to the isolated local database. Static/per-trigger checks, rollback functional coverage and seven actual two-session races passed; exact old-row preservation and API archive cleanup are recorded in `companies-fleets-catalogue-review-proof.json`, `companies-fleets-catalogue-local-apply-proof.json` and `fleet-catalogue-concurrency-proof.json`. New Flutter component11 tests and targeted analysis passed. The screen is now wired into existing owner-only CRM and the local web build succeeded. Actual HTTP context/list allow the owner and deny customer/employee/manager/anonymous access (`fleet-http-permissions-proof.json`). Actual read-only browser acceptance passed in Arabic390 and English1440 for the owner route, live context/list and archived filter. These browser checks do not approve unexecuted browser writes or native devices. This supersedes historical author-only/pending notes below for these scopes only. No contracts, billing, tax verification, ETA submission or actual profit implementation is implied. No production changes or deployment.

# Companies and fleets — owner catalogue foundation (source only)

Migration20261115032036 adds independent private party/vehicle master data. Source review found no existing company/fleet catalogue; individual customers/vehicles, private reception profiles and suppliers remain separate. There is no company Auth user, fake customer identity, changed customer PK/FK, historic invoice update, contract, price, debt, payment, loyalty transfer, bulk work or ETA writer.

## Authorization and storage

The new fleet_require_owner(view/manage) module boundary reuses the accepted actual live owner/session check. Both capabilities currently require an active real owner. Existing arbitrary permissions JSON does not establish safe new delegated fleet access, so manager/employee/customer fleet flags do not grant anything. Future delegation requires an explicit reviewed change, not an implicit new permission default. All tables have RLS, no direct public/anon/authenticated/service-role grants, and public wrappers are invokers over explicitly gated private implementations.

Private fleet_parties and fleet_vehicles have stable independent UUIDs, versions, archive state, creator/updater and command references. Immutable fleet_catalog_versions records actual owner role, request, purpose, old/new snapshots and time, with one event per entity version and one event per command. Master changes require matching same-transaction event proof; events cannot be rewritten. Historical master versions are never overwritten. No delete API exists; archive/re-enable produces another version. A vehicle's party affiliation cannot be edited or silently transferred.

All legal/tax/contact/representative/vehicle facts remain UNVERIFIED. Country checking is only two-letter formatting, never official registration validation. Unknown fields remain explicit null; no EG,14%,zero tax, legal validity, ownership or representative access is inferred. Contact syntax is not possession proof. Owner-recorded business emails are contact data, not Auth credentials; the individual cashier no-email requirement and existing intake remain untouched.

## Party input

Party create/edit data must contain exactly:
- legal_name and trading_name: nullable actual text≤200; at least one has≥2 characters.
- registration_country: nullable explicit two-letter country.
- tax: null or exactly country, identifier_type≤40, number≤80, all present/nonempty. Tax type/number are owner-recorded labels, not official codes or validated status.
- address: null or exactly country, region, city, street, building, postal_code, additional; each explicitly nullable. Other fields≤120, additional≤300.
- contacts: array0–25 of exactly kind(phone/email/other), value, label. Values bounded, exact repeated kind/value rejected. These are observed records, never verification or marketing consent.
- representative: null or exactly name≤120, title≤120, phone≤64, email≤254, verification:'unverified'. No login/membership/authorization is granted.

Observed tax country/type/number keys are uniquely constrained, including archived parties; a duplicate rejects for owner review and never merges records. Whitespace/case key normalization is a bookkeeping comparison, not a country's legal tax-number equivalence rule. Shared legal/trade names remain separate and get owner-visible possible-same-name references via party details; a name match is not identity proof. A wrong recorded identifier can be corrected through a reasoned new version, retaining old history.

## Vehicle input and unlimited catalogue

Vehicle create/edit data contains exactly plate_country(nullable), plate_number(required≤40), make(nullable≤80), model(nullable≤80), year(nullable integer1000–9999 (four-digit recorded value, not a legal/model-year assertion)), color(nullable≤40), fleet_reference(nullable≤80). Plate key uses the existing intake normalization (Arabic digits, uppercase, remove spaces/hyphens); it is not vehicle ownership verification. Country/plate collisions across fleet records, including archived records, reject without merging. Correcting/transfer/conflict resolution beyond normal versioned field edits needs explicit later workflow; archiving alone does not release a claimed key.

Vehicles are separate rows with no per-party count cap. Indexed bounded keyset listings support plate/make/model/fleet-reference literal-prefix search; percent/underscore/backslash are escaped. Every page is1–50 items, with created_at+entity_id cursor. Edit timestamps do not reorder creation cursors. No array containing every car is returned. Company archive suppresses effective vehicle activity without rewriting child rows; child archive is independent. Parent re-enable does not change any child's own archive state. New vehicle/create/edit/re-enable requires an active parent; child archive remains possible while a parent is archived.

## Durable command contract

- prepare_fleet_catalog_command(p_request UUID,p_kind TEXT,p_entity UUID,p_party UUID,p_expected_version INT nullable,p_data JSONB,p_reason TEXT)
- get_fleet_catalog_command(p_request UUID)
- apply_fleet_catalog_command(p_request UUID)
- close_fleet_catalog_command(p_request UUID)

Kinds: party_create/edit/archive/reenable, vehicle_create/edit/archive/reenable. Party entity UUID must equal party UUID. Creates require expected_version:null; updates require exact current version≥1. Edit supplies full replacement terms. Archive/re-enable supplies exactly empty object. Reason10–500 characters is mandatory. Prepare normalizes and freezes the exact payload; get returns its canonical server payload for apply-by-UUID recovery. The vehicle's derived plate_key is server output, not a permitted raw create/edit input field.

State envelopes have request_id/state(open/succeeded/closed/absent), payload/result and timestamps where available. Absent has definitive_failure:false. Same nonce with changed canonical payload rejects22023; another owner cannot read/reuse its command. A successful result replays immutably even after later entity edits. Close-before-prepare permanently fences delayed creation. Close-after-business returns its original success and does not undo anything. Unknown network outcomes must recover or close the SAME nonce before starting another operation; acknowledgements may clear only the local UUID after a definitive terminal receipt.

Apply serializes command → party → vehicle, rechecks real owner/session after entity waits, and verifies expected version/state before writing. Stale version40001, identity/key conflict23505, unavailable42501, invalid input22023 or blocked state55000 do not create partial entity/history results. A prepared command remains recoverable/closable after a rejected apply. The source uses no cron, test bypass, privileged browser key or external provider.

## Read APIs

- get_fleet_catalogue_context(): owner-only module capabilities; billing/contracts/pricing/bulk work/receivables/ETA all false; tax_rate and actual_profit null.
- get_fleet_party(p_party): full own-owner master terms, version, effective activity, bounded potential name duplicates and vehicle count.
- get_fleet_vehicle(p_party,p_vehicle): exact party-bound vehicle, version and effective activity; no ownership proof.
- list_fleet_parties(p_search default'',p_include_archived defaultfalse,p_before_created_at nullable,p_before_id nullable,p_limit default25): literal name/trade prefix; item metadata, not all private terms.
- list_fleet_vehicles(p_party,p_search default'',p_include_archived defaultfalse,p_before_created_at nullable,p_before_id nullable,p_limit default25).
- list_fleet_catalogue_history(p_entity_kind party/vehicle,p_entity,p_before_version nullable,p_limit default25): immutable before/after reason/actor/version/time, bounded.

Pair cursors must be both null or both provided. Next cursor uses created_at/entity_id; history uses next_before_version. Search has bounded input length; there is no free SQL or unbounded export API.

## Acceptance source and remaining work

Focused rollback fixture companies_fleets_owner_catalogue.sql requires existing live owner/nonowner sessions, no Auth creation or permission/phone edits. It covers current-session/metadata denial, nullable unknown legal/tax data, no fabricated verified representative, stable command replay/changed payload/close fence, all8 operations, stale expected version, duplicate tax/plate rejection, same-name warnings, exact party-bound reads,3-car pagination/literal wildcard, archive-parent behavior, immutable original versions and unchanged old invoices/Auth. Root should run static and per-trigger checks, DDL/rollback and full old public/private/Auth fingerprints. Author performed no DB/actual test/build/network write or application.

Actual two-session command/close, concurrent edits and party-archive/vehicle-create races are still pending root acceptance; locking design is not claimed as executed proof. Flutter/owner route and delegated module permission management are not implemented here. Contracts/pricing/credit limits, bulk work, invoicing/receivables, actual settlement, legal/tax verification, ETA credentials/signing/official acceptance and AI profit remain explicit future dependencies. Existing working financial and identity paths are not changed.
