# Phase 5 — Cairo sales windows and customer bookings

13 November 2026. Branch: `codex/admin-accounting-console` in both repositories.
Local development only. Prior work, original logo, backups and previous branches retained.

## Implemented and verified in this phase

- Owner-only `get_owner_sales_window`: Cairo local date AND time, branch/all branches,
  half-open interval, at most 366 days, rejection of nonexistent/ambiguous Cairo DST boundaries.
- Server-derived hourly active/refunded invoice values. Invoice cohort uses issue time
  and current invoice status; payment transactions use their own event time. These are
  separate measures and may concern different invoice cohorts.
- Explicit equation: billed before discount (including taxes/fees) minus discounts equals
  net active invoice value. Gross/net sales excluding tax/fees are unavailable when
  any included invoice lacks their snapshots. Missing legacy tax/fees are never backfilled as zero.
- Actual profit remains unavailable until cost/payroll snapshots and reconciliation are complete.
  Uncollected values are differences against recorded sale payments, not proof of actual customer debt.
- Both Flutter and Streamlit use the same RPC. Date/time/branch filters, interactive
  hourly chart, invoice metrics and clear accounting notes added.
- Website PDF/Excel exports retain missing values and actual totals. Fixed shared PDF
  fallback fonts after visual review exposed missing Latin glyphs in the Arabic font.
- Flutter PDF/Excel export uses the same report snapshot, original logo/bilingual PDF,
  proper numeric XLSX cells, explicit missing values, frozen headers and optional RTL.
  Text uses inline strings, so text beginning with `=` cannot execute as a formula.
- Customer booking cards retain existing authenticated, customer-filtered Supabase queries.
  Added current/past/all filters and ID/service/date search, localized status and saved
  booking price, explicit missing quote, inspection/gallery and existing support links.
  Failed loading is distinguished from a genuinely empty result.
- Restored Streamlit mobile sidebar access while hiding the hosting toolbar.

## Tests and practical limits

See the task-output phase 5 report for the final verified counts and artifact links.
DB integration covers the previous contracts plus new owner authorization, branch isolation,
end exclusion, Cairo DST rejection, unknown accounting data and cash events outside invoice cohort.
Focused Flutter tests cover responsive cards, actual action callback, search/status partition,
missing quote, report authorization and actual export generators. Welcome/login navigation
regression was run once after main-screen integration, not the full unchanged suite.
Real local Supabase calls reconciled hourly totals and denied customer/employee report access.
Website local owner login/report navigation, mobile sidebar expansion and downloaded PDF/XLSX were checked in Chrome. Flutter web owner authentication and the canonical report screen were also verified; actual PDF and Excel downloads from Flutter web passed and were independently parsed. Physical OS save/print acceptance remains pending.
Flutter web local customer login/bookings were checked at 390/430 px using existing synthetic DB fixtures.
These are real running Flutter **web** screenshots, not iOS/Android device screenshots.

## Additive reference requirements — accepted, not completion claims

The ten new user attachments guide customer interior layouts and thermal receipt arrangement.
Do not copy third-party brands, account balances, prices, employee identities or receipt access notes.
Keep the approved public welcome/home, original transparent logo and all prior business requirements.
Still to complete: illustrated customer home/services/packages comparison with genuine published
branch data and suitable licensed/owner-provided car photos; slot picker visual redesign;
full profile/reviews/loyalty presentation and consistent customer navigation.
The newly improved booking list is only one part of that work.

Reuse phase 4 invoice token, secure resolver, PDF A4/58/80, print queue and idempotent payment
ledger. Still pending: full historical fiscal/customer/vehicle snapshots, refined receipt layout,
physical-printer validation, trusted gateway webhook, verified App/Universal Links.
No physical printer submission, real payment, iOS build, live publication or main merge is claimed.

## Remaining approved scope

Canonical reconciliation of every legacy POS/JSON/inventory/commission path; complete Egypt tax,
cost/payroll snapshots and actual profit; shared HR/attendance/payroll; jobs/applications/hiring;
VIP reception; warranty/escalation; safe rescheduling; full branch-aware marketing/offers;
full bilingual legacy UI and exact admin/reference visual acceptance; notification/AI provider quality;
real device/network/printer acceptance and full isolated Storage-service restore/external backup schedule.
External launch requirements remain domain/association IDs, signing/store accounts, modern supported
Xcode/Firebase toolchain, payment sandbox/provider configuration, Firebase/APNs and physical devices.
No paid setup is purchased and no production migration has been applied.
