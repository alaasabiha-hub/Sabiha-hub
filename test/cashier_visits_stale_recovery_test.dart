import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_visits_verbal.dart';

import 'cashier_visits_verbal_test.dart' show VisitsGateway;

class StaleVisitsGateway extends VisitsGateway {
  bool released = false;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) async {
    if (name == 'get_cashier_mixed_visits_context') {
      calls.add({'name': name, 'params': p});
      return {
        'enabled': !released,
        'redemption_enabled': false,
        'state': 'stale_hold_requires_release',
        'hold': released
            ? null
            : {'group_id': 'old-group', 'recovery_only': true},
        'approval': null,
        'options': [],
        'documents': [],
      };
    }
    if (name == 'release_cashier_mixed_visits') released = true;
    return super.call(name, p);
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('Stale hold release only $language no prior customer details', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = StaleVisitsGateway();
      addTearDown(g.events.close);
      bool pending = false;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: SingleChildScrollView(
              child: CashierVisitsVerbalPanel(
                gateway: g,
                branch: 'b',
                draft: 'd',
                onBusy: (_) {},
                onSelectionPending: (value) => pending = value,
                onApproval: (value) => expect(value, isNull),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(pending, true);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tester.tap(find.byKey(const ValueKey('visits_release_stale')));
      await tester.pumpAndSettle();
      expect(pending, false);
      expect(g.released, true);
      final releases = g.calls.where(
        (x) => x['name'] == 'release_cashier_mixed_visits',
      );
      expect(releases.length, 1);
      expect(releases.single['params']['p_group'], 'old-group');
      expect(tester.takeException(), isNull);
    });
  }
}
