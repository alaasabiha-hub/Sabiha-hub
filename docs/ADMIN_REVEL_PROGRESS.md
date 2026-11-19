# Sabiha Hub administration — saved development progress

Scope: Flutter administration, existing `codex/admin-accounting-console` branch. Original SH bitmap and customer visual system retained. No main merge, deployment, hosted database access, data reset or release approval.

## Implemented

- Reusable native Flutter `AdminConsole`: original silver/blue SH mark, cyan brand strip, dark fixed horizontal navigation with ten icon-above-label sections in reference order; active royal-blue state; establishment selector; Arabic/English and RTL/LTR; desktop/tablet horizontal navigation scrolling when required.
- Overview: Payments Overview band, Today/Yesterday/Custom exclusive-end Cairo dates, interactive real payment-event curve, collections/cash/unclassified electronic/discount/tax/net-sales indicators, branch-linked customer and transaction indicators. Refunds are separate and negative chart values remain visible.
- Reports: seven live tabs; Sales Summary and Analytics in reference-style two columns on desktop, stacked on tablet; expandable rows and expand/collapse all; branch/employee/service/payment/search filters; full filtered PDF/Excel datasets and A4 print callback. Original CSV copy retained.
- Native data pages: catalog, inventory, scoped employee directory, schedules/bookings, branch-linked customer directory and published offer records, establishments, live-role security information and settings. Existing booking, inspection/VIP intake, invoices/printing, shifts, complaints, delivery, employee moderation, branch configuration, document and contact settings routes retained. A settings shortcut retains the previous operations menu.
- Additive read-only `get_admin_console` RPC and private implementation, with live active-staff identity checks. Owners see all branches; managers see assigned branches; ordinary employees see assigned work; cashiers see only their own shift payments/invoices and never commission costs. Customers/anonymous/inactive staff denied. No existing table/RLS policy rewritten. New functions applied to loopback database only, migration prepared for later review.
- Incomplete tax/fee snapshots, card credit/debit classification, liabilities, net-to-account-for and actual profit stay explicitly unknown. No Revel numbers or tax rates assumed. Branch-linked customer count is labeled as such rather than presented as period-active customer count.

## Verification and data boundary

Actual Chrome screenshots come from the running Flutter web app authenticated against loopback Supabase; they are not mockups. This environment contains synthetic test records and displays a persistent development warning. No screenshot/export is an approved final business report. Production financial validation requires authorized real operational records and is not claimed here.

Targeted tests cover AR/EN at 768/1024/1440 widths, pinned navigation, server filter requests, denied and stale financial results, original report entrypoint, OOXML numeric/string safety and expanded export datasets. Independent PDF/Excel parsing validates actual files. API tests reconcile invoice metrics with retained canonical owner report, test payment/search filters and deny out-of-scope real branch and invalid windows. Rollback-only cashier fixtures prove own/other cashier isolation, private commission suppression and inactive-account denial; fixtures do not persist. Per-section sources/progress saved privately before proceeding. Customer acceptance tests/screenshots from the previous phase were not rerun.

## Remaining — do not call the entire financial system complete

- Full transactional payroll (salary, bonus, deduction, advance settlement), approved liabilities, purchasing/cost of goods and audited profit remain incomplete in the shared database. Existing worker advances and invoice commissions are not a complete payroll or branch-cost allocation. No speculative financial mutation API added.
- Catalog/inventory pages currently show actual authorized data; existing branch tools retain price/capacity/stock-transfer actions. Complete native purchase-order and stock-receipt workflows still need implementation and acceptance.
- Security page reports effective server scope; full account provisioning/role editing in Flutter remains pending. Preserve current server access rules until separately reviewed.
- Report email delivery is visibly unavailable until configured; no email was sent. Electronic receipts do not yet distinguish credit/debit cards. Missing tax snapshot data is not backfilled with an assumed rate.
- Physical tablet/native Android/iOS, real print hardware and final business-data acceptance remain pending. Browser viewport checks do not replace native-device checks.

Next work: continue native inventory purchasing/receiving against an audited, idempotent branch ledger, then payroll and financial reconciliation; verify each operation and save before the next module. Do not rerun completed customer checks or regenerate customer assets. Preserve previous backups and local private verification artifacts. No production application without explicit user approval.

### Cairo midnight correction

`today_cairo` comes from PostgreSQL's `Africa/Cairo` clock. Today/Yesterday and the initial month window use that server day, not the device's calendar. An initial date mismatch is corrected before financial results render. Targeted regression deliberately uses a server date different from the device, including a previous-year Yesterday boundary. This fixes Dubai/Cairo midnight differences without adding a timezone package or changing customer code.


### Brand-only correction — 2026-11-14

Replaced the clipped monogram in the administrative header with the entire original approved bitmap using BoxFit.contain, retaining byte-identical artwork and its original proportions. A white/silver backing preserves contrast for the bitmap's navy lettering. Header height adapts to the complete logo. Narrow-header button spacing preserves readable company words.

Applied requested navy #071A36, royal #174B83, silver #C5CBD5, gold #D4AF37, dark #101820 and white. Navigation icon/label arrangement, ten-section order, report tabs, charts, tables, filters and financial operations are unchanged. Gold marks active sections/tabs and graph points. Existing customer visuals and Supabase code/schema untouched.

Four focused original-logo/responsive tests passed; actual Overview and Reports screenshots at 1440, 1024, 390 and 320 widths, plus English navigation, passed without browser/render errors. Exact requested colors verified in rendered pixels. No main merge, deployment, database edits or financial-test reruns. Before/after review: outputs/Sabiha-admin-brand-before-after.md in the task workspace.
