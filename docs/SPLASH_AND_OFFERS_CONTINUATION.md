# Startup branding and newest offers requirements — 14 November 2026

## Current implementation

- Added `lib/sabiha_splash.dart`: navy #071A36, full unchanged approved PNG using
  BoxFit.contain, soft 0.94→1 scale, fade, subtle temporary silver reflection,
  white single-line name, two-second animation, 350 ms home transition.
- Startup resolves saved language and verifies a restored session against Auth;
  active staff route through the existing StaffDashboardScreen, customers through
  the existing customer dashboard, guest/offline/failed verification to public home.
  Public web does not acquire the app-only startup delay. Existing database access
  checks remain authoritative. Pending deep links wait for startup readiness.
- Accessibility: reduced-motion preference disables the visual movement; responsive
  constraints and safe areas support small/landscape displays.
- Platform resources now use the original bitmap, uniformly resized and padded,
  never cropped/recolored. Android launch themes cover pre-12 and Android 12+,
  light/dark; normal window and system bars remain navy. The iOS launch storyboard
  has aspect-fit constraints and navy background; all 19 icon slots are opaque RGB.
- Removed original-image clipping in welcome header/hero/reusable OriginalHubMark;
  these now display the complete approved bitmap with a light backing for legibility.
- Original asset hash is unchanged. Source/native resources were backed up first:
  `work/checkpoints/before-splash-offers-20261114.tar.gz` in the task workspace.

## Verification

19 combined splash + welcome regression tests passed: animation/session timing,
full asset containment, reduced motion, small/tablet/desktop/landscape displays,
AR/EN, enlarged text, login/booking/staff destinations and language persistence.
Targeted Flutter analysis is clean. iOS launch storyboard compiled with ibtool and
19 icon dimensions/opacity validated. Full iPhone runtime/build remains blocked by
Xcode 16.4 / Swift 6.1 versus the pinned Firebase SDK's Swift tools 6.2 requirement.
The earlier actual iOS build failure was retained rather than repeated unnecessarily.
Android normal debug APK build and real startup capture results are recorded below
once the final native mask/padding check completes. Earlier full customer booking /
local cash / admin native acceptance passed before this startup change and is
preserved separately; it is not a claim that every native feature passed again.

## Latest user steering, still to implement after verified startup checkpoint

The newest request supersedes earlier gold navigation styling: gold belongs only
to offers, discounts and rewards. Apply navy/royal/silver/white elsewhere. Preserve
approved admin icon order and table layout while changing accents where required.

Build the reference offers/packages screen in existing Flutter, not a separate HTML
page and not generated mockups: desktop hero, four offer categories, responsive
package cards with real images and genuine prices, account loyalty and real coupons.
Link every Book now to the actual chosen service/booking route. Owner editing must
have verified database permissions and real service/package relationships; current
legacy offers do not yet have reliable package price/service links. Never display
reference prices (315/595/899 etc.) or 50 loyalty points as real business data.

Temporarily remove multi-branch selection from current public/admin flows using a
single authorized/default branch; preserve existing database branches and RLS for
future use. Do not silently aggregate hidden branches. Exclude ceramic and paint
protection from current public services without deleting historical records.

Still pending: complete offer/package relationship and owner CRUD, coupon/service
booking application, revised platform-wide gold restriction, single-branch UI and
ceramic/protection exclusions, then targeted real Flutter Web/mobile acceptance.
No hosted changes, production mutations, signing/store release, merge or publishing.
