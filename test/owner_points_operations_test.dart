import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_points_operations.dart';
import 'package:sabiha_hub/owner_points_policy.dart';

class OperationsGateway implements OwnerPointsGateway {
  final changed = StreamController<void>.broadcast();
  bool live = true, allowed = false, lose = false;
  int version = 2;
  String? decision;
  final calls = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  @override
  bool get current => live;
  @override
  Stream<void> get changes => changed.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    calls.add({'name': name, 'params': Map.from(params)});
    if (name == 'get_owner_mixed_points_operations') {
      return {
        'activation_supported': false,
        'earning_runtime_enabled': false,
        'redemption_runtime_enabled': false,
        'has_more': false,
        'verbal_policy': {'version': version, 'allowed': allowed},
        'reviews': [
          {
            'lot_id': 'lot',
            'invoice_number': 'SH-INV-000123',
            'points': '25',
            'refund_amount': 102.60,
            'created_at': '2026-11-16T10:00:00Z',
            'decision': decision,
            'decision_reason': decision == null
                ? null
                : 'Original documents reviewed',
          },
        ],
      };
    }
    final nonce = params['p_request'] as String;
    if (receipts.containsKey(nonce)) return receipts[nonce]!;
    Map<String, dynamic> result;
    if (name == 'save_owner_mixed_points_verbal_policy') {
      version++;
      allowed = params['p_allowed'] == true;
      result = {'version': version, 'allowed': allowed};
    } else if (name == 'decide_owner_mixed_points_refund_review') {
      decision = params['p_decision'] as String;
      result = {'lot': params['p_lot'], 'decision': decision};
    } else {
      throw StateError(name);
    }
    receipts[nonce] = result;
    if (lose) {
      lose = false;
      throw TimeoutException('Lost reply');
    }
    return result;
  }
}

Future<void> mount(
  WidgetTester t,
  OperationsGateway g,
  String lang,
  double width,
) async {
  t.view.physicalSize = Size(width, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(g.changed.close);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OwnerPointsOperationsPanel(gateway: g, branch: 'branch'),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.byType(ExpansionTile));
  await t.pumpAndSettle();
}

class WaitingOperationsGateway extends OperationsGateway {
  final waiting = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params) {
    if (name == 'get_owner_mixed_points_operations') {
      calls.add({'name': name, 'params': Map.from(params)});
      return waiting.future;
    }
    return super.call(name, params);
  }
}

void main() {
  testWidgets(
    'Owner scope change clears old review data and ignores old gateway events',
    (t) async {
      final first = OperationsGateway(), second = WaitingOperationsGateway();
      addTearDown(first.changed.close);
      addTearDown(second.changed.close);
      Widget app(OperationsGateway g, String branch) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OwnerPointsOperationsPanel(gateway: g, branch: branch),
          ),
        ),
      );
      await t.pumpWidget(app(first, 'first'));
      await t.pumpAndSettle();
      await t.tap(find.byType(ExpansionTile));
      await t.pumpAndSettle();
      expect(find.textContaining('SH-INV-000123'), findsOneWidget);
      await t.pumpWidget(app(second, 'second'));
      await t.pump();
      expect(find.textContaining('SH-INV-000123'), findsNothing);
      first.changed.add(null);
      await t.pump();
      second.waiting.complete({
        'activation_supported': false,
        'verbal_policy': {'version': 0, 'allowed': false},
        'reviews': [],
        'has_more': false,
        'redemption_runtime_enabled': false,
      });
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('owner_verbal_allowed')),
        findsOneWidget,
      );
      expect(second.calls.single['params']['p_branch'], 'second');
      expect(t.takeException(), isNull);
    },
  );

  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1024.0, 1440.0]) {
      testWidgets(
        'Owner verbal permission and independent refund decision $lang $width',
        (t) async {
          final g = OperationsGateway();
          await mount(t, g, lang, width);
          await t.tap(find.byKey(const ValueKey('owner_verbal_allowed')));
          await t.pumpAndSettle();
          await t.enterText(
            find.byKey(const ValueKey('owner_verbal_reason')),
            'Owner explicitly permits independent identity checks',
          );
          final save = find.text(
            lang == 'ar'
                ? 'حفظ إذن الموافقة الشفهية'
                : 'Save verbal approval permission',
          );
          await t.ensureVisible(save);
          await t.tap(save);
          await t.pumpAndSettle();
          expect(g.allowed, true);
          expect(
            find.textContaining(
              lang == 'ar'
                  ? 'حالة الصرف العام: غير مفعّل'
                  : 'Redemption runtime: Disabled',
            ),
            findsOneWidget,
          );
          final dropdown = find.byKey(
            const ValueKey('owner_points_decision_lot'),
          );
          await t.ensureVisible(dropdown);
          await t.tap(dropdown);
          await t.pumpAndSettle();
          await t.tap(
            find
                .text(lang == 'ar' ? 'الإبقاء على النقاط' : 'Preserve points')
                .last,
          );
          await t.pumpAndSettle();
          await t.enterText(
            find.byKey(const ValueKey('owner_points_reason_lot')),
            'Original service documents independently reviewed',
          );
          final decide = find.text(
            lang == 'ar' ? 'تسجيل قرار المراجعة' : 'Record review decision',
          );
          await t.ensureVisible(decide);
          await t.tap(decide);
          await t.pumpAndSettle();
          expect(g.decision, 'preserve_rights');
          expect(
            g.calls
                .where(
                  (x) => x['name'] == 'decide_owner_mixed_points_refund_review',
                )
                .length,
            1,
          );
          expect(
            g.calls.any((x) => '${x['name']}'.contains('activate')),
            false,
          );
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'Owner uncertain save retains exact request and does not activate runtime',
    (t) async {
      final g = OperationsGateway()..lose = true;
      await mount(t, g, 'en', 1440);
      await t.enterText(
        find.byKey(const ValueKey('owner_verbal_reason')),
        'Owner explicitly closes permission',
      );
      final save = find.text('Save verbal approval permission');
      await t.ensureVisible(save);
      await t.tap(save);
      await t.pumpAndSettle();
      final retry = find.text('Retry the same owner request');
      await t.ensureVisible(retry);
      await t.tap(retry);
      await t.pumpAndSettle();
      final writes = g.calls
          .where((x) => x['name'] == 'save_owner_mixed_points_verbal_policy')
          .toList();
      expect(writes.length, 2);
      expect(writes[0], writes[1]);
      expect(g.version, 3);
      expect(g.allowed, false);
      g.live = false;
      g.changed.add(null);
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    },
  );
}
