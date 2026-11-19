import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabiha_hub/cashier_checkout.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';

class CheckoutGateway implements CashierCartGateway {
  bool live = true, issued = false, paid = false, lose = false;
  bool stopWork = false, adjusted = false, unpaidStop = false;
  Object? afterReceiptFailure, beforeReceiptFailure;
  final changed = StreamController<void>.broadcast();
  final mutations = <Map<String, dynamic>>[];
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
    if (name == 'get_cashier_mixed_points_context') {
      return {'enabled': false, 'buckets': [], 'documents': []};
    }
    if (name == 'get_cashier_checkout_state') {
      return {
        'kind': 'cashier_checkout_state_v1',
        'draft_id': 'draft',
        'draft_version': 1,
        'branch_id': 'branch',
        'state': issued ? 'issued' : 'draft',
        'role': 'owner',
        'local_now': '2026-11-15T12:00:00',
        'local_today': '2026-11-15',
        'binding': {
          'state': 'bound',
          'binding_version': 2,
          'subject': {'kind': 'app_customer'},
        },
        'open_shifts': [
          {
            'id': 'shift',
            'cashier_name': 'QA cashier',
            'opened_local': '2026-11-15T10:00:00',
          },
        ],
        'can_collect': true,
        'can_refund': true,
        'invoice': issued
            ? {
                'id': 'invoice',
                'number': 'SH-INV-000001',
                'token': 'token',
                'total': 114,
                if (adjusted) 'payable': 80,
                if (adjusted) 'unpaid_credit_amount': 34,
                if (adjusted) 'credit_version': 'qa-credit-version',
                'refunded_amount': 0,
                'payment_status': paid ? 'paid' : 'unpaid',
              }
            : null,
        'work': stopWork
            ? [
                {
                  'order_id': 'work',
                  'name': 'خدمة',
                  'name_en': 'Service',
                  'status': 'in_progress',
                  'reference': 'SH-BKG-000001',
                  'can_open': true,
                  'can_cancel': !unpaidStop,
                  'can_cancel_unpaid': unpaidStop,
                  'unpaid_credit_preview_amount': 34,
                  'physical_clearance_required': true,
                },
              ]
            : [],
        'refund_history': [],
        'refundable_lines': paid
            ? [
                {
                  'line_id': 'line',
                  'name': 'منتج',
                  'name_en': 'Product',
                  'item_type': 'product',
                  'refundable_quantity': 1,
                },
              ]
            : [],
      };
    }
    if (name == 'resolve_cashier_start_time') {
      return {'start_at': '2026-11-15T10:10:00Z'};
    }
    if (name == 'preview_cashier_refund_lines') {
      return {
        'amount': 114,
        'quote_only': true,
        'financial_event_created': false,
        'quote_hash': 'server-hash',
        'lines': [
          {
            'name': 'منتج',
            'name_en': 'Product',
            'quantity': 1,
            'amount': 114,
            'restock': false,
          },
        ],
      };
    }
    mutations.add(
      jsonDecode(jsonEncode({'name': name, 'params': params}))
          as Map<String, dynamic>,
    );
    if (beforeReceiptFailure != null) {
      final failure = beforeReceiptFailure!;
      beforeReceiptFailure = null;
      throw failure;
    }
    if (waiting != null) return waiting!.future;
    Map<String, dynamic> result;
    if (name.startsWith('issue_cashier_')) {
      issued = true;
      result = {'issued': true, 'invoice_id': 'invoice'};
    } else if ((name == 'confirm_cashier_cash_payment' ||
        name == 'confirm_cashier_adjusted_cash')) {
      paid = true;
      result = {
        'invoice_id': 'invoice',
        'payment_id': params['p_request'],
        'sale_recorded': true,
      };
    } else if ((name == 'cancel_cashier_service' ||
        name == 'cancel_unpaid_cashier_service')) {
      result = {
        'request_id': params['p_request'],
        'order_id': params['p_order'],
        'status': 'cancelled',
        'financial_refund_performed': false,
        'unpaid_credit_applied': unpaidStop,
      };
    } else if (name == 'confirm_cashier_refund') {
      result = {'invoice_id': 'invoice', 'refund_id': params['p_request']};
    } else {
      throw StateError('Unexpected RPC $name');
    }
    if (afterReceiptFailure != null) {
      final failure = afterReceiptFailure!;
      afterReceiptFailure = null;
      throw failure;
    }
    if (lose) {
      lose = false;
      throw TimeoutException('Lost acknowledgement');
    }
    return result;
  }
}

Future<void> mount(
  WidgetTester tester,
  CheckoutGateway g,
  String lang,
  double width, {
  bool services = false,
  ValueChanged<bool>? busy,
  VoidCallback? issued,
}) async {
  tester.view.physicalSize = Size(width, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(g.changed.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: CashierCheckoutPanel(
            gateway: g,
            branch: 'branch',
            draft: 'draft',
            version: 1,
            hasServices: services,
            onMutationBusy: busy ?? (_) {},
            onIssued: issued ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets(
      'Unpaid cancellation shows credit and requires physical confirmation $lang',
      (tester) async {
        final g = CheckoutGateway()
          ..issued = true
          ..stopWork = true
          ..unpaidStop = true;
        await mount(tester, g, lang, lang == 'ar' ? 390 : 1440);
        await press(tester, 'checkout_stop_work');
        expect(find.textContaining('34.00'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('service_stop_reason')),
          'QA explicit unpaid cancellation',
        );
        final checks = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(CheckboxListTile),
        );
        for (final check in [checks.first, checks.last]) {
          await tester.ensureVisible(check);
          await tester.tap(check);
          await tester.pumpAndSettle();
        }
        await press(tester, 'service_stop_confirm');
        expect(g.mutations.single['name'], 'cancel_unpaid_cashier_service');
        expect(
          (g.mutations.single['params'] as Map)['p_physical_clearance'],
          true,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Adjusted cash pins reviewed amount and credit version $lang', (
      tester,
    ) async {
      final g = CheckoutGateway()
        ..issued = true
        ..adjusted = true
        ..lose = true;
      await mount(tester, g, lang, lang == 'ar' ? 390 : 1440);
      await press(tester, 'checkout_cash');
      expect(g.mutations.single['name'], 'confirm_cashier_adjusted_cash');
      final params = g.mutations.single['params'] as Map;
      expect(params['p_expected_payable'], 80);
      expect(params['p_credit_version'], 'qa-credit-version');
      await press(tester, 'checkout_retry');
      expect(g.mutations.first, g.mutations.last);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Proxy Postgrest failure retains exact financial request for retry',
    (tester) async {
      final g = CheckoutGateway()
        ..issued = true
        ..afterReceiptFailure = const PostgrestException(
          message: 'Proxy lost response after commit',
          code: '502',
        );
      await mount(tester, g, 'en', 1440);
      await press(tester, 'checkout_cash');
      expect(g.paid, true);
      expect(find.byKey(const ValueKey('checkout_retry')), findsOneWidget);
      await press(tester, 'checkout_retry');
      expect(g.mutations.length, 2);
      expect(g.mutations.first, g.mutations.last);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Explicit database rejection releases pending request without marking paid',
    (tester) async {
      final g = CheckoutGateway()
        ..issued = true
        ..beforeReceiptFailure = const PostgrestException(
          message: 'Permission denied',
          code: '42501',
        );
      await mount(tester, g, 'ar', 390);
      await press(tester, 'checkout_cash');
      expect(g.paid, false);
      expect(find.byKey(const ValueKey('checkout_retry')), findsNothing);
      expect(g.mutations.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final lang in ['ar', 'en']) {
    testWidgets('Checkout shift uses localized date and time $lang', (
      tester,
    ) async {
      final g = CheckoutGateway()
        ..issued = true
        ..paid = true;
      await mount(tester, g, lang, lang == 'ar' ? 390 : 1440);
      expect(find.textContaining('QA cashier'), findsOneWidget);
      expect(find.textContaining('2026-11-15T10:00:00'), findsNothing);
      final labels = MaterialLocalizations.of(
        tester.element(find.byType(CashierCheckoutPanel)),
      );
      final date = DateTime(2026, 11, 15, 10);
      expect(
        find.text(
          'QA cashier · ${labels.formatMediumDate(date)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(date))}',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(g.mutations, isEmpty);
    });
  }

  for (final language in ['ar', 'en']) {
    testWidgets(
      'Service stop requires physical clearance and keeps retry identity $language',
      (tester) async {
        final g = CheckoutGateway()
          ..issued = true
          ..paid = true
          ..stopWork = true
          ..lose = true;
        await mount(tester, g, language, language == 'ar' ? 390 : 1440);
        await press(tester, 'checkout_stop_work');
        final confirm = find.byKey(const ValueKey('service_stop_confirm'));
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.enterText(
          find.byKey(const ValueKey('service_stop_reason')),
          'QA customer requested stop',
        );
        final checks = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(CheckboxListTile),
        );
        await tester.ensureVisible(checks.last);
        await tester.tap(checks.last);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.ensureVisible(checks.first);
        await tester.tap(checks.first);
        await tester.pumpAndSettle();
        await press(tester, 'service_stop_confirm');
        expect(g.mutations.single['name'], 'cancel_cashier_service');
        await press(tester, 'checkout_retry');
        expect(g.mutations.length, 2);
        expect(g.mutations.first, g.mutations.last);
        final params = g.mutations.first['params'] as Map;
        expect(params['p_physical_clearance'], true);
        expect(params['p_expected_status'], 'in_progress');
        expect(
          g.mutations.any((r) => r['name'] == 'confirm_cashier_refund'),
          false,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final lang in ['ar', 'en']) {
    testWidgets(
      '$lang mobile mixed issue lost ACK retries exact nonce then separate cash',
      (tester) async {
        final g = CheckoutGateway()..lose = true;
        final states = <bool>[];
        await mount(tester, g, lang, 390, services: true, busy: states.add);
        expect(tester.takeException(), isNull);
        await press(tester, 'checkout_issue');
        expect(find.byKey(const ValueKey('checkout_retry')), findsOneWidget);
        expect(states.last, isTrue);
        await press(tester, 'checkout_retry');
        expect(g.mutations.length, 2);
        expect(g.mutations[0], g.mutations[1]);
        expect(g.mutations.first['name'], 'issue_cashier_mixed_invoice');
        expect(
          (g.mutations.first['params'] as Map)['p_start'],
          '2026-11-15T10:10:00Z',
        );
        expect(g.paid, isFalse);
        await press(tester, 'checkout_cash');
        expect(g.paid, isTrue);
        expect(g.mutations.last['name'], 'confirm_cashier_cash_payment');
        expect(states.last, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'desktop refund requires authoritative preview and explicit consent',
    (tester) async {
      final g = CheckoutGateway()
        ..issued = true
        ..paid = true;
      await mount(tester, g, 'en', 1440);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Refund reason'),
        'QA customer returned goods',
      );
      await press(tester, 'checkout_refund_preview');
      final confirm = find.byKey(const ValueKey('checkout_refund_confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.ensureVisible(
        find.text('I reviewed the lines, amount and stock-return decision'),
      );
      await tester.tap(
        find.text('I reviewed the lines, amount and stock-return decision'),
      );
      await tester.pumpAndSettle();
      await press(tester, 'checkout_refund_confirm');
      expect(g.mutations.single['name'], 'confirm_cashier_refund');
      final params = g.mutations.single['params'] as Map;
      expect(params['p_quote_hash'], 'server-hash');
      expect((params['p_lines'] as List).single['restock'], false);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in ['ar', 'en']) {
    testWidgets('returned product condition consent $language', (tester) async {
      final g = CheckoutGateway()
        ..issued = true
        ..paid = true;
      await mount(tester, g, language, language == 'ar' ? 390 : 1440);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      final label = language == 'ar'
          ? 'أؤكد استلام المنتج وفحص صلاحيته للبيع قبل إعادته للمخزون'
          : 'I confirm the product was received and checked as fit for resale before restocking';
      final consent = find.widgetWithText(CheckboxListTile, label);
      await tester.ensureVisible(consent);
      expect(tester.widget<CheckboxListTile>(consent).value, false);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(consent).value, true);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(consent).value, false);
      expect(g.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('late issuance result after account switch is discarded', (
    tester,
  ) async {
    final g = CheckoutGateway()..waiting = Completer<Map<String, dynamic>>();
    var shown = 0;
    await mount(tester, g, 'ar', 390, issued: () => shown++);
    await tester.tap(find.byKey(const ValueKey('checkout_issue')));
    await tester.pump();
    g.live = false;
    g.waiting!.complete({'issued': true, 'invoice_id': 'invoice'});
    await tester.pump();
    expect(shown, 0);
    expect(find.text('SH-INV-000001'), findsNothing);
  });
}
