import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_catalog_buttons.dart';

void main() {
  for (final width in [390.0, 1024.0, 1600.0]) {
    for (final ar in [true, false]) {
      testWidgets('Touch targets and larger text $width ${ar ? 'ar' : 'en'}', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tapped = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1200),
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: Directionality(
                  textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                  child: SingleChildScrollView(
                    child: CashierCatalogButtons(
                      items: const [
                        {
                          'item_id': 'one',
                          'item_type': 'service',
                          'name': 'تنظيف داخلي شامل للسيارة',
                          'name_en': 'Complete interior vehicle cleaning',
                          'price': 123.45,
                        },
                      ],
                      categories: const [
                        {
                          'category_id': 'care',
                          'name_ar': 'العناية بالسيارة',
                          'name_en': 'Car care',
                        },
                      ],
                      arabic: ar,
                      enabled: true,
                      onAdd: tapped.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final target = find.byKey(const ValueKey('pos_item_one'));
        expect(tester.getSize(target).height, greaterThanOrEqualTo(180));
        final button = tester.widget<OutlinedButton>(target);
        expect(
          button.style!.backgroundColor!.resolve({}),
          const Color(0xff071a36),
        );
        expect(button.style!.shape!.resolve({}), isA<RoundedRectangleBorder>());
        await tester.tap(target);
        expect(tapped.single['item_id'], 'one');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
