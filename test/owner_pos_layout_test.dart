import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sabiha_hub/owner_pos_layout.dart';
import 'package:sabiha_hub/owner_tax_invoice_settings.dart';

class Gateway implements OwnerTaxGateway {
  final events = StreamController<void>.broadcast();
  final saves = <Map<String, dynamic>>[];
  @override
  bool get current => true;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_owner_pos_catalog_layout') {
      return {
        'branch': 'branch',
        'version': 3,
        'has_more': false,
        'items': [
          {'item_id': 'product', 'name': 'منتج', 'name_en': 'Product'},
        ],
        'spec': {
          'categories': [
            {
              'category_id': 'category',
              'name_ar': 'عناية',
              'name_en': 'Care',
              'sort_order': 1,
              'enabled': true,
            },
          ],
          'items': [
            {
              'item_id': 'product',
              'category_id': 'category',
              'sort_order': 2,
              'featured': false,
            },
            {
              'item_id': 'unloaded-item',
              'category_id': null,
              'sort_order': 9,
              'featured': true,
            },
          ],
        },
      };
    }
    if (name == 'save_owner_pos_catalog_layout') {
      saves.add(params);
      return {'layout_id': 'layout', 'version': 4};
    }
    throw StateError('Unexpected action');
  }
}

void main() {
  for (final ar in [true, false]) {
    testWidgets(
      'Owner POS order preserves unloaded assignments ${ar ? 'ar' : 'en'}',
      (tester) async {
        tester.view.physicalSize = Size(ar ? 390 : 1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = Gateway();
        addTearDown(g.events.close);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(ar ? 'ar' : 'en'),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: OwnerPosLayoutEditor(gateway: g, branch: 'branch'),
          ),
        );
        await tester.pumpAndSettle();
        final order = find.byKey(const ValueKey('item_order_product_3'));
        await tester.ensureVisible(order);
        await tester.enterText(order, ar ? '١' : '1');
        final favorite = find.widgetWithText(
          CheckboxListTile,
          ar ? 'ضمن المفضلة' : 'Show in favorites',
        );
        await tester.ensureVisible(favorite);
        await tester.tap(favorite);
        await tester.pumpAndSettle();
        final reason = find.widgetWithText(
          TextField,
          ar ? 'سبب تغيير العرض' : 'Reason for display change',
        );
        await tester.ensureVisible(reason);
        await tester.enterText(reason, 'QA owner layout review');
        final save = find.widgetWithText(
          FilledButton,
          ar ? 'حفظ التصنيفات والترتيب' : 'Save categories and order',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(g.saves.single['p_expected_version'], 3);
        final rows = ((g.saves.single['p_spec'] as Map)['items'] as List)
            .cast<Map>();
        expect(
          rows.firstWhere((x) => x['item_id'] == 'product')['sort_order'],
          1,
        );
        expect(
          rows.firstWhere((x) => x['item_id'] == 'product')['featured'],
          true,
        );
        expect(
          rows.firstWhere((x) => x['item_id'] == 'unloaded-item')['sort_order'],
          9,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
