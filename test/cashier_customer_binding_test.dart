import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cashier_invoice_draft_test.dart' as fixture;

class BindingGateway extends fixture.Gateway {
  bool loseBinding = false;
  final bindings = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? bindingWait;
  Map<String, dynamic>? bindingReceipt;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'find_cashier_customers') {
      return {
        'automatic_account_link': false,
        'loyalty_redemption_authorized': false,
        'candidates': [
          {
            'kind': 'offline_profile',
            'id': 'qa-offline-profile',
            'name': 'QA offline customer',
            'cars': [
              {
                'id': 'qa-owned-car',
                'plate_number': 'QA-OWNED',
                'brand': 'QA brand',
              },
            ],
          },
        ],
      };
    }
    if (name == 'bind_cashier_draft_subject') {
      bindings.add(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(params)) as Map),
      );
      if (bindingWait != null) return bindingWait!.future;
      bindingReceipt ??= {
        'draft_id': params['p_draft'],
        'draft_version': params['p_expected_draft_version'],
        'binding_version': 1,
        'can_issue': false,
        'subject': {
          'kind': 'offline_profile',
          'id': 'qa-offline-profile',
          'name': 'QA offline customer',
          'car': {'id': 'qa-owned-car', 'plate_number': 'QA-OWNED'},
          'loyalty_redemption_authorized': false,
        },
      };
      if (loseBinding) {
        loseBinding = false;
        throw TimeoutException('QA lost binding ACK');
      }
      return bindingReceipt!;
    }
    return super.call(name, params);
  }
}

Future<void> selectCustomer(
  WidgetTester tester,
  BindingGateway g,
  String lang,
  double width,
) async {
  await fixture.mount(tester, g, lang, width);
  await tester.tap(
    find.byTooltip(lang == 'ar' ? 'إضافة بند' : 'Add line').first,
  );
  await tester.pumpAndSettle();
  await fixture.save(
    tester,
    lang == 'ar'
        ? 'حفظ المسودة وحساب السعر من الخادم'
        : 'Save draft and calculate on server',
  );
  final phone = find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        w.decoration?.labelText ==
            (lang == 'ar' ? 'رقم هاتف العميل' : 'Customer phone'),
  );
  await tester.ensureVisible(phone);
  await tester.enterText(phone, '01099887766');
  final search = find.widgetWithText(
    OutlinedButton,
    lang == 'ar' ? 'البحث عن العميل' : 'Find customer',
  );
  await tester.ensureVisible(search);
  await tester.tap(search);
  await tester.pumpAndSettle();
  final car = find.widgetWithText(OutlinedButton, 'QA-OWNED — QA brand ');
  await tester.ensureVisible(car);
  await tester.tap(car);
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('customer/car selection binds without email $lang', (
      tester,
    ) async {
      final g = BindingGateway();
      await selectCustomer(tester, g, lang, lang == 'ar' ? 390 : 1440);
      final confirm = find.widgetWithText(
        FilledButton,
        lang == 'ar' ? 'تأكيد العميل والسيارة' : 'Confirm customer and car',
      );
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(g.bindings.single['p_kind'], 'offline_profile');
      expect(g.bindings.single['p_car'], 'qa-owned-car');
      expect(
        find.text(
          lang == 'ar'
              ? 'العميل والسيارة مرتبطان بالنسخة المحفوظة.'
              : 'Customer and car are bound to this saved version.',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.labelText ?? '').toLowerCase().contains('email'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('changing searched phone clears the previous car choice', (
    tester,
  ) async {
    final g = BindingGateway();
    await selectCustomer(tester, g, 'en', 390);
    final phone = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Customer phone',
    );
    await tester.ensureVisible(phone);
    await tester.enterText(phone, '01011223344');
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(
      FilledButton,
      'Confirm customer and car',
    );
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(g.bindings, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unknown binding ACK freezes cart until exact retry', (
    tester,
  ) async {
    final g = BindingGateway()..loseBinding = true;
    await selectCustomer(tester, g, 'en', 390);
    var confirm = find.widgetWithText(FilledButton, 'Confirm customer and car');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final quantity = find.byKey(const ValueKey('quantity-${fixture.service}'));
    expect(tester.widget<TextField>(quantity).enabled, isFalse);
    final retry = find.widgetWithText(
      FilledButton,
      'Retry the same customer selection',
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(g.bindings.length, 2);
    expect(g.bindings[0], g.bindings[1]);
    expect(tester.widget<TextField>(quantity).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('account change hides customer and ignores late binding', (
    tester,
  ) async {
    final g = BindingGateway()..bindingWait = Completer<Map<String, dynamic>>();
    await selectCustomer(tester, g, 'en', 390);
    final confirm = find.widgetWithText(
      FilledButton,
      'Confirm customer and car',
    );
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pump();
    g.live = false;
    g.changed.add(null);
    await tester.pump();
    expect(find.textContaining('QA offline customer'), findsNothing);
    g.bindingWait!.complete({'can_issue': false});
    await tester.pumpAndSettle();
    expect(find.text('Sign in again to view the draft.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
