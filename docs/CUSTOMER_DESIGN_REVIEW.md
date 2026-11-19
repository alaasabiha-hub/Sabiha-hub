# Customer visual correction — 13 November 2026

Local continuation on `codex/admin-accounting-console`, retaining previous files,
functional workflows and checkpoints. This task prioritizes the actual visual redesign.

## Design authority

Latest supplied customer references replace the earlier plain customer interior layout:
black/navy backgrounds, royal blue panels, gold accents/gradients, service photographs,
original approved silver/navy SH mark and bilingual wordmark. Public welcome/login remains
as previously approved. No reference screenshot is used as a fixed customer interface.

The website administration now follows the actual Revel reference organization:
cyan header, dark horizontal icon navigation, white report surface and summary/analysis tables.
The original SH logo and all existing role-filtered destinations remain.

## Implemented presentation

- New shared `customer_visuals.dart`: native Flutter hero, gold wave painter, original
  bitmap mark, panels/buttons, drawer, bottom navigation, customer-only theme/frame and
  themed dialogs/date picker. The original logo file is unchanged.
- Rebuilt orders/appointments with actual counts, search, current/past/all filters,
  photographic cards, real saved prices/status and inspection-linked detail sheet.
  Shop orders and secure invoices remain separate reachable tabs.
- Rebuilt signed-in home into an action grid and photographed published branch service
  cards. Existing vehicles, reviews, invoices, complaints, inspections, support, language
  switching, product ads and logout remain reachable.
- Rebuilt published services: branch selector, search/category chips, service photographs,
  actual branch prices/durations, up to three selections and compact comparison.
  At least two selections are required. Branch change clears comparison selection.
  Booking retains the original selected service/branch and login continuation.
- Booking form has service photo/price summary; the native calendar and slot sheet use
  the existing server availability RPC. No invented times, packages or prices were added.
- Profile/settings: actual customer identity, form, password route and consent switches;
  loyalty/offers: actual balance, published offers, coupon copy and real service route.
- Shop/basket: redesigned quantity controls and native panels, preserving invalidated
  quotes, idempotency IDs, server quote/final total and existing pickup/delivery validation.
  Only the currently implemented pay-on-receipt flow is shown, without fake card collection.
- Reviews use compact approved-photo/name/rating cards and completed-service forms.
  Missing photos use an icon; no fake portrait or rating count is supplied.
- Vehicles, password, delivery tracking, customer invoices, inspection gallery and
  complaints receive the shared customer frame. Staff/owner frames are gated separately.

## Photographs and content

Real Pexels photographs are bundled with credits in `assets/customer/PHOTO_CREDITS.md`.
They are illustrative, not evidence of a particular customer inspection or Sabiha premises.
A downloaded photo containing another business brand was excluded and retained privately.
The actual blue car photograph is used in the hero. No original SH artwork was redrawn.
Reference prices, balances, employee identities and notification badges were not copied.

Catalog names/descriptions are owner-entered data and are not automatically translated
or invented. Package categories show matching published catalog entries; no configured
package means an honest empty result. Product-specific bottle photographs still require
actual catalog photography; the shop uses clear icons when no real product photograph exists.

## Verification

- 36 focused Flutter checks passed across the changed presentation and retained
  welcome/login, customer care, delivery and invoice contracts.
- Final visual component checks: 14 passed, including AR/EN at 320/390/430 widths.
- Flutter analysis clean. Normal web and Android debug builds passed.
- Live Chrome/Flutter Web acceptance captured 78 images: 13 screens/states × 2 languages ×
  3 phone dimensions. No render exceptions were collected. Comparison selected two real
  published services; slots were returned by the local Supabase availability RPC.
- No booking confirmation or payment submission was made during visual acceptance.
- Website: actual owner login, native report navigation, AR/EN, desktop/mobile and
  mobile drawer verified. Five targeted Python checks passed (role-filtered navigation,
  default/current highlighting and existing export safeguards).
- The approved logo was retained byte-for-byte. No schema/RLS changes or migrations
  were needed for the redesign. Existing Supabase records/permissions remain authoritative.

## Acceptance limits

Images are from the actual running Flutter **web** application at phone viewports.
They are not native iPhone/Android device screenshots. The existing Android emulator
was attempted read-only, remained ADB-offline, and was stopped without wiping its data.
iOS/native device acceptance remains pending. Building is not launch acceptance.

The 13 captured screens/states are home, bookings, booking detail, services, comparison,
appointment form, available times, shop/basket, profile, privacy settings, loyalty,
reviews and vehicles. Auxiliary invoice/inspection/complaint frames were updated but
need their own detailed visual acceptance before they can be called visually complete.
The website shared shell/report is reviewed; remaining legacy management forms still
need individual reference review. No claim of universal pixel identity or 100% release
readiness is made. Existing business requirements outside this design task remain open.

## Review artifacts

The task outputs contain `Sabiha-design-review.html`, a reference/actual comparison and
filterable gallery, `Sabiha-design-review.md`, actual PNGs and the visual verification JSON.
No deployment, main merge, production mutation, paid purchase or secret publication occurred.
