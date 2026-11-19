# Sabiha Hub — approved scope and verified status

Updated 13 November 2026. All work is local, on existing Codex branches. No merge,
push, hosted database mutation, release or paid service purchase is authorized.
Android, iOS and Streamlit form **one release**; no component is release-ready alone.

## Verified paths (not a declaration that an entire subsystem is complete)

| Domain | Verified locally | Remaining for the full approved scope |
| --- | --- | --- |
| Auth/customer/vehicles | Real Auth, email OTP/recovery, own profile/vehicles, session/logout | Final phone acceptance and full website account management |
| Bookings/operations | Server price snapshot, workflow permissions, branch hours/exceptions/closure, resource capacity and real concurrency, available slots | Rescheduling UI/RPC, maintenance resources, occupancy/delay alerts, VIP reception |
| Products/delivery | Independent product cart, pickup/delivery quote, fees/minimum/zone validation, exact-once stock reservation/cancellation, fulfillment stages/courier, invoice on completion | Final devices/provider delivery, geographic address verification beyond declared supported zone, return/refund stock workflow |
| Branches/prices | Renameable first Egyptian branch, owner management, per-day hours, exceptions, addresses/maps, per-branch catalog/stock, safe price copy, stock transfers, manager branch isolation | Finish migration of every legacy POS/commission/expense path and campaign/offer UI to explicit branch scope; Egyptian tax configuration |
| WhatsApp | Configurable global and optional branch number, official encoded links, editable message, order/booking references, no automatic personal details | Actual native WhatsApp handoff on Android/iOS and desktop browser acceptance |
| Owner reports | Shared Cairo date/time/branch RPC, hourly invoices and separate cash events, missing tax/cost handling, PDF/XLSX/CSV in both clients | Canonical historical reconciliation, complete tax/fees/COGS/payroll snapshots, actual profit, full staff/product/service report coverage |
| Reviews/photos | Completed own service and assigned staff only, unique editable rating for seven days, real averages, moderation without changing stars, private candidate photo and approved public photo | Final mobile/web acceptance, richer filters/reporting and abuse-report workflow |
| Complaints | Own visit/order reference, private attachments, lifecycle/assignment, immutable events and internal-note isolation | Service warranties, inspection links, overdue/push escalation and richer filters |
| Cashier shifts | Per-branch authorized cashier, payment/refund ledger, exact-once payment, cash movements/expense integration, expected/actual/difference, sealed close and owner approval, PDF | Finish connecting every legacy POS/payment path; audited financial corrections and configurable difference alert thresholds |
| Catalog/offers/loyalty | Existing shared catalog, coupons and loyalty SQL tests retained | Complete branch-aware offers/campaign selection and full Egypt tax treatment |
| Documents/AI | Private upload/review/renewal, fingerprints; approved metadata assistant with consent and validated citations | Provider credentials/output quality, full file-text/vector retrieval, legacy fingerprints |
| Notifications | Private order inbox, independent order push preference, tested dispatcher guards/consent/provider mocks | Firebase/APNs project credentials, scheduler and physical-device delivery |
| Audit | Owner-only append log for branches, prices/inventory, memberships, moderation and shifts/payment actions | Cover every remaining payroll, inspection, warranty and legacy financial operation; alerts/search refinements |
| Recruitment | Not implemented in the reviewed source | Jobs, anonymous applications with optional CV, secure screening/hiring/invitations and no-email onboarding |
| Inspection/before-after | Phase 4 private photos/signatures/diagram, approval audit, customer gallery/history/PDF and access isolation tested locally | Physical-device acceptance, richer comparison UI, complete VIP integration |
| HR/payroll/attendance | Legacy commission/advance calculations exist in website | Canonical staff employment/payroll/attendance/schedules/bonus system shared with app and hiring |
| Backups | Preserved source checkpoints, atomic JSON backups; authenticated AES-GCM DB/Storage backup, successful isolated restore + object checksums + tamper rejection | Full isolated Storage-service restore, external periodic schedule/replica, retention and failure notifications |
| Localization/design | Original supplied silver/navy image retained identically in both sources; core mobile AR/EN + RTL/LTR; bilingual branch names/addresses and PDF | Full new-screen and website English localization, responsive acceptance across devices |
| Release | Local web/APK builds in previous phase; current source under integration verification | Current builds, physical phones; Xcode 26.2+/Swift 6.2, final app IDs, signing/store accounts, Firebase/APNs/OpenAI, public hosting/production review and final approval |

## New migrations in this continuation

- `20261112202245_delivery_and_whatsapp.sql`
- `20261113045438_branches_schedules_and_capacity.sql`
- `20261113050718_customer_reviews_and_complaints.sql`
- `20261113052039_cashier_shifts_and_payments.sql`

These were developed against an isolated local Supabase stack. They are not applied
to the hosted project. Keep the earlier reports and migration/data review gate.

## Next dependency order

1. Complete verification and fix regressions in this phase; preserve checkpoint.
2. Close branch scoping gaps in legacy POS/catalog publishing/invoices/expenses,
   snapshots and reports before treating it as a single production ledger.
3. Inspection and customer before/after access; complaints/warranty integration.
4. Recruitment with rate limits/private optional CV and safe staff activation;
   canonical HR/attendance/payroll links.
5. Complete Storage-service disaster recovery/external retention, full bilingual UI, provider/device testing,
   store/hosting preparation and final integrated release acceptance.

Do not count file quantity or a successful build as completion. A final percentage
must be a conservative estimate of tested user workflows, with gaps listed above.

Conservative functional estimate for the expanded approved scope: about 40%. This
weights partially implemented workflows partially and excludes unverified provider,
physical-device and release acceptance. It is not a launch-readiness percentage.

## Newly approved printing scope (13 November)

Retain all prior scope. Add per-branch printer configuration/default printer and
opt-in automatic transaction receipts after a successfully committed cash/electronic
payment, manual print/reprint with duplicate-copy marking, A4/58mm/80mm, AR/EN,
the latest approved transparent PNG, invoice/date/services/discount/tax/total/method.
Printing must use a separate durable job/attempt record so failures never repeat
payment or lose the transaction. Printer connection/USB/Bluetooth/Wi-Fi/LAN support
must be verified against actual printer/device capabilities. A secure local bridge
or OS print dialog is required where direct browser printing is unavailable. Hardware
printing is not implemented or verified yet; existing A4 PDF exports are not printer
integration. Do not publish or enable real automatic printing without approved setup.

## Final website design reference
Use the attached homepage reference (13 November) as the layout/size/color target,
not merely inspiration. Keep the approved transparent PNG unchanged. Build real
horizontal navigation, hero actions, seven feature cards, promotions/loyalty and
branch information strip; read hours/address/offers from Supabase. Validate desktop
and mobile screenshots and actual navigation. Preserve all staff/owner/cashier
functions and apply the same visual identity. No live publication is authorized.

### Approved scope additions — 2026-11-13
- Preserve public homepage reference; internal owner/cashier/staff layout follows the newly supplied Revel-style reference with original SH identity: navy #071A36, royal blue #174B83, silver #C5CBD5, white background.
- Add bilingual responsive role-specific navigation, real Supabase charts, date/branch/employee filtering and PDF/XLSX export without widening DB permissions.
- Smart invoices: stable opaque revocable QR locator, authenticated owner/branch/customer resolution, website and Flutter detail/PDF, post-login route retention, App/Universal Links (verified domain external), service/assigned-employee reviews after completion.
- Durable branch/device print settings and print job/attempt history, payment-success auto enqueue, A4/58/80 mm with immutable same QR and explicit reprint mark. Printer failures never replay payment. Secure local bridge and platform adapters require device compatibility validation. Physical printers and real iOS/Android link association remain external acceptance gates until tested.
- These are additive requirements, not completed-feature claims; no production changes or deployment authorized.

### Phase 4 verified locally — 2026-11-13
- See `docs/PHASE4_PROGRESS.md` for the complete stage result, limitations, and remaining scope.
- Public reference homepage and Revel-style internal shell/report implemented; real local browser screenshots captured. Design and all legacy localization are not claimed fully complete.
- Added private vehicle inspection workflow/gallery/PDF, stable authenticated invoice QR documents, A4/58/80 PDF, per-branch print settings/outbox/attempts, local allowlisted OS print worker, Flutter OS print/scanner integration, and completed-invoice overall/assigned-staff review controls with owner moderation.
- Final checks: 60 SQL integration scenarios, 27 Python tests, 15 Flutter functional tests; optional artifact test run separately. `flutter analyze` clean. Normal Android debug APK and Flutter web builds passed. Supabase local security advisors clean.
- Real Flutter web at 390 px saved a service review, owner website read the identical new comment and the DB retained one review. Browser proof and JSON verification saved outside the repos in the task outputs.
- Six invoice QR codes (both clients × three paper sizes) decoded to one identical synthetic invoice locator. No physical printer, iPhone Universal Link or Android verified App Link acceptance is claimed.
- Encrypted backup/restoration into a newly created isolated local DB succeeded, including 27 Storage objects and new inspection/invoice/print/review tables. Original data and all prior backups retained.
- Still blocked/pending: stale legacy POS/JSON reconciliation, fiscal tax/coupon/loyalty snapshots, trusted payment webhook, full recruitment/HR/VIP/warranty/escalation, full AR/EN legacy UI, real phone push/AI quality, external backup scheduling and launch accounts/domain/signing/toolchain.
- No production mutation, deployment, GitHub upload, main merge, or real payment was performed.

### Mobile welcome reference implementation — 2026-11-13
Original transparent logo retained unchanged. Added responsive white brand/language/login header, navy welcome hero, real book/services/staff routes, persisted AR/EN and customer dashboard restyling. Published services use the existing shared public contract and preserve selected branch/service through customer login. 15 focused tests passed across five sizes and 130% text scale; final analysis clean, web and Android debug builds passed. Real Flutter web screenshots and service-selection/dashboard language checks completed. No schema, production, deployment, main merge or data deletion. Physical iPhone/Android acceptance remains external. See MOBILE_HOME_DESIGN_PROGRESS.md.

### Phase 5 — local continuation
See PHASE5_PROGRESS.md. Added owner-only Cairo time-window accounting across clients, explicit missing tax/cost handling, hourly charts and report exports; customer booking cards/search/current-past filters. The new image references are accepted as additive scope, not marked complete. Full project remains incomplete.

### Customer visual correction — 13 November 2026
The latest black/royal-blue/gold customer interior reference is implemented through native Flutter components across the main customer journeys. 78 actual Flutter Web captures cover 13 screens/states, AR/EN, 320/390/430. The website administration uses the actual Revel cyan/dark horizontal navigation layout. See CUSTOMER_DESIGN_REVIEW.md for exact coverage, preserved data contracts and native-device/auxiliary-screen acceptance limits. No completion percentage is increased solely for UI work.
