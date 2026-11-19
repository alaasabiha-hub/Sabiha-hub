import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_reward_issuer.dart';

import 'visit_recovery_request_test.dart' as auth;

const request = '22222222-2222-4222-8222-222222222222';
const token = '33333333-3333-4333-8333-333333333333';

class Gateway implements OwnerRewardIssuerGateway {
  @override
  bool current = true;
  bool enabled = false, wrongDue = false;
  Completer<Map<String, dynamic>>? pending;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    calls.add(name);
    return switch (name) {
      'get_owner_reward_issuer_context' => {
        'module': 'owner_reward_issuer_v1',
        'owner_only': true,
        'spending_enabled': enabled,
        'can_prepare': false,
        'can_issue': false,
        'activation_available': false,
        'currency': 'EGP',
        'unit': 'service_visits',
      },
      'list_owner_reward_issues' => {
        'spending_enabled': false,
        'items': [
          {
            'request_id': request,
            'created_at': '2026-11-15T05:00:00Z',
            'state': 'issued',
            'invoice_number': 'SH-INV-900001',
          },
        ],
      },
      'get_owner_reward_issue' =>
        pending != null
            ? await pending!.future
            : {
                'request_id': request,
                'state': 'issued',
                'issuer_public_enabled': false,
                'result': {
                  'invoice_number': 'SH-INV-900001',
                  'invoice_token': token,
                  'currency': 'EGP',
                  'amount_due': wrongDue ? 5 : 0,
                  'gross_amount': 120,
                  'reward_discount': 120,
                  'collectible': false,
                  'work_status': 'completed',
                  'payment_status': 'covered_by_reward',
                },
              },
      _ => throw StateError('Unexpected financial mutation'),
    };
  }
}

class PagedGateway extends Gateway {
  Map<String, dynamic>? cursor;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    if (name != 'list_owner_reward_issues') return super.call(name, parameters);
    calls.add(name);
    cursor = Map.of(parameters);
    return {
      'spending_enabled': false,
      'items': parameters['p_before_request'] != null
          ? []
          : [
              for (var i = 25; i > 0; i--)
                {
                  'request_id':
                      '44444444-4444-4444-8444-${i.toString().padLeft(12, '0')}',
                  'created_at': '2026-11-15T05:00:00Z',
                  'state': 'closed',
                  'invoice_number': null,
                },
            ],
    };
  }
}

Future<void> host(WidgetTester tester, Gateway gateway, String language) async {
  final client = await auth.client(tester);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: OwnerRewardIssuerScreen(
        client: client,
        gateway: gateway,
        invoiceBuilder: (_, value) {
          expect(value, token);
          return const Scaffold(body: Text('QA invoice route'));
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('owned reward receipt and invoice route $language $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = Gateway();
        await host(tester, gateway, language);
        expect(
          Directionality.of(
            tester.element(find.byType(OwnerRewardIssuerScreen)),
          ),
          language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        );
        await tester.tap(find.text('SH-INV-900001'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'ar'
                ? 'المستحق للتحصيل: ٠٫٠٠ جنيه مصري'
                : 'Amount to collect: EGP 0.00',
          ),
          findsOneWidget,
        );
        final invoice = find.text(
          language == 'ar' ? 'عرض الفاتورة وPDF' : 'View invoice and PDF',
        );
        await tester.ensureVisible(invoice);
        await tester.tap(invoice);
        await tester.pumpAndSettle();
        expect(find.text('QA invoice route'), findsOneWidget);
        expect(gateway.calls, [
          'get_owner_reward_issuer_context',
          'list_owner_reward_issues',
          'get_owner_reward_issue',
        ]);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('unknown activated capability fails closed without listing', (
    tester,
  ) async {
    final gateway = Gateway()..enabled = true;
    await host(tester, gateway, 'ar');
    expect(find.text('SH-INV-900001'), findsNothing);
    expect(gateway.calls, ['get_owner_reward_issuer_context']);
  });
  testWidgets('unverified amount hides receipt and invoice route', (
    tester,
  ) async {
    final gateway = Gateway()..wrongDue = true;
    await host(tester, gateway, 'en');
    await tester.tap(find.text('SH-INV-900001'));
    await tester.pumpAndSettle();
    expect(find.text('View invoice and PDF'), findsNothing);
    expect(
      find.text(
        'Authorized data could not be loaded. No financial operation was performed.',
      ),
      findsOneWidget,
    );
  });
  testWidgets('late receipt cannot paint after identity context replacement', (
    tester,
  ) async {
    final gateway = Gateway()..pending = Completer<Map<String, dynamic>>();
    await host(tester, gateway, 'en');
    await tester.tap(find.text('SH-INV-900001'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gateway.pending!.complete({
      'request_id': request,
      'state': 'issued',
      'issuer_public_enabled': false,
    });
    await tester.pumpAndSettle();
    expect(find.text('View invoice and PDF'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('receipt pagination uses exact server cursor and stops at end', (
    tester,
  ) async {
    final gateway = PagedGateway();
    await host(tester, gateway, 'en');
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    for (var i = 0; i < 6; i++) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
    }
    final older = find.text('Load older receipts');
    await tester.ensureVisible(older);
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(gateway.cursor, {
      'p_before_created_at': '2026-11-15T05:00:00Z',
      'p_before_request': '44444444-4444-4444-8444-000000000001',
      'p_limit': 25,
    });
    expect(find.text('Load older receipts'), findsNothing);
    expect(
      gateway.calls.where((name) => name == 'list_owner_reward_issues').length,
      2,
    );
    expect(tester.takeException(), isNull);
  });
}
