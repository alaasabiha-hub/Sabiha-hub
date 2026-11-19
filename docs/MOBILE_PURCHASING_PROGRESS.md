# Mobile header and purchasing continuation — 14 November 2026

All changes remain local on `codex/admin-accounting-console`. No hosted database,
production data, publishing, merge or release signing was changed.

## Verified stage 1: mobile header

Preserved the existing ten-section order, horizontal admin layout and report tabs.
Original `assets/sabiha_brand_approved.png` is unchanged, fully displayed using
BoxFit.contain. The Sabiha Hub name is a single line, scaled only when needed.
On narrow screens language/logout controls sit below the name. Horizontal section
scroll starts at Overview in both languages and reaches Settings.

Eight targeted widget tests passed: Arabic/English at 320, 390, 768 and 1440 px.
Actual Flutter Web Overview and Reports captures passed at 320, 390, 1024 and
1440 px. Existing before/after captures are retained, not regenerated.

## Verified stage 2: supplier and purchasing ledger

Embedded a reusable purchasing panel below the existing inventory table. Supports
branch-scoped supplier creation, explicit stock counts with mandatory reasons,
multiline draft purchases using entered unit costs in EGP, confirmed receipt and
reasoned cancellation of drafts. Saving a draft does not increase stock. Unknown
stock stays unknown until a physical count is entered. Received orders cannot be
cancelled through the draft cancellation operation. Latest 100 entries are labelled.

The additive migration is retained identically in Flutter and website sources:
`20261113203302_inventory_purchasing_ledger.sql`. Applied to local Supabase only.
RLS and RPC checks require active owner or explicitly inventory-authorized manager
with branch membership. Authenticated clients have no direct table write grants.
Stable request IDs, row locks and immutable movement records prevent duplicate
receipts, including concurrent retries; multiline receipts roll back atomically.

Five purchasing widget tests passed; combined with the header suite: 13 passing.
Eight backend integration groups passed, plus cancellation and manager/branch/
inactive-staff/anonymous/direct-write checks. Synthetic records exist only in an
isolated local QA branch and are never final business reports. Encrypted local
DB/Storage backup was created before the schema change; prior restore drills retained.

This stage does not implement supplier payments/accounts payable, returns, or full
cost-of-sales allocation. Actual profit must remain unavailable until the approved
cost/payroll/tax ledger is complete. Do not substitute purchase totals for COGS.

## Native and build verification

Android API 35 isolated emulator is available. Native integration verification is
in progress; read the final execution status below before claiming acceptance.
Repeated native runs retain test bookings; the test selects a vehicle-free interval
rather than deleting history. Booking service/vehicle/branch and cashier branch
menus now constrain long text to avoid narrow-screen overflow.

An actual iOS simulator build was attempted and failed: installed Xcode 16.4 has
Swift 6.1; pinned Firebase iOS SDK requires Swift tools 6.2. Upgrade to the previously
documented Xcode 26.2+ environment before retrying. iPhone runtime acceptance is
NOT passed. Final bundle/app IDs, Apple team/provisioning/APNs and Android signing
keystore are still external release requirements; no signing credentials fabricated.

## Outstanding scope / next dependency order

1. Finish actual purchasing UI and native flow acceptance; retain final proof logs.
2. Shared attendance/employment/payroll/commission/advance/bonus ledger and screens.
3. Supplier payments, returns, canonical costs/tax snapshots and actual profit.
4. Remaining legacy POS/branch scoping, VIP workflow and customer acceptance gaps.
5. Real payment gateway/provider configuration, owner AI provider acceptance,
   physical printers/phones, iPhone build/signing and integrated release acceptance.

Current work is not a declaration that all previously requested modules are complete.

## Final native result before splash continuation

The Android API 35 native integration flow passed (exit 0): actual customer login,
new local isolated booking with server price 12 EGP, 5.37 EGP local cash collection,
admin Overview and Reports, and no Flutter layout exceptions. Screenshot captured
from the emulator as `Sabiha-Android-native-admin.png`. This verifies local cash,
not a live electronic payment gateway. Purchasing browser acceptance is still pending:
forms opened and supplier creation succeeded, but the automation needs dropdown
selection adaptation; do not claim the complete browser purchase flow passed yet.
