import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_system_health.dart';

class HealthAuth extends GoTrueClient {
  HealthAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  String token = 'initial';
  final user = User(
    id: 'owner',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession =>
      Session(accessToken: token, tokenType: 'bearer', user: user);
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class HealthClient extends SupabaseClient {
  HealthClient(this.fake)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final HealthAuth fake;
  @override
  GoTrueClient get auth => fake;
}

class Gateway implements OwnerSystemHealthGateway {
  late Future<Map<String, dynamic>> Function(String?) handler;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> read(String? branch) {
    calls++;
    return handler(branch);
  }
}

Map<String, dynamic> data({
  String state = 'working',
  String reason = 'recent_execution_observed',
}) => {
  'checked_at': '2026-11-15T00:35:00Z',
  'database_probe': {
    'state': 'working',
    'source': 'authenticated_database_round_trip',
    'scope': 'this_request_only',
  },
  'background_worker': {
    'state': state,
    'reason': reason,
    'source': 'canonical_loyalty_cron_and_outbox',
    'scope': 'execution_observation_only',
    'checked_at': '2026-11-15T00:35:00Z',
    'last_success_at': '2026-11-15T00:34:00Z',
    'success_age_seconds': 60,
    'pending_events': 0,
    'due_events': 0,
    'retrying_events': 0,
    'pending_failed_attempts': 0,
    'unresolved_pending_events': 0,
  },
  'other_checks': {
    for (final key in [
      'booking_success',
      'invoice_success',
      'payments_and_integrations',
      'device_sync',
      'in_app_notifications',
      'pdf_generation',
      'backup_restore',
      'global_security',
      'financial_correctness',
    ])
      key: {'state': 'not_checked'},
  },
};
void main() {
  late HealthAuth auth;
  late HealthClient client;
  setUpAll(() {
    auth = HealthAuth();
    client = HealthClient(auth);
  });
  tearDownAll(() async {
    await client.dispose();
    await auth.events.close();
    auth.dispose();
  });
  Future<void> show(
    WidgetTester t,
    Gateway g, {
    String language = 'en',
    double width = 1440,
  }) async {
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerSystemHealthScreen(
          client: client,
          branchId: 'actual-branch',
          gateway: g,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  for (final scenario in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'actual source scope timestamp and independent checks ${scenario.$1}',
      (t) async {
        final g = Gateway()
          ..handler = (branch) async {
            expect(branch, 'actual-branch');
            return data();
          };
        await show(t, g, language: scenario.$1, width: scenario.$2);
        expect(find.textContaining('2026-11-15T00:35:00Z'), findsOneWidget);
        await t.scrollUntilVisible(
          find.textContaining(
            scenario.$1 == 'ar' ? 'رصد التنفيذ فقط' : 'Observed execution only',
          ),
          250,
        );
        expect(
          find.textContaining(
            scenario.$1 == 'ar' ? 'رصد التنفيذ فقط' : 'Observed execution only',
          ),
          findsOneWidget,
        );
        await t.scrollUntilVisible(
          find.textContaining(
            scenario.$1 == 'ar' ? 'الدقة المالية' : 'Financial correctness',
          ),
          300,
        );
        expect(
          find.textContaining(
            scenario.$1 == 'ar'
                ? 'الدقة المالية: لم يتم التحقق'
                : 'Financial correctness: Not checked',
          ),
          findsOneWidget,
        );
        expect(t.takeException(), null);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('empty queue with stale actual cron remains not checked', (
    t,
  ) async {
    final g = Gateway()
      ..handler = (_) async =>
          data(state: 'not_checked', reason: 'success_observation_stale');
    await show(t, g);
    expect(find.text('Not checked'), findsOneWidget);
    expect(
      find.textContaining('older than the verification window'),
      findsOneWidget,
    );
    expect(find.text('Execution observed'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'refresh clears prior evidence immediately and failed request never keeps green data',
    (t) async {
      final g = Gateway()..handler = (_) async => data();
      await show(t, g);
      expect(find.byKey(const ValueKey('worker_state')), findsOneWidget);
      final pending = Completer<Map<String, dynamic>>();
      g.handler = (_) => pending.future;
      await t.tap(find.byKey(const ValueKey('health_refresh')));
      await t.pump();
      expect(find.byKey(const ValueKey('worker_state')), findsNothing);
      pending.completeError(
        const PostgrestException(message: 'PRIVATE_SQL_ERROR', code: '42501'),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('health_error')), findsOneWidget);
      expect(find.textContaining('PRIVATE_SQL_ERROR'), findsNothing);
      expect(find.textContaining('2026-11-15T00:35:00Z'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'same mount signedIn replay accepted fresh token rejects pending late response',
    (t) async {
      final pending = Completer<Map<String, dynamic>>();
      final g = Gateway()..handler = (_) => pending.future;
      await t.pumpWidget(
        MaterialApp(
          home: OwnerSystemHealthScreen(client: client, gateway: g),
        ),
      );
      await t.pump();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pump();
      pending.complete(data());
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('worker_state')), findsOneWidget);
      final later = Completer<Map<String, dynamic>>();
      g.handler = (_) => later.future;
      await t.tap(find.byKey(const ValueKey('health_refresh')));
      await t.pump();
      auth.token = 'changed';
      auth.events.add(
        AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
      );
      await t.pump();
      later.complete(data());
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('worker_state')), findsNothing);
      expect(find.textContaining('Session changed'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('health_refresh')))
            .onPressed,
        isNull,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unknown source or unverifiable global green evidence fails closed',
    (t) async {
      final invalid = data();
      (invalid['other_checks'] as Map)['global_security'] = {
        'state': 'working',
      };
      final g = Gateway()..handler = (_) async => invalid;
      await show(t, g);
      expect(find.byKey(const ValueKey('health_error')), findsOneWidget);
      expect(find.byKey(const ValueKey('worker_state')), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
}
