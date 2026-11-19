import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_catalog_buttons.dart';

void main() {
  testWidgets('Category filters and owner order retain source pagination', (
    tester,
  ) async {
    final items = <Map<String, dynamic>>[
      {
        'item_id': 'a',
        'item_type': 'service',
        'name': 'أ',
        'name_en': 'A',
        'price': 10,
        'pos_category_id': 'wash',
        'pos_sort_order': 20,
        'pos_featured': false,
      },
      {
        'item_id': 'b',
        'item_type': 'product',
        'name': 'ب',
        'name_en': 'B',
        'price': 20,
        'pos_category_id': 'care',
        'pos_sort_order': 1,
        'pos_featured': true,
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CashierCatalogButtons(
              items: items,
              arabic: true,
              enabled: true,
              onAdd: (_) {},
              categories: const [
                {'category_id': 'wash', 'name_ar': 'غسيل', 'name_en': 'Wash'},
                {'category_id': 'care', 'name_ar': 'عناية', 'name_en': 'Care'},
              ],
            ),
          ),
        ),
      ),
    );
    final buttons = find.byType(OutlinedButton);
    expect(
      (tester.widget<OutlinedButton>(buttons.first).key),
      const ValueKey('pos_item_b'),
    );
    expect(items.first['item_id'], 'a');
    await tester.tap(find.byKey(const ValueKey('pos_category_wash')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pos_item_b')), findsNothing);
    expect(find.byKey(const ValueKey('pos_item_a')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pos_category_all')));
    await tester.tap(find.byKey(const ValueKey('pos_featured')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pos_item_a')), findsNothing);
    expect(find.byKey(const ValueKey('pos_item_b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
