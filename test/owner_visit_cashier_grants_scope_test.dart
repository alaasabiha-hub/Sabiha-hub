import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_visit_cashier_grants.dart';

import 'owner_visit_cashier_grants_test.dart' show GrantGateway;

class LateGrantGateway extends GrantGateway {
  final response = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> read(String branch, String rules) =>
      response.future;
}

Widget host(GrantGateway g, String branch) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: OwnerVisitCashierGrantsPanel(
        gateway: g,
        branch: branch,
        rules: 'r',
      ),
    ),
  ),
);
void main() {
  testWidgets('Late prior branch grant response never crosses scope', (
    tester,
  ) async {
    final old = LateGrantGateway();
    await tester.pumpWidget(host(old, 'old'));
    await tester.pump();
    final current = GrantGateway();
    await tester.pumpWidget(host(current, 'current'));
    await tester.pumpAndSettle();
    old.response.complete({
      'staff': [
        {
          'staff_id': 'secret-old',
          'name': 'OLD PRIVATE STAFF',
          'eligible': true,
          'allowed': true,
          'version_no': 5,
        },
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('OLD PRIVATE STAFF'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('عامل الاختبار'), findsWidgets);
    expect(find.text('OLD PRIVATE STAFF'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Explicit refresh discards uncertain command without resending it',
    (tester) async {
      final g = GrantGateway()..timeoutOnce = true;
      await tester.pumpWidget(host(g, 'b'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('عامل الاختبار').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('grant-reason')),
        'QA explicit revoke pending request',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(g.calls.length, 1);
      await tester.tap(find.text('Refresh delegations'));
      await tester.pumpAndSettle();
      expect(g.calls.length, 1);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
