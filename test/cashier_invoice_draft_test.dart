import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';

const branch = '10000000-0000-4000-8000-000000000001',
    service = '20000000-0000-4000-8000-000000000001',
    product = '30000000-0000-4000-8000-000000000001',
    worker = '40000000-0000-4000-8000-000000000001';

class Gateway implements CashierCartGateway {
  bool live = true, lose = false, owner = true, loseTax = false;
  bool bound = false;
  int taxVersion = 0;
  final taxCalls = <Map<String, dynamic>>[];
  Map<String, dynamic>? taxReceipt;
  final changed = StreamController<void>.broadcast(sync: true);
  final saves = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>>? waiting;
  @override
  bool get current => live;
  @override
  Stream<void> get changes => changed.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_reviewed_context') {
      return {
        'kind': 'cashier_cart_reviewed_quote_v2',
        'quote_only': true,
        'can_issue': false,
        'can_discount': true,
        'owner': owner,
        'has_more': false,
        'tax_rules': [],
        'tax_rules_version': taxVersion,
        'staff': [
          {'staff_id': worker, 'name': 'QA worker'},
        ],
        'items': [
          {
            'item_id': service,
            'name': 'خدمة اختبار',
            'name_en': 'QA service',
            'item_type': 'service',
            'price': 100.01,
          },
          {
            'item_id': product,
            'name': 'منتج اختبار',
            'name_en': 'QA product',
            'item_type': 'product',
            'price': 20.03,
          },
        ],
      };
    }
    if (name == 'get_cashier_checkout_state') {
      return {
        'kind': 'cashier_checkout_state_v1',
        'branch_id': params['p_branch'],
        'draft_id': params['p_draft'],
        'draft_version': 1,
        'state': 'draft',
        'role': 'owner',
        'local_now': '2026-11-15T12:00:00',
        'local_today': '2026-11-15',
        'binding': {'state': 'unbound'},
        'open_shifts': [],
      };
    }
    if (name == 'get_cashier_draft_subject') {
      return bound
          ? {
              'state': 'bound',
              'binding_version': 1,
              'subject': {
                'kind': 'app_customer',
                'id': '50000000-0000-4000-8000-000000000001',
                'name': 'QA customer',
                'car': {
                  'id': '60000000-0000-4000-8000-000000000001',
                  'plate_number': 'QA-1',
                  'brand': 'QA',
                  'model': 'Sedan',
                },
              },
            }
          : {'state': 'unbound', 'binding_version': 0};
    }
    if (name == 'get_cashier_vehicle_service_prices') {
      return {
        'ready': bound,
        'draft_version': params['p_version'],
        'binding_version': 1,
        'vehicle_class_code': 'sedan',
        'vehicle_class_name_ar': 'سيدان',
        'vehicle_class_name_en': 'Sedan',
        'prices': {service: 125.0},
      };
    }
    if (name == 'get_cashier_reviewed_draft') return {'state': 'absent'};
    if (name == 'find_cashier_customers') {
      return {
        'automatic_account_link': false,
        'loyalty_redemption_authorized': false,
        'candidates': [
          {
            'kind': 'app_customer',
            'id': '50000000-0000-4000-8000-000000000001',
            'name': 'QA customer',
            'cars': [
              {
                'id': '60000000-0000-4000-8000-000000000001',
                'plate_number': 'QA-1',
                'brand': 'QA',
                'model': 'Sedan',
              },
            ],
          },
        ],
      };
    }
    if (name == 'bind_cashier_draft_subject') {
      bound = true;
      return {
        'draft_id': params['p_draft'],
        'draft_version': params['p_expected_draft_version'],
        'binding_version': 1,
        'can_issue': false,
        'subject': {
          'kind': 'app_customer',
          'id': '50000000-0000-4000-8000-000000000001',
          'name': 'QA customer',
          'car': {
            'id': '60000000-0000-4000-8000-000000000001',
            'plate_number': 'QA-1',
            'brand': 'QA',
            'model': 'Sedan',
          },
        },
      };
    }
    if (name != 'save_cashier_reviewed_draft') {
      throw StateError('Unexpected RPC');
    }
    saves.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(params)) as Map));
    if (waiting != null) return waiting!.future;
    final receipt = receipts.putIfAbsent(
      params['p_request'] as String,
      () => {
        'draft_id': params['p_draft'],
        'version': (params['p_expected_version'] as int) + 1,
        'quote': {
          'kind': 'cashier_cart_reviewed_quote_v2',
          'quote_only': true,
          'can_issue': false,
          'earned_commission': false,
          'vehicle_pricing_ready': true,
          'unconfigured_tax_items': 0,
          'subtotal_before_discount_exact': 300.03,
          'invoice_discount_exact': 40.09,
          'tax_amount_exact': 19.19,
          'total': 279.13,
          'lines': [],
        },
      },
    );
    if (lose) {
      lose = false;
      throw TimeoutException('QA lost ACK');
    }
    return receipt;
  }
}

Future<void> mount(
  WidgetTester tester,
  Gateway gateway,
  String lang,
  double width,
) async {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(gateway.changed.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: CashierInvoiceDraftScreen(gateway: gateway, branch: branch),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester, String text) async {
  final b = find.widgetWithText(FilledButton, text);
  await tester.ensureVisible(b);
  await tester.tap(b);
  await tester.pumpAndSettle();
}

Future<void> chooseWorker(WidgetTester tester, String lang) async {
  expect(
    tester
        .widget<FilledButton>(
          find.widgetWithText(
            FilledButton,
            lang == 'ar' ? 'حفظ الاختيار' : 'Save selection',
          ),
        )
        .onPressed,
    isNull,
  );
  await tester.tap(find.text('QA worker'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(lang == 'ar' ? 'حفظ الاختيار' : 'Save selection'));
  await tester.pumpAndSettle();
}

Future<void> bindQaSedan(WidgetTester tester, String lang) async {
  final phone = find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        w.decoration?.labelText ==
            (lang == 'ar' ? 'رقم هاتف العميل' : 'Customer phone'),
  );
  await tester.enterText(phone, '+201000000001');
  await tester.tap(
    find.text(lang == 'ar' ? 'البحث عن العميل' : 'Find customer'),
  );
  await tester.pumpAndSettle();
  final car = find.textContaining('QA-1');
  final scrollable = find
      .byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      )
      .first;
  await tester.dragUntilVisible(car, scrollable, const Offset(0, -420));
  await tester.tap(car);
  await tester.pumpAndSettle();
  final confirm = find.text(
    lang == 'ar' ? 'تأكيد العميل والسيارة' : 'Confirm customer and car',
  );
  await tester.dragUntilVisible(confirm, scrollable, const Offset(0, -420));
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  await save(
    tester,
    lang == 'ar'
        ? 'حفظ المسودة وحساب السعر من الخادم'
        : 'Save draft and calculate on server',
  );
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'cashier draft edits quantities removes line and uses server totals $lang $width',
        (tester) async {
          final g = Gateway();
          await mount(tester, g, lang, width);
          final add = find.byTooltip(lang == 'ar' ? 'إضافة بند' : 'Add line');
          await tester.tap(find.byKey(ValueKey('pos_item_$product')));
          await tester.pumpAndSettle();
          await save(
            tester,
            lang == 'ar'
                ? 'حفظ المسودة وحساب السعر من الخادم'
                : 'Save draft and calculate on server',
          );
          await bindQaSedan(tester, lang);
          await tester.tap(find.byKey(ValueKey('pos_item_$service')));
          await tester.pumpAndSettle();
          await chooseWorker(tester, lang);
          await tester.tap(add.last);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('quantity-$service')),
            lang == 'ar' ? '٣' : '3',
          );
          final remove = find
              .widgetWithText(
                TextButton,
                lang == 'ar' ? 'حذف البند' : 'Remove line',
              )
              .first;
          await tester.ensureVisible(remove);
          await tester.tap(remove);
          await tester.pumpAndSettle();
          await save(
            tester,
            lang == 'ar'
                ? 'حفظ المسودة وحساب السعر من الخادم'
                : 'Save draft and calculate on server',
          );
          final lines = g.saves.last['p_items'] as List;
          expect(lines, [
            {
              'item_id': service,
              'quantity': 3,
              'staff_ids': [worker],
            },
          ]);
          expect(lines.single.containsKey('unit_price'), isFalse);
          expect(
            find.textContaining('279.13 EGP'),
            findsNWidgets(2),
          ); // Summary and detailed server total.
          expect(g.saves.last['p_discount_value'], '0');
          await tester.ensureVisible(
            find.byKey(const ValueKey('quantity-$service')),
          );
          await tester.enterText(
            find.byKey(const ValueKey('quantity-$service')),
            '5',
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('279.13 EGP'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'cashier draft lost ACK freezes edits and retries exact nonce payload',
    (tester) async {
      final g = Gateway()..lose = true;
      await mount(tester, g, 'en', 390);
      await tester.tap(find.byKey(ValueKey('pos_item_$product')));
      await tester.pumpAndSettle();
      await save(tester, 'Save draft and calculate on server');
      expect(g.saves.length, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('quantity-$product')))
            .enabled,
        isFalse,
      );
      await save(tester, 'Retry the same save');
      expect(g.saves.length, 2);
      expect(g.saves[0], g.saves[1]);
      expect(
        find.textContaining('279.13 EGP'),
        findsNWidgets(2),
      ); // Summary and detailed server total.
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cashier draft drops late results after account change', (
    tester,
  ) async {
    final g = Gateway()..waiting = Completer<Map<String, dynamic>>();
    await mount(tester, g, 'en', 390);
    await tester.tap(find.byKey(ValueKey('pos_item_$product')));
    await tester.pumpAndSettle();
    final b = find.widgetWithText(
      FilledButton,
      'Save draft and calculate on server',
    );
    await tester.ensureVisible(b);
    await tester.tap(b);
    await tester.pump();
    g.live = false;
    g.changed.add(null);
    await tester.pumpAndSettle();
    g.waiting!.complete({
      'draft_id': g.saves.single['p_draft'],
      'version': 1,
      'quote': {
        'kind': 'cashier_cart_reviewed_quote_v2',
        'quote_only': true,
        'can_issue': false,
        'earned_commission': false,
        'unconfigured_tax_items': 0,
        'total': 279.13,
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('Sign in again to view the draft.'), findsOneWidget);
    expect(find.textContaining('279.13'), findsNothing);
    expect(find.byKey(const ValueKey('quantity-$product')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final owner in [true, false]) {
    testWidgets('reviewed draft cannot override tax owner=$owner', (
      tester,
    ) async {
      final g = Gateway()..owner = owner;
      await mount(tester, g, 'ar', 390);
      expect(find.byIcon(Icons.percent), findsNothing);
      expect(g.taxCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
