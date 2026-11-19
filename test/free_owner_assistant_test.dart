import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/free_owner_assistant.dart';

Map<String, dynamic> answer(
  String topic,
  String from,
  String to, {
  bool ar = false,
}) {
  final missing = topic == 'profit';
  return {
    'topic': topic,
    'mode': 'free_evidence_templates',
    'scope': 'active_default_branch',
    'period': {'from': from, 'to': to},
    'paid_provider_allowed': false,
    'execution_supported': false,
    'requires_owner_review': true,
    'state': missing ? 'missing_data' : 'answer',
    'answer': missing
        ? 'Actual profit is unavailable because costs are incomplete.'
        : ar
        ? 'إجمالي الفواتير المسجل: ١٢٣ جنيه مصري.'
        : 'Recorded invoice total: 123 EGP.',
    'facts': missing
        ? []
        : [
            {
              'id': 'billed_revenue',
              'source': 'business_invoices',
              'unit': 'EGP',
              'basis': 'window',
              'value': 123,
              'count': 2,
            },
          ],
    'citations': missing
        ? []
        : [
            {
              'evidence_id': 'billed_revenue',
              'source': 'business_invoices',
              'basis': 'window',
              'count': 2,
            },
          ],
    'limitations': [
      'active_default_branch_only',
      'incomplete_costs_no_actual_profit',
      'no_forecast_or_causal_inference',
    ],
  };
}

class FakeGateway implements FreeOwnerAssistantGateway {
  String? user = 'owner';
  final events = StreamController<void>.broadcast(sync: true);
  final calls = <Map<String, String>>[];
  Completer<Map<String, dynamic>>? pending;
  Object? failure;
  bool malformed = false;
  Map<String, dynamic>? responseFixture;
  @override
  String? get currentUserId => user;
  @override
  Stream<void> get authChanges => events.stream;
  @override
  Future<Map<String, dynamic>> ask({
    required String topic,
    required String language,
    required String from,
    required String to,
  }) async {
    calls.add({'topic': topic, 'language': language, 'from': from, 'to': to});
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    final result =
        responseFixture ?? answer(topic, from, to, ar: language == 'ar');
    if (malformed) {
      result['citations'] = [
        {
          'evidence_id': 'billed_revenue',
          'source': 'private_customers',
          'basis': 'window',
          'count': 2,
        },
      ];
    }
    return result;
  }
}

void main() {
  final from = DateTime(2026, 11, 1), to = DateTime(2026, 11, 15);
  Widget host(FakeGateway gateway, {String locale = 'en', DateTime? end}) =>
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: FreeOwnerAssistantPanel(
              key: const ValueKey('panel'),
              gateway: gateway,
              from: from,
              to: end ?? to,
            ),
          ),
        ),
      );
  Future<void> select(WidgetTester t, String text) async {
    const values = <String, String>{
      'Invoice totals': 'billing',
      'إجمالي الفواتير': 'billing',
      'Cash collections': 'collections',
      'التحصيل النقدي': 'collections',
      'Is actual profit available?': 'profit',
      'هل الربح الفعلي متاح؟': 'profit',
    };
    final dropdown = t.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('free-owner-topic')),
    );
    dropdown.onChanged!(values[text]!);
    await t.pumpAndSettle();
  }

  Future<void> ask(WidgetTester t) async {
    await t.ensureVisible(find.byKey(const ValueKey('free-owner-ask')));
    await t.tap(find.byKey(const ValueKey('free-owner-ask')));
    await t.pumpAndSettle();
  }

  for (final locale in ['ar', 'en']) {
    testWidgets(
      'free assistant $locale layout, supported picker and source labels',
      (t) async {
        t.view.physicalSize = Size(locale == 'ar' ? 390 : 1440, 1400);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final g = FakeGateway();
        addTearDown(g.events.close);
        await t.pumpWidget(host(g, locale: locale));
        expect(find.byType(TextField), findsNothing);
        await select(t, locale == 'ar' ? 'إجمالي الفواتير' : 'Invoice totals');
        await ask(t);
        expect(g.calls.single, {
          'topic': 'billing',
          'language': locale,
          'from': '2026-11-01',
          'to': '2026-11-15',
        });
        expect(find.byKey(const ValueKey('free-owner-answer')), findsOneWidget);
        expect(
          find.textContaining(locale == 'ar' ? 'الفواتير ·' : 'Invoices ·'),
          findsOneWidget,
        );
        expect(find.textContaining('business_invoices'), findsNothing);
        expect(
          find.text(
            locale == 'ar'
                ? 'التكاليف غير مكتملة؛ الربح الفعلي غير متاح.'
                : 'Costs are incomplete; actual profit is unavailable.',
          ),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'free assistant default summary renders all production-handler facts and footer',
    (t) async {
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final fixture = Map<String, dynamic>.from(
        jsonDecode(
          File('test/fixtures/free_owner_summary_ar.json').readAsStringSync(),
        ) as Map,
      );
      final g = FakeGateway()..responseFixture = fixture;
      addTearDown(g.events.close);
      await t.pumpWidget(host(g, locale: 'ar'));
      await ask(t);
      expect(g.calls.single['topic'], 'summary');
      expect(fixture['fixture_only'], true);
      expect((fixture['facts'] as List).length, 18);
      expect((fixture['citations'] as List).length, 18);
      expect(find.text(fixture['answer'] as String), findsOneWidget);
      expect(find.textContaining('السجلات المطابقة'), findsNWidgets(18));
      final footer = find.text(
        'مراجعة المالك مطلوبة؛ لا ينفّذ المساعد أي إجراء.',
      );
      await t.ensureVisible(footer);
      await t.pumpAndSettle();
      expect(footer, findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'free assistant missing data is explicit with no invented citations',
    (t) async {
      final g = FakeGateway();
      addTearDown(g.events.close);
      await t.pumpWidget(host(g));
      await select(t, 'Is actual profit available?');
      await ask(t);
      expect(find.text('Unavailable or incomplete data'), findsOneWidget);
      expect(
        find.text(
          'No evidence-backed figures are available to calculate this result.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('123 EGP'), findsNothing);
    },
  );
  testWidgets(
    'free assistant owner denial and invalid citations reveal no stale answer',
    (t) async {
      final g = FakeGateway();
      addTearDown(g.events.close);
      await t.pumpWidget(host(g));
      await select(t, 'Invoice totals');
      await ask(t);
      expect(find.byKey(const ValueKey('free-owner-answer')), findsOneWidget);
      g.failure = const FunctionException(
        status: 403,
        details: 'private server details',
      );
      await ask(t);
      expect(find.byKey(const ValueKey('free-owner-answer')), findsNothing);
      expect(find.textContaining('owner access denied'), findsOneWidget);
      expect(find.textContaining('private server details'), findsNothing);
      g.failure = null;
      g.malformed = true;
      await ask(t);
      expect(find.byKey(const ValueKey('free-owner-answer')), findsNothing);
      expect(find.textContaining('unavailable right now'), findsOneWidget);
    },
  );
  testWidgets('free assistant drops in-flight answer on signout', (t) async {
    final g = FakeGateway()..pending = Completer();
    addTearDown(g.events.close);
    await t.pumpWidget(host(g));
    await select(t, 'Invoice totals');
    await t.tap(find.byKey(const ValueKey('free-owner-ask')));
    await t.pump();
    g.user = null;
    g.events.add(null);
    await t.pump();
    g.pending!.complete(answer('billing', '2026-11-01', '2026-11-15'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('free-owner-answer')), findsNothing);
    expect(find.text('Sign in as owner to view evidence.'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('free-owner-ask')))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'free assistant drops previous period response after host changes dates',
    (t) async {
      final g = FakeGateway()..pending = Completer();
      addTearDown(g.events.close);
      await t.pumpWidget(host(g));
      await select(t, 'Invoice totals');
      await t.tap(find.byKey(const ValueKey('free-owner-ask')));
      await t.pump();
      await t.pumpWidget(host(g, end: DateTime(2026, 11, 16)));
      g.pending!.complete(answer('billing', '2026-11-01', '2026-11-15'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('free-owner-answer')), findsNothing);
      g.pending = null;
      await ask(t);
      expect(g.calls.last['to'], '2026-11-16');
      expect(find.byKey(const ValueKey('free-owner-answer')), findsOneWidget);
    },
  );
  test('free assistant real gateway invokes only existing Edge function with exact bounded payload', () async {
    final paths = <String>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'fake-anon',
      accessToken: () async => 'fake-jwt',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        paths.add(r.url.path);
        expect(r.url.path, '/functions/v1/owner-evidence-advisor');
        expect(r.method, 'POST');
        expect(jsonDecode(r.body), {
          'action': 'ask',
          'question': 'billing',
          'language': 'en',
          'from': '2026-11-01',
          'to': '2026-11-15',
        });
        return http.Response(
          jsonEncode(answer('billing', '2026-11-01', '2026-11-15')),
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
    try {
      final data = await SupabaseFreeOwnerAssistantGateway(client).ask(
        topic: 'billing',
        language: 'en',
        from: '2026-11-01',
        to: '2026-11-15',
      );
      expect(data['paid_provider_allowed'], false);
      expect(paths.length, 1);
    } finally {
      await client.dispose();
    }
  });
}
