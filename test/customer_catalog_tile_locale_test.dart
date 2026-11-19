import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_visuals.dart';

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets(
      'Service tile translates owner data and shows only class-specific prices $lang',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var booked = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(lang),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: SingleChildScrollView(
                child: CustomerServiceTile(
                  service: const {
                    'name': 'غسيل سيارة',
                    'name_en': 'Vehicle wash',
                    'description': 'وصف عربي',
                    'description_en': 'English details',
                    'price': 123.45,
                    'vehicle_class_prices': [
                      {
                        'class_code': 'sedan',
                        'name_ar': 'سيدان',
                        'name_en': 'Sedan',
                        'price': 150.0,
                      },
                      {
                        'class_code': 'suv',
                        'name_ar': 'دفع رباعي',
                        'name_en': 'SUV',
                        'price': 180.0,
                      },
                    ],
                    'duration_minutes': 60,
                  },
                  onBook: () => booked++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(lang == 'ar' ? 'غسيل سيارة' : 'Vehicle wash'),
          findsOneWidget,
        );
        expect(
          find.text(lang == 'ar' ? 'وصف عربي' : 'English details'),
          findsOneWidget,
        );
        expect(
          find.text(lang == 'ar' ? 'English details' : 'وصف عربي'),
          findsNothing,
        );
        expect(find.byType(CustomerCatalogPhoto), findsOneWidget);
        expect(find.textContaining(lang == 'ar' ? 'سيدان' : 'Sedan'), findsOneWidget);
        expect(find.textContaining(lang == 'ar' ? 'دفع رباعي' : 'SUV'), findsOneWidget);
        expect(find.textContaining('123.45'), findsNothing);
        expect(find.textContaining('150.00'), findsOneWidget);
        expect(find.textContaining('180.00'), findsOneWidget);
        await tester.tap(find.text(lang == 'ar' ? 'احجز الآن' : 'Book now'));
        expect(booked, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('does not silently display a legacy flat price when classes lack rates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        supportedLocales: [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: CustomerServiceTile(
            service: {
              'name': 'Wash',
              'price': 100,
              'vehicle_class_prices': [
                {
                  'class_code': 'sedan',
                  'name_ar': 'سيدان',
                  'name_en': 'Sedan',
                  'price': null,
                },
              ],
            },
            onBook: _noop,
          ),
        ),
      ),
    );
    expect(find.textContaining('Price unavailable'), findsOneWidget);
    expect(find.textContaining('100'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
