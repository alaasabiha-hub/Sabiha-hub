import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/loyalty_visit_lifecycle.dart';

class VisitFake implements VisitLifecycleGateway {
  Map<String, dynamic> data = {
    'scheduler_ready': true,
    'actual_cron_run_observed': false,
    'current_policy_enabled': true,
    'policy_version_id': 'policy-one',
    'activation': null,
    'earned_visits': 4,
    'reversed_visits': 1,
    'net_visits': 3,
    'pending_events': 0,
  };
  bool deny = false, loseFirstResponse = false;
  final writes = <(String, String)>[];
  @override
  Future<Map<String, dynamic>> ownerContext(String? branch) async {
    if (deny) throw StateError('denied');
    return Map.from(data);
  }

  @override
  Future<void> activate(String request, String policy) async {
    writes.add((request, policy));
    if (loseFirstResponse && writes.length == 1) throw StateError('network');
    data['activation'] = {'activated_at': '2026-11-14T12:00:00Z'};
  }
}

void main() {
  Future<void> open(
    WidgetTester t,
    Widget child, {
    String locale = 'en',
  }) async {
    t.view.physicalSize = const Size(390, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
    await t.pumpAndSettle();
  }

  for (final locale in ['en', 'ar']) {
    testWidgets('Unobserved worker blocks activation $locale mobile', (
      t,
    ) async {
      final fake = VisitFake();
      await open(t, OwnerVisitLifecyclePanel(gateway: fake), locale: locale);
      expect(
        t.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(fake.writes, isEmpty);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('Owner context denial reveals no balance or activation', (
    t,
  ) async {
    await open(t, OwnerVisitLifecyclePanel(gateway: VisitFake()..deny = true));
    expect(find.byType(FilledButton), findsNothing);
    expect(find.textContaining('Unable to verify'), findsOneWidget);
    expect(find.textContaining('Earned visits'), findsNothing);
  });
  testWidgets(
    'Explicit activation retries same request without changing saved policy',
    (t) async {
      final fake = VisitFake()..loseFirstResponse = true;
      fake.data['actual_cron_run_observed'] = true;
      await open(t, OwnerVisitLifecyclePanel(gateway: fake));
      Future<void> confirm() async {
        await t.tap(find.text('Activate saved policy earning'));
        await t.pumpAndSettle();
        await t.tap(find.text('Activate for future bookings'));
        await t.pumpAndSettle();
      }

      await confirm();
      expect(fake.writes, hasLength(1));
      // A refresh resolves uncertainty while preserving the idempotency identity.
      await t.tap(find.text('Refresh status'));
      await t.pumpAndSettle();
      await confirm();
      expect(fake.writes, hasLength(2));
      expect(fake.writes[0], fake.writes[1]);
      expect(fake.writes.first.$2, 'policy-one');
      expect(find.textContaining('Eligibility starts'), findsOneWidget);
      expect(find.text('Activate saved policy earning'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'Missing canonical ledger is unavailable rather than fabricated zero',
    (t) async {
      await open(t, const CanonicalServiceVisitsCard(summary: null));
      expect(find.text('Currently unavailable'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(
        find.textContaining('Separate from previous points'),
        findsOneWidget,
      );
    },
  );
  testWidgets('Own actual visit balance stays separate from points in Arabic', (
    t,
  ) async {
    await open(
      t,
      const CanonicalServiceVisitsCard(summary: {'net_visits': 0}),
      locale: 'ar',
    );
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('الاستبدال غير مفعّل'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
