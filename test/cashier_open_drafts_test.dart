import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sabiha_hub/cashier_open_drafts.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';

class Gateway implements CashierCartGateway {
  @override
  bool get current => true;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async => {
    'scope': 'own_cashier_branch',
    'loyalty_authorized': false,
    'drafts': List.generate(
      5,
      (i) => {
        'draft_id': 'draft-$i',
        'version': 1,
        'customer_name': 'QA customer $i',
        'car': {'plate_number': 'QA-$i'},
        'total': 100 + i,
        'currency': 'EGP',
        'state': 'open',
        'line_count': i + 1,
      },
    ),
    'has_more': false,
  };
}

void main() {
  testWidgets('Session change rejects late customer draft data', (t) async {
    final g = SessionGateway();
    await t.pumpWidget(
      MaterialApp(
        home: CashierOpenDraftsScreen(gateway: g, branch: 'qa'),
      ),
    );
    g.controller.add(null);
    await t.pump();
    g.pending.complete({
      'scope': 'own_cashier_branch',
      'loyalty_authorized': false,
      'drafts': [
        {'customer_name': 'PRIVATE PREVIOUS CUSTOMER'},
      ],
      'has_more': false,
    });
    await t.pumpAndSettle();
    expect(find.text('Sign in again.'), findsOneWidget);
    expect(find.text('PRIVATE PREVIOUS CUSTOMER'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await g.controller.close();
  });
  navigationTests();
  for (final lang in ['ar', 'en']) {
    testWidgets('Five saved drafts are distinct $lang', (t) async {
      await t.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: CashierOpenDraftsScreen(gateway: Gateway(), branch: 'qa'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('QA customer 0'), findsOneWidget);
      expect(find.text('QA customer 4'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

void navigationTests() {
  testWidgets('Opening each of five drafts returns only its own identifier', (
    t,
  ) async {
    final selected = <String>[];
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final id = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => CashierOpenDraftsScreen(
                      gateway: Gateway(),
                      branch: 'qa',
                    ),
                  ),
                );
                if (id != null) selected.add(id);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('QA customer $i'));
      await t.pumpAndSettle();
      await t.tap(find.text('QA customer $i'));
      await t.pumpAndSettle();
      expect(selected.last, 'draft-$i');
    }
    expect(selected.toSet().length, 5);
  });
}

class SessionGateway extends Gateway {
  final controller = StreamController<void>.broadcast();
  final pending = Completer<Map<String, dynamic>>();
  @override
  Stream<void> get changes => controller.stream;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params) =>
      pending.future;
}
