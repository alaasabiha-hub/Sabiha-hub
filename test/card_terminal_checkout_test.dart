import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cashier_checkout_test.dart' as existing;

class TerminalGateway extends existing.CheckoutGateway {
  TerminalGateway() {
    issued = true;
  }
  bool enabled = true, loseAck = false;
  final recorded = <String>{};
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_checkout_state') {
      final base = await super.call(name, params);
      return {
        ...base,
        'terminal_manual_enabled': enabled,
        if (base['invoice'] is Map)
          'invoice': {
            ...base['invoice'] as Map,
            if (paid) 'payment_method': 'card_terminal',
          },
      };
    }
    if (name == 'confirm_cashier_terminal_payment') {
      mutations.add({
        'name': name,
        'params': Map<String, dynamic>.from(params),
      });
      paid = true;
      recorded.add(params['p_request'] as String);
      if (loseAck) {
        loseAck = false;
        throw TimeoutException('QA unknown terminal acknowledgement');
      }
      return {
        'sale_recorded': true,
        'invoice_id': 'invoice',
        'payment_id': params['p_request'],
        'method': 'card_terminal',
      };
    }
    if (name == 'confirm_cashier_terminal_refund') {
      mutations.add({
        'name': name,
        'params': Map<String, dynamic>.from(params),
      });
      return {'invoice_id': 'invoice', 'refund_id': params['p_request']};
    }
    return super.call(name, params);
  }
}

void main() {
  testWidgets('Closing terminal dialog records nothing', (t) async {
    final g = TerminalGateway();
    await existing.mount(t, g, 'en', 390);
    await existing.press(t, 'checkout_terminal');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(g.mutations, isEmpty);
    expect(g.paid, false);
  });
  testWidgets('Unknown terminal acknowledgement retries immutable request', (
    t,
  ) async {
    final g = TerminalGateway()..loseAck = true;
    await existing.mount(t, g, 'en', 390);
    await existing.press(t, 'checkout_terminal');
    await t.enterText(find.byType(TextField).at(0), 'QA-POS');
    await t.enterText(find.byType(TextField).at(1), 'QA-SALE-002');
    await t.tap(find.byType(CheckboxListTile).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Record verified payment'));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(g.mutations.length, 1);
    final first = g.mutations.single['params'];
    await t.ensureVisible(find.text('Retry the same checkout request'));
    await t.tap(find.text('Retry the same checkout request'));
    await t.pumpAndSettle();
    expect(g.mutations.length, 2);
    expect(g.mutations.last['params'], first);
    expect(g.recorded.length, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets('Terminal partial refund requires its external receipt', (
    t,
  ) async {
    final g = TerminalGateway()..paid = true;
    await existing.mount(t, g, 'en', 1440);
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pumpAndSettle();
    await t.enterText(
      find.widgetWithText(TextField, 'Refund reason'),
      'QA received refund receipt',
    );
    await existing.press(t, 'checkout_refund_preview');
    await t.tap(
      find.text('I reviewed the lines, amount and stock-return decision'),
    );
    await t.pumpAndSettle();
    await existing.press(t, 'checkout_refund_confirm');
    expect(g.mutations, isEmpty);
    expect(find.text('Verify card refund receipt'), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'Receipt transaction reference'),
      'QA-REFUND-002',
    );
    await t.tap(
      find.text('I verified successful refund and the terminal receipt'),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Record verified refund'));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(g.mutations.single['name'], 'confirm_cashier_terminal_refund');
    expect(g.mutations.single['params']['p_verified'], true);
    expect(t.takeException(), isNull);
  });

  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('Terminal receipt required $lang $width', (t) async {
        final g = TerminalGateway();
        await existing.mount(t, g, lang, width);
        await existing.press(t, 'checkout_terminal');
        final confirm = find.text(
          lang == 'ar' ? 'تسجيل الدفع المؤكد' : 'Record verified payment',
        );
        expect(
          t
              .widget<FilledButton>(
                find.ancestor(of: confirm, matching: find.byType(FilledButton)),
              )
              .onPressed,
          isNull,
        );
        expect(g.mutations, isEmpty);
        await t.enterText(find.byType(TextField).at(0), 'QA-TERMINAL');
        await t.enterText(find.byType(TextField).at(1), 'QA-REF-100');
        await t.tap(find.byType(CheckboxListTile).last);
        await t.pumpAndSettle();
        await t.ensureVisible(confirm);
        await t.tap(confirm);
        await t.pumpAndSettle();
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        expect(g.mutations.length, 1);
        expect(g.mutations.single['params']['p_verified'], true);
        expect(g.mutations.single['params']['p_expected_amount'], 114);
        expect(g.paid, true);
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('Disabled terminal cannot confirm payment', (t) async {
    final g = TerminalGateway()..enabled = false;
    await existing.mount(t, g, 'ar', 390);
    final b = t.widget<OutlinedButton>(
      find.byKey(const ValueKey('checkout_terminal')),
    );
    expect(b.onPressed, isNull);
    expect(g.mutations, isEmpty);
  });
}
