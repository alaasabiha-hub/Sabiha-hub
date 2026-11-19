import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cashier_invoice_draft_test.dart' as fixture;

class SealingGateway extends fixture.Gateway {
  bool posted = false;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_checkout_state') {
      return {
        'kind': 'cashier_checkout_state_v1',
        'branch_id': params['p_branch'],
        'draft_id': params['p_draft'],
        'draft_version': 1,
        'state': posted ? 'issued' : 'draft',
        'role': 'owner',
        'local_now': '2026-11-15T12:00:00',
        'local_today': '2026-11-15',
        'binding': {
          'state': 'bound',
          'binding_version': 1,
          'subject': {'kind': 'app_customer'},
        },
        'open_shifts': [],
        'invoice': posted
            ? {
                'id': 'invoice',
                'number': 'SH-INV-000001',
                'token': 'token',
                'total': 279.13,
                'refunded_amount': 0,
                'payment_status': 'unpaid',
              }
            : null,
      };
    }
    if (name == 'issue_cashier_invoice') {
      posted = true;
      return {'issued': true, 'invoice_id': 'invoice'};
    }
    return super.call(name, params);
  }
}

void main() {
  testWidgets(
    'issued parent cart is sealed while a fresh draft stays possible',
    (tester) async {
      final gateway = SealingGateway();
      await fixture.mount(tester, gateway, 'en', 390);
      await tester.tap(
        find.byKey(const ValueKey('pos_item_${fixture.product}')),
      );
      await tester.pumpAndSettle();
      await fixture.save(tester, 'Save draft and calculate on server');
      final issue = find.byKey(const ValueKey('checkout_issue'));
      await tester.scrollUntilVisible(
        issue,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(issue);
      await tester.pumpAndSettle();
      expect(gateway.posted, isTrue);
      final save = find.widgetWithText(
        FilledButton,
        'Save draft and calculate on server',
      );
      await tester.scrollUntilVisible(
        save,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      final fresh = find.widgetWithText(OutlinedButton, 'New draft');
      await tester.scrollUntilVisible(
        fresh,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<OutlinedButton>(fresh).onPressed, isNotNull);
      await tester.ensureVisible(fresh);
      await tester.tap(fresh);
      await tester.pumpAndSettle();
      expect(find.text('SH-INV-000001'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pos_item_${fixture.product}')),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('pos_item_${fixture.product}')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
