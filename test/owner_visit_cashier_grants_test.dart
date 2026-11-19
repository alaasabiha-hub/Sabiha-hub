import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_visit_cashier_grants.dart';

class GrantGateway implements VisitCashierGrantGateway {
  bool alive = true, allowed = false, timeoutOnce = false;
  int version = 0;
  final calls = <Map<String, dynamic>>[];
  @override
  bool get current => alive;
  @override
  Future<Map<String, dynamic>> read(String branch, String rules) async => {
    'staff': [
      {
        'staff_id': 'cashier',
        'name': 'عامل الاختبار',
        'eligible': true,
        'allowed': allowed,
        'version_no': version,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> p) async {
    calls.add(Map.of(p));
    if (timeoutOnce) {
      timeoutOnce = false;
      throw TimeoutException('lost response');
    }
    allowed = p['p_allowed'] == true;
    version++;
    return {
      'version_id': p['p_request'],
      'redemption_activated': false,
      'prior_invoices_changed': false,
    };
  }
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('Owner scoped delegation $lang safe retry and revoke', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = GrantGateway()..timeoutOnce = true;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: SingleChildScrollView(
              child: OwnerVisitCashierGrantsPanel(
                gateway: g,
                branch: 'b',
                rules: 'r',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('عامل الاختبار').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('grant-reason')),
        'QA owner explicit scoped permission',
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(g.calls.length, 1);
      expect(g.calls.first['p_allowed'], true);
      expect(
        find.byType(TextField).evaluate().single.widget,
        isA<TextField>().having(
          (x) => x.enabled,
          'locked uncertain command',
          false,
        ),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(g.calls.length, 2);
      expect(g.calls.first, g.calls.last);
      expect(g.allowed, true);
      expect(tester.takeException(), isNull);
    });
  }
}
