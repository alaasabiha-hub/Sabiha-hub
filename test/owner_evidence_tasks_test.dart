import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_evidence_tasks.dart';

Map<String, dynamic> task() => {
  'task_id': '00000000-0000-4000-8000-000000000001',
  'action': 'verify_stock_counts',
  'from': '2026-11-01',
  'to': '2026-11-15',
  'state': 'proposed',
  'version': 1,
  'evidence': {
    'metrics': [
      {'code': 'active_products', 'value': 7, 'unit': 'count'},
    ],
  },
};

class Gateway implements OwnerEvidenceTasksGateway {
  @override
  String? actor = 'owner';
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get authChanges => changes.stream;
  Map<String, dynamic> row = task();
  final commands = <Map<String, dynamic>>[];
  bool lose = false;
  Map<String, dynamic>? firstResult;
  @override
  Future<List<Map<String, dynamic>>> list() async => [
    Map<String, dynamic>.from(row),
  ];
  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> params) async {
    commands.add(Map<String, dynamic>.from(params));
    if (firstResult != null) return firstResult!;
    row = {
      ...row,
      'state': params['p_state'],
      'version': (row['version'] as int) + 1,
    };
    if (lose) {
      firstResult = Map<String, dynamic>.from(row);
      lose = false;
      throw TimeoutException('lost acknowledgement');
    }
    return row;
  }

  @override
  Future<List<Map<String, dynamic>>> history(String task) async => [
    {
      'after_state': 'approved',
      'reason': 'sensitive audit note',
      'created_at': '2026-11-15T09:00:00Z',
    },
  ];
}

Future<void> mount(
  WidgetTester tester,
  Gateway gateway,
  String lang,
  double width,
) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(gateway.changes.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: OwnerEvidenceTasksScreen(
        gateway: gateway,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 15),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> decide(WidgetTester tester, String button, String confirm) async {
  final target = find.widgetWithText(OutlinedButton, button);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'Reviewed recorded evidence');
  await tester.pump();
  await tester.tap(find.widgetWithText(TextButton, confirm));
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('owner manual approval and completion $lang $width', (
        tester,
      ) async {
        final g = Gateway();
        await mount(tester, g, lang, width);
        final ar = lang == 'ar';
        expect(
          Directionality.of(
            tester.element(find.byType(OwnerEvidenceTasksScreen)),
          ),
          ar ? TextDirection.rtl : TextDirection.ltr,
        );
        await decide(
          tester,
          ar ? 'موافقة على المراجعة' : 'Approve review',
          ar ? 'تأكيد' : 'Confirm',
        );
        expect(g.commands.single['p_state'], 'approved');
        expect(g.commands.single['p_expected_version'], 1);
        await decide(
          tester,
          ar
              ? 'تسجيل إتمام المراجعة يدويًا'
              : 'Record manual review completion',
          ar ? 'تأكيد' : 'Confirm',
        );
        expect(g.commands.length, 2);
        expect(g.commands.last['p_state'], 'completed');
        expect(g.commands.last['p_expected_version'], 2);
        expect(
          find.text(
            ar
                ? 'سجّل المالك إتمام المراجعة'
                : 'Owner recorded review completion',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('lost acknowledgement retains exact review nonce and payload', (
    tester,
  ) async {
    final g = Gateway()..lose = true;
    await mount(tester, g, 'en', 390);
    await decide(tester, 'Approve review', 'Confirm');
    expect(g.commands.length, 1);
    final retry = find.widgetWithText(FilledButton, 'Retry the same request');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(g.commands.length, 2);
    expect(g.commands[1], g.commands[0]);
    expect(find.text('Approved for manual review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('open audit dialog hides private history after account change', (
    tester,
  ) async {
    final g = Gateway();
    await mount(tester, g, 'en', 390);
    final history = find.widgetWithText(TextButton, 'Decision history');
    await tester.ensureVisible(history);
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.textContaining('sensitive audit note'), findsOneWidget);
    g.actor = null;
    g.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('sensitive audit note'), findsNothing);
    expect(find.text('Session ended'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
