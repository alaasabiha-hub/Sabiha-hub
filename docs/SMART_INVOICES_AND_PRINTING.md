> Historical implementation notes. For the current flexible printer adapters, permissions, local PDF.js dependency, and physical acceptance limits, see `PRINTING_CAPABILITIES_AND_ACCEPTANCE.md` and the latest `PROJECT_HANDOFF.md` entry.

# Smart invoices and local printing — development implementation

No deployment, production database change, real gateway charge or physical printer submission was performed.

## Implemented boundary
- Supabase assigns each existing/new invoice a UUID locator. Invoice ownership remains the order customer, or a cashier-authorized staff member of the invoice branch. Knowing/scanning a locator is never authorization.
- QR links can be disabled by the owner. The original locator and the first configured origin are stable for reprints; changing the global origin affects future/unconfigured invoices only. Old domains must retain a controlled redirect if a domain ever changes.
- Historical branch identity, item quantities/prices, discount and total are snapshotted. Existing server loyalty finalization may adjust an unpaid invoice; the existing paid ledger guard blocks changes after collection. Legacy invoices have no tax snapshot: PDFs explicitly say tax is not recorded. Fiscal/tax configuration and coupon/loyalty detail are still release blockers.
- PDF layouts: A4, 58 mm, 80 mm, original approved transparent brand, Arabic and English, QR and explicit reprint mark. The six generated Flutter/website samples decode to the identical locator using native macOS Vision.
- Website QR route survives login. Staff can paste/use keyboard scanners; compatible browsers offer user-initiated BarcodeDetector camera scanning and a clear paste/USB fallback. Flutter has a camera scanner, invoice page, PDF export and OS print integration.
- The owner configures per-branch printer profiles, default, paper and automatic printing. A unique durable print job is enqueued after a payment event. Failure/retry records append attempts and cannot invoke payment. Expired/failed attempts are conservatively marked as reprints.
- `submitted` means OS/spool acceptance (or an explicitly simulated acknowledgement in automated tests), not proof that paper exited the printer.

## Secure local website worker
`tools/print_worker.py` polls OUTBOUND using a staff session and public API key. It opens no inbound port, accepts no arbitrary URL/command from QR, and sends generated PDF only to an allowlisted local OS printer. Private config must be mode 0600, kept outside Git. It rejects hosted endpoints in this development version.

Run `--dry-run` for read-only queue inspection, once for pending jobs, `--watch` for repeated pending-job polling, or `--job UUID` for an explicit retry. No daemon was installed and no printer was automatically selected on the user's computer. A real printer must be paired and its driver validated first.

Flutter auto-print additionally requires the owner to enable this device in Printer Settings; it runs after the payment RPC returns. The OS may require a dialog. Truly silent printing/raw ESC/POS USB/Bluetooth adapters are not claimed as implemented or verified. USB/LAN/Wi-Fi/Bluetooth work only where the OS driver/print service supports that model and platform. iOS Bluetooth generally requires a supported vendor/MFi/AirPrint integration; a generic ESC/POS claim would be inaccurate.

## External gates and outstanding work
- Final HTTPS domain, Android application ID + release signing SHA256, Apple Team ID/bundle ID/Associated Domains. `tools/prepare_invoice_association.py` generates review files without publishing them or overwriting prior files.
- No real App Links / Universal Links association was enabled because these final identifiers/domain are not available. Compile `INVOICE_PORTAL_ORIGIN` only after verification. Camera and OS print plugins still require actual Android/iPhone acceptance tests.
- No trusted payment gateway/webhook exists yet. Current electronic events are staff-recorded local ledger confirmations, not independently verified gateway success. Do not use this as a real electronic payment integration.
- Physical A4/58/80 printer testing, Arabic raster quality, driver disconnection/reconnection and spool acknowledgement remain required.
- Overall service reviews and assigned-employee review controls are now linked from completed invoices, with seven-day edit and owner comment moderation. Final tax/coupon/loyalty financial snapshots and store download destinations remain pending. Existing employee rating data remains in the shared booking-based ledger rather than being duplicated.
- App/website invoice list currently limits to 200 authorized recent rows; pagination/search by opaque locator is available, but historical paginated browsing remains pending.
