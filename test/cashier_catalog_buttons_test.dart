import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_catalog_buttons.dart';

void main() {
  testWidgets(
    'a bound class with no rate never falls back to catalogue price',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CashierCatalogButtons(
              items: const [
                {
                  'item_id': 'service',
                  'item_type': 'service',
                  'name': 'خدمة',
                  'name_en': 'Service',
                  'price': 999,
                  'vehicle_price_verified': true,
                  'vehicle_price_available': false,
                },
              ],
              arabic: false,
              enabled: true,
              vehicleClassName: 'SUV',
              onAdd: (_) => fail('A service without a class rate is disabled'),
            ),
          ),
        ),
      );
      expect(find.text('No price set for SUV'), findsOneWidget);
      expect(find.text('999.00 EGP'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('pos_item_service')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final ar in [true, false]) {
    testWidgets(
      'Real-priced touch catalogue filters and adds ${ar ? 'ar mobile' : 'en desktop'}',
      (tester) async {
        tester.view.physicalSize = Size(ar ? 390 : 1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selected = <Map<String, dynamic>>[];
        final items = <Map<String, dynamic>>[
          {
            'item_id': 'service',
            'item_type': 'service',
            'name': 'خدمة',
            'name_en': 'Service',
            'price': 123.45,
            'vehicle_price_verified': true,
            'vehicle_price_available': true,
          },
          {
            'item_id': 'product',
            'item_type': 'product',
            'name': 'منتج',
            'name_en': 'Product',
            'price': 67.89,
          },
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Directionality(
                textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                child: SingleChildScrollView(
                  child: CashierCatalogButtons(
                    items: items,
                    arabic: ar,
                    enabled: true,
                    vehicleClassName: ar ? 'سيدان' : 'Sedan',
                    onAdd: selected.add,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('123.45 EGP'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('pos_type_service')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pos_item_product')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('pos_item_service')));
        expect(selected.single, same(items.first));
        await tester.tap(find.byKey(const ValueKey('pos_type_product')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pos_item_service')), findsNothing);
        expect(find.text('67.89 EGP'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
