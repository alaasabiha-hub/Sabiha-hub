import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/current_catalog.dart';
import 'package:sabiha_hub/offers_catalog.dart';

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('service promotion shows per-vehicle rates only $language', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: OffersCatalogPage(
            offers: const [
              {
                'offer_id': 'class-service',
                'name': 'خدمة حسب السيارة',
                'name_en': 'Vehicle-priced service',
                'category': 'package',
                'service_id': 'service-id',
                'price': 999,
                'vehicle_class_prices': [
                  {
                    'class_code': 'sedan',
                    'name_ar': 'سيدان',
                    'name_en': 'Sedan',
                    'price': 120,
                  },
                  {
                    'class_code': 'suv',
                    'name_ar': 'دفع رباعي',
                    'name_en': 'SUV / 4WD',
                    'price': null,
                  },
                ],
              },
            ],
            coupons: const [],
            points: null,
            loading: false,
            failed: false,
            onRetry: () {},
            onHome: () {},
            onServices: () {},
            onBooking: () {},
            onAccount: () {},
            onLanguage: () {},
            onBookOffer: (_) {},
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('public-category-package')));
      await t.pumpAndSettle();
      final card = find.byKey(const ValueKey('promotion-class-service'));
      await t.scrollUntilVisible(
        card,
        250,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      expect(find.textContaining('EGP 120.00'), findsOneWidget);
      expect(find.textContaining('999.00'), findsNothing);
      expect(
        find.textContaining(
          language == 'ar'
              ? 'غير محدد لهذه الفئة'
              : 'No price set for this class',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }

  test('Current-service exclusions preserve wash/polish and normalize Arabic prices', () {
    for (final name in [
      'Ceramic coating',
      'حماية الطلاء',
      'Paint protection',
      'PPF film',
      'سيراميك',
    ]) {
      expect(isCurrentService({'name': name}), false);
    }
    expect(isCurrentService({'name': 'غسيل وتلميع'}), true);
    expect(
      isCurrentService({'name': 'إضافات', 'name_en': 'Ceramic coating'}),
      false,
    );
    expect(normalizedNumericInput(' ١٢٣٫٤٥ '), '123.45');
  });
  for (final language in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 768.0, 1440.0]) {
      testWidgets(
        'Real-price linked booking and responsive offers $language $width',
        (t) async {
          t.view.physicalSize = Size(width, 1000);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          Map<String, dynamic>? booked;
          await t.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: OffersCatalogPage(
                offers: const [
                  {
                    'offer_id': 'qa-package',
                    'name': 'باقة اختبار معزولة',
                    'name_en': 'Isolated QA package',
                    'description': 'بيانات اختبار الواجهة فقط',
                    'description_en': 'UI test data only',
                    'category': 'package',
                    'service_id': 'actual-service-id',
                    'price': 101.25,
                    'compare_price': 125.0,
                    'image_asset': 'wash',
                  },
                ],
                coupons: const [],
                points: null,
                loading: false,
                failed: false,
                onRetry: () {},
                onHome: () {},
                onServices: () {},
                onBooking: () {},
                onAccount: () {},
                onLanguage: () {},
                onBookOffer: (o) => booked = o,
              ),
            ),
          );
          await t.pumpAndSettle();
          await t.scrollUntilVisible(
            find.byKey(const ValueKey('promotion-qa-package')),
            250,
            scrollable: find
                .byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                )
                .first,
          );
          final book = find.text(language == 'ar' ? 'احجز الآن' : 'Book now');
          await t.ensureVisible(book);
          await t.pumpAndSettle();
          expect(find.text('EGP 101.25'), findsOneWidget);
          expect(find.text('EGP 125.00'), findsOneWidget);
          await t.tap(book);
          expect(booked?['service_id'], 'actual-service-id');
          final layoutError = t.takeException();
          if (layoutError is FlutterError) {
            debugPrint(
              layoutError.diagnostics.map((n) => n.toStringDeep()).join('\n'),
            );
          }
          expect(layoutError, isNull);
        },
      );
    }
  }
}
