import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_visits_verbal.dart';

import 'cashier_visits_verbal_test.dart' show VisitsGateway;

class LateVisitsGateway extends VisitsGateway {
  final response = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) =>
      response.future;
}

Widget host(VisitsGateway gateway) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: CashierVisitsVerbalPanel(
        key: const ValueKey('same-panel'),
        gateway: gateway,
        branch: 'b',
        draft: 'd',
        onApproval: (_) {},
        onBusy: (_) {},
        onSelectionPending: (_) {},
      ),
    ),
  ),
);
void main() {
  testWidgets(
    'Late previous gateway cannot reveal its visit context after scope change',
    (t) async {
      final old = LateVisitsGateway();
      final next = VisitsGateway()..enabled = false;
      addTearDown(old.events.close);
      addTearDown(next.events.close);
      await t.pumpWidget(host(old));
      await t.pump();
      await t.pumpWidget(host(next));
      await t.pumpAndSettle();
      old.response.complete({
        'enabled': true,
        'state': 'ready',
        'options': [
          {
            'name': 'old-private-customer',
            'rules_id': 'x',
            'channel_id': 'c',
            'line_id': '1',
            'available_visits': 100,
            'maximum_units': 1,
          },
        ],
        'documents': [],
      });
      await t.pumpAndSettle();
      expect(find.textContaining('old-private-customer'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('Logout clears visit approval details and operator evidence', (
    t,
  ) async {
    final g = VisitsGateway();
    addTearDown(g.events.close);
    await g.call('reserve_cashier_mixed_visits', {'p_request': 'held'});
    await t.pumpWidget(host(g));
    await t.pumpAndSettle();
    final note = find.byKey(const ValueKey('visits_identity_note'));
    await t.ensureVisible(note);
    await t.enterText(note, 'private operator evidence');
    g.alive = false;
    g.events.add(null);
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('private operator evidence'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
