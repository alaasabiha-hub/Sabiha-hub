import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sabiha_hub/owner_service_commission.dart';
import 'package:sabiha_hub/owner_tax_invoice_settings.dart';

class Gateway implements OwnerTaxGateway {
  bool live = true;
  bool duplicateItems = false;
  final events = StreamController<void>.broadcast();
  final saves = <Map<String, dynamic>>[];
  @override
  bool get current => live;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_owner_service_commission_context') {
      return {
        'branch': 'branch',
        'items': [
          {
            'item_id': 'service',
            'name': 'خدمة',
            'name_en': 'Service',
            'policy': null,
          },
          if (duplicateItems)
            {
              'item_id': 'service',
              'name': 'خدمة مكررة',
              'name_en': 'Duplicate service',
              'policy': null,
            },
        ],
        'staff': [
          {'staff_id': 'worker', 'name': 'QA worker'},
        ],
      };
    }
    if (name == 'save_owner_service_commission') {
      saves.add(params);
      return {'policy_id': 'policy', 'version': 1};
    }
    throw StateError('Unexpected request');
  }
}

void main() {
  testWidgets('duplicate service IDs do not crash commission selection', (
    tester,
  ) async {
    final gateway = Gateway()..duplicateItems = true;
    addTearDown(gateway.events.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerServiceCommissionScreen(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.takeException(), isNull);
    expect(find.text('Duplicate service'), findsNothing);
  });

  for (final ar in [true, false]) {
    testWidgets(
      'Owner future commission save ${ar ? 'ar mobile' : 'en desktop'}',
      (tester) async {
        tester.view.physicalSize = Size(ar ? 390 : 1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = Gateway();
        addTearDown(gateway.events.close);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(ar ? 'ar' : 'en'),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: OwnerServiceCommissionScreen(gateway: gateway),
          ),
        );
        await tester.pumpAndSettle();
        final value = find.widgetWithText(
          TextField,
          ar ? 'إجمالي عمولة الخدمة' : 'Total service commission',
        );
        await tester.ensureVisible(value);
        await tester.enterText(value, '10');
        final reason = find.widgetWithText(
          TextField,
          ar ? 'سبب تغيير السياسة' : 'Reason for policy change',
        );
        await tester.ensureVisible(reason);
        await tester.enterText(reason, 'QA approved future policy');
        final save = find.widgetWithText(
          FilledButton,
          ar ? 'حفظ سياسة مستقبلية' : 'Save future policy',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(gateway.saves.single['p_value'], 10);
        expect(gateway.saves.single['p_expected_version'], 0);
        expect(gateway.saves.single['p_shares'], isEmpty);
        gateway.live = false;
        gateway.events.add(null);
        await tester.pumpAndSettle();
        expect(
          find.text(ar ? 'أعد تسجيل الدخول.' : 'Sign in again.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
