import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';
import 'package:sabiha_hub/cashier_checkout.dart';

import 'cashier_invoice_draft_test.dart' as fixture;

class LiveGateway extends fixture.Gateway implements CashierCatalogUpdates {
  final updates = StreamController<void>.broadcast();
  bool updated = false, offline = false;
  @override
  Stream<void> catalogChanges(String branch) => updates.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_reviewed_context' && offline) {
      throw TimeoutException('QA offline');
    }
    final result = await super.call(name, params);
    if (name == 'get_cashier_reviewed_context' && updated) {
      result['items'] = [
        {
          'item_id': fixture.product,
          'name': 'منتج محدث',
          'name_en': 'Updated product',
          'item_type': 'product',
          'price': 99.99,
        },
        {
          'item_id': 'new-service',
          'name': 'خدمة جديدة',
          'name_en': 'New service',
          'item_type': 'service',
          'price': 45,
        },
      ];
    }
    return result;
  }
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets(
      'Live catalogue preserves draft, invalidates quote and recovers $lang',
      (tester) async {
        final g = LiveGateway();
        addTearDown(g.updates.close);
        addTearDown(g.changed.close);
        await fixture.mount(tester, g, lang, lang == 'ar' ? 390 : 1440);
        await tester.tap(
          find.byKey(const ValueKey('pos_item_${fixture.service}')),
        );
        await tester.pumpAndSettle();
        await fixture.chooseWorker(tester, lang);
        final product = find.byKey(
          const ValueKey('pos_item_${fixture.product}'),
        );
        await tester.ensureVisible(product);
        await tester.tap(product);
        await tester.pumpAndSettle();
        await fixture.save(
          tester,
          lang == 'ar'
              ? 'حفظ المسودة وحساب السعر من الخادم'
              : 'Save draft and calculate on server',
        );
        expect(g.saves, hasLength(1));
        await tester.drag(find.byType(ListView).first, const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(find.byType(CashierCheckoutPanel), findsOneWidget);
        g.updated = true;
        g.updates.add(null);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('pos_item_${fixture.service}')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('pos_item_new-service')),
          findsOneWidget,
        );
        expect(find.text('99.99 EGP'), findsOneWidget);
        final quantity = find.byKey(
          const ValueKey('quantity-${fixture.service}'),
        );
        await tester.ensureVisible(quantity);
        expect(tester.widget<TextField>(quantity).controller!.text, '1');
        g.offline = true;
        g.updates.add(null);
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('pos_item_${fixture.product}'));
        await tester.ensureVisible(add);
        expect(tester.widget<OutlinedButton>(add).onPressed, isNull);
        g.offline = false;
        g.updates.add(null);
        await tester.pumpAndSettle();
        expect(tester.widget<OutlinedButton>(add).onPressed, isNotNull);
        expect(g.saves, hasLength(1));
        expect(find.byType(CashierCheckoutPanel), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
