import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_customer_registration_test.dart' as fixture;

const actualReceipt = '22222222-2222-4222-8222-222222222222';
const savedRequest = '11111111-1111-4111-8111-111111111111';
const visibleCode = 'SYNTHETIC-PRIVATE-RECEIPT';

class AccessibleGateway extends fixture.FakeRegistrationGateway {
  @override
  Map<String, dynamic> result(
    String id, {
    String status = 'created_unverified',
  }) => {
    ...super.result(id, status: status),
    'enrollment_receipt_id': actualReceipt,
  };
}

Future<void> reference(
  WidgetTester tester,
  String key,
  String label,
  String value,
) async {
  final field = find.byKey(ValueKey('${key}_semantics'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  final data = tester.getSemantics(field).getSemanticsData();
  expect(data.label, '$label: $value');
  expect(data.value, isEmpty);
  expect(data.flagsCollection.isTextField, isFalse);
  // The visual selectable value stays available; no clipboard side effect or
  // second hidden accessibility copy is introduced.
  expect(tester.widget<SelectableText>(find.byKey(ValueKey(key))).data, value);
}

void main() {
  for (final (arabic, width) in [(true, 390.0), (false, 1440.0)]) {
    final locale = arabic ? 'AR390' : 'EN1440';
    final receiptLabel = arabic
        ? 'مرجع إيصال العميل'
        : 'Customer receipt reference';
    final recoveryLabel = arabic
        ? 'مرجع استعادة الموظف'
        : 'Staff recovery reference';
    final codeLabel = arabic
        ? 'رمز الإيصال السري · يظهر مرة واحدة'
        : 'Private receipt code · shown once';

    testWidgets(
      '$locale screen reader receives actual receipt, recovery and visible one-time code',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final api = AccessibleGateway();
          final store = fixture.MemoryRegistrationStore();
          await fixture.mount(tester, api, store, arabic: arabic, width: width);
          await fixture.fill(tester);
          await fixture.press(tester, 'submit_registration');
          await reference(
            tester,
            'enrollment_receipt_reference',
            receiptLabel,
            actualReceipt,
          );
          await reference(
            tester,
            'staff_recovery_reference',
            recoveryLabel,
            store.value!,
          );
          await reference(tester, 'enrollment_secret', codeLabel, visibleCode);
          expect(store.writes, [api.calls.single['p_request']]);
          expect(store.value, isNot(actualReceipt));
          expect(store.value, isNot(visibleCode));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      '$locale recovered receipt exposes no missing code in accessibility tree',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final api = AccessibleGateway();
          api.recovered = {
            ...api.result(savedRequest),
            'enrollment_secret': 'MUST-NOT-RETURN',
          };
          final store = fixture.MemoryRegistrationStore()..value = savedRequest;
          await fixture.mount(tester, api, store, arabic: arabic, width: width);
          await reference(
            tester,
            'enrollment_receipt_reference',
            receiptLabel,
            actualReceipt,
          );
          await reference(
            tester,
            'staff_recovery_reference',
            recoveryLabel,
            savedRequest,
          );
          expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
          expect(
            find.byKey(const ValueKey('enrollment_secret_semantics')),
            findsNothing,
          );
          expect(find.bySemanticsLabel(codeLabel), findsNothing);
          expect(
            tester.getSemantics(find.byType(Scaffold)).toStringDeep(),
            isNot(contains('MUST-NOT-RETURN')),
          );
          expect(store.writes, isEmpty);
          expect(store.value, savedRequest);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'pending saved UUID has a readable recovery value without a fabricated customer receipt',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final store = fixture.MemoryRegistrationStore()..value = savedRequest;
        await fixture.mount(
          tester,
          AccessibleGateway(),
          store,
          arabic: true,
          width: 390,
        );
        await reference(
          tester,
          'staff_recovery_reference',
          'مرجع استعادة الموظف',
          savedRequest,
        );
        expect(
          find.byKey(const ValueKey('enrollment_receipt_reference_semantics')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('enrollment_secret_semantics')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
