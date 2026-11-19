import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_booking_ui.dart';
import 'package:sabiha_hub/customer_visuals.dart';
import 'package:sabiha_hub/home_tagline.dart';

void main() {
  const id = '12345678-1234-4000-8000-123456789012';
  final booking = <String, dynamic>{
    'id': id,
    'service_name': 'خدمة محفوظة / Saved service',
    'booking_date': '2026-11-15',
    'booking_time': '10:30:00',
    'status': 'pending',
    'quoted_price': 137.45,
    'payment_status': 'unpaid',
    'vehicle': {'brand': 'QA', 'model': 'Isolated', 'plate_number': 'QA-123'},
  };
  test(
    'Short reference is display-only and searches preserve original IDs/plates',
    () {
      expect(shortBookingReference(id), 'SH-12345678');
      for (final query in ['SH-12345678', id, 'QA-123']) {
        expect(
          filterCustomerBookings([booking], query, 'all').single['id'],
          id,
        );
      }
      expect(
        bookingPaymentLabel('verification_required', false),
        'Electronic payment not verified',
      );
      expect(bookingPaymentLabel(null, false), 'Payment status not recorded');
    },
  );
  for (final locale in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 1440.0]) {
      testWidgets('Enriched own booking card $locale $width', (t) async {
        t.view.physicalSize = Size(width, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        var opened = 0;
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: ListView(
                children: [
                  CustomerBookingCard(
                    booking: booking,
                    arabic: locale == 'ar',
                    onDetails: () => opened++,
                    onInspection: () {},
                    support: const SizedBox(),
                  ),
                ],
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('SH-12345678'), findsOneWidget);
        expect(find.text(id), findsNothing);
        expect(find.text('137.45 EGP'), findsOneWidget);
        expect(find.text('QA · Isolated · QA-123'), findsOneWidget);
        expect(
          find.text(bookingPaymentLabel('unpaid', locale == 'ar')),
          findsOneWidget,
        );
        final date = find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data ?? '').contains(locale == 'ar' ? 'نوفمبر' : 'November'),
        );
        expect(date, findsOneWidget);
        expect(find.textContaining('10:30:00'), findsNothing);
        await t.tap(
          find.text(
            locale == 'ar' ? 'التفاصيل والفاتورة' : 'Details & invoice',
          ),
        );
        expect(opened, 1);
        expect(t.takeException(), isNull);
      });
    }
    testWidgets('New copy is enabled on customer home only $locale', (t) async {
      Future<void> show(bool home) async {
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: CustomerShell(
              title: 'Page',
              body: const SizedBox(),
              onNavigate: (_) {},
              showHomeTagline: home,
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await show(true);
      expect(find.byType(HomeTagline), findsOneWidget);
      expect(
        find.text(
          locale == 'ar'
              ? 'لأن سيارتك تستحق الأفضل'
              : 'Because Your Car Deserves the Best',
        ),
        findsOneWidget,
      );
      await show(false);
      expect(find.byType(HomeTagline), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
