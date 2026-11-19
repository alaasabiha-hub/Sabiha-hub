import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/visit_recovery_request.dart';

const actorId = '11111111-1111-4111-8111-111111111111';
const otherId = '22222222-2222-4222-8222-222222222222';
const savedId = '33333333-3333-4333-8333-333333333333';
const caseId = '44444444-4444-4444-8444-444444444444';
Map<String, dynamic> notice() => {
  'state': 'unavailable',
  'case': null,
  'consent': {
    'version': 'visit-recovery-v1',
    'notice_ar': 'النطاق الفعلي من الخادم',
    'notice_en': 'Actual scope supplied by server',
  },
};
Map<String, dynamic> receipt() => {
  'state': 'available',
  'case': {
    'case_id': caseId,
    'status': 'awaiting_matching',
    'identity_current': true,
  },
  'status_label_ar': 'بانتظار مطابقة المعلومات',
  'status_label_en': 'Waiting for information matching',
  'receipt_message_ar': 'تم استلام طلبك بنجاح. طلبك قيد المراجعة، وفي انتظار مطابقة معلوماتك مع سجلات زياراتك السابقة',
  'receipt_message_en': 'Your request has been received successfully. It is under review and waiting for your information to be matched with previous visit records.',
  'notification_notice_ar':
      'سيصلك إشعار داخل التطبيق عند الانتهاء من مراجعة طلبك',
  'notification_notice_en': 'You will receive an in-app notification when your request review is complete.',
};
Map<String, dynamic> resolution(String id, String state) => {
  'state': state,
  'request_id': id,
  'payload': null,
  'result': null,
  'definitive_failure': state == 'closed',
};
Map<String, dynamic> accepted(String id) => {
  'state': 'accepted',
  'request_id': id,
  'definitive_failure': false,
  'payload': {
    'consent': {
      'accepted': true,
      'version': 'visit-recovery-v1',
      'language': 'en',
      'text': 'Actual scope supplied by server',
    },
  },
  'result': receipt(),
};

class Store implements VisitRecoveryStore {
  String? value;
  final writes = <String>[];
  int clears = 0;
  bool failWrite = false, failClear = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async {
    writes.add(id);
    if (failWrite) throw StateError('Storage unavailable');
    value = id;
  }

  @override
  Future<void> clear(String expectedRequest) async {
    if (failClear) throw StateError('Storage unavailable');
    if (value != null && value != expectedRequest) {
      throw StateError('Saved request differs');
    }
    clears++;
    value = null;
  }
}

class Gateway implements VisitRecoveryGateway {
  final submits = <Map<String, dynamic>>[],
      recoveries = <String>[],
      closes = <String>[];
  bool loseSubmit = false, loseClose = false, closeWins = true, deny = false;
  Map<String, dynamic>? recoveryOverride;
  Completer<Map<String, dynamic>>? pendingCurrent;
  @override
  Future<Map<String, dynamic>> current() async {
    if (deny) {
      throw const PostgrestException(
        message: 'Private detail must not display',
        code: '42501',
      );
    }
    return pendingCurrent == null ? notice() : pendingCurrent!.future;
  }

  @override
  Future<Map<String, dynamic>> submit(
    String id,
    Map<String, dynamic> consent,
  ) async {
    submits.add(
      jsonDecode(jsonEncode({'p_request': id, 'p_consent': consent}))
          as Map<String, dynamic>,
    );
    if (loseSubmit) {
      loseSubmit = false;
      throw StateError('Lost response');
    }
    return receipt();
  }

  @override
  Future<Map<String, dynamic>> recover(String id) async {
    recoveries.add(id);
    return recoveryOverride ?? resolution(id, 'absent');
  }

  @override
  Future<Map<String, dynamic>> close(String id) async {
    closes.add(id);
    if (loseClose) {
      loseClose = false;
      throw StateError('Lost close');
    }
    return closeWins ? resolution(id, 'closed') : accepted(id);
  }
}

class TestAuth extends GoTrueClient {
  TestAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  User? user = User(
    id: actorId,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession => user == null
      ? null
      : Session(
          accessToken: 'mock-session-only',
          tokenType: 'bearer',
          user: user!,
        );
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class TestClient extends SupabaseClient {
  TestClient(this.testAuth)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final TestAuth testAuth;
  @override
  GoTrueClient get auth => testAuth;
}

Future<TestClient> client(WidgetTester t) async {
  final result = (await t.runAsync(() async => TestClient(TestAuth())))!;
  addTearDown(() async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await t.runAsync(() async {
      await result.dispose();
      await result.testAuth.events.close();
      result.testAuth.dispose();
    });
  });
  return result;
}

Future<void> showPanel(
  WidgetTester t,
  TestClient c,
  Gateway api,
  Store store, {
  String language = 'en',
  double width = 1440,
}) async {
  t.view.physicalSize = Size(width, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: VisitRecoveryRequestPanel(
            client: c,
            gateway: api,
            store: store,
          ),
        ),
      ),
    ),
  );
  if (api.pendingCurrent != null && !api.pendingCurrent!.isCompleted) {
    await t.pump();
  } else {
    await t.pumpAndSettle();
  }
}

Future<void> press(WidgetTester t, String key) async {
  final target = find.byKey(ValueKey(key));
  await t.ensureVisible(target);
  await t.tap(target);
  await t.pumpAndSettle();
}

VisitRecoveryController controller(
  Gateway api,
  Store store, {
  String? Function()? actor,
}) => VisitRecoveryController(
  gateway: api,
  store: store,
  currentActor: actor ?? () => actorId,
);
void main() {
  for (final scenario in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'explicit server consent and exact receipt ${scenario.$1} ${scenario.$2}',
      (t) async {
        final c = await client(t), api = Gateway(), store = Store();
        await showPanel(
          t,
          c,
          api,
          store,
          language: scenario.$1,
          width: scenario.$2,
        );
        expect(
          t
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('recovery_consent')),
              )
              .value,
          isFalse,
        );
        expect(
          t
              .widget<FilledButton>(
                find.byKey(const ValueKey('recovery_submit')),
              )
              .onPressed,
          isNull,
        );
        await press(t, 'recovery_consent');
        await press(t, 'recovery_submit');
        expect(api.submits, hasLength(1));
        final body = api.submits.single;
        expect(body.keys, unorderedEquals(['p_request', 'p_consent']));
        expect(body['p_consent'], {
          'accepted': true,
          'version': 'visit-recovery-v1',
          'language': scenario.$1,
          'text': scenario.$1 == 'ar'
              ? 'النطاق الفعلي من الخادم'
              : 'Actual scope supplied by server',
        });
        expect(store.value, body['p_request']);
        expect(
          find.text(receipt()['receipt_message_${scenario.$1}'] as String),
          findsOneWidget,
        );
        expect(
          find.text(receipt()['notification_notice_${scenario.$1}'] as String),
          findsOneWidget,
        );
        await press(t, 'recovery_acknowledge');
        expect(store.value, isNull);
        expect(api.submits, hasLength(1));
        expect(t.takeException(), isNull);
      },
    );
  }
  test('storage failure and lost submit retain exact UUID and consent until receipt acknowledgement', () async {
    final api = Gateway()..loseSubmit = true,
        store = Store()..failWrite = true,
        c = controller(api, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.submit('en', accepted: true);
    final id = c.requestId;
    expect(id, isNotNull);
    expect(api.submits, isEmpty);
    store.failWrite = false;
    await c.retry();
    expect(c.phase, 'uncertain');
    await c.retry();
    expect(c.phase, 'accepted');
    expect(api.submits, hasLength(2));
    expect(api.submits.first, api.submits.last);
    expect(api.submits.first['p_request'], id);
    store.failClear = true;
    await c.acknowledge();
    expect(c.requestId, id);
    expect(c.phase, 'accepted');
    store.failClear = false;
    await c.acknowledge();
    expect(c.requestId, isNull);
    expect(store.value, isNull);
  });
  testWidgets(
    'restart absent stays frozen; lost close retries same nonce and explicit closed acknowledgement resets consent',
    (t) async {
      final c = await client(t),
          api = Gateway()..loseClose = true,
          store = Store()..value = savedId;
      await showPanel(t, c, api, store, width: 390, language: 'ar');
      expect(find.byKey(const ValueKey('recovery_submit')), findsNothing);
      expect(find.byKey(const ValueKey('recovery_retry')), findsNothing);
      await press(t, 'recovery_refresh');
      expect(api.recoveries, [savedId, savedId]);
      expect(store.value, savedId);
      await press(t, 'recovery_close');
      expect(store.value, savedId);
      await press(t, 'recovery_close');
      expect(api.closes, [savedId, savedId]);
      expect(find.byKey(const ValueKey('recovery_closed')), findsOneWidget);
      expect(store.clears, 0);
      await press(t, 'recovery_acknowledge');
      expect(store.value, isNull);
      expect(api.submits, isEmpty);
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('recovery_consent')),
            )
            .value,
        isFalse,
      );
      expect(t.takeException(), isNull);
    },
  );
  test('creation wins close and reopened accepted receipt remain truthful; wrong nonce never clears', () async {
    final store = Store()..value = savedId,
        api = Gateway()..closeWins = false,
        c = controller(api, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.close();
    expect(c.phase, 'accepted');
    expect(c.view?['case'], receipt()['case']);
    expect(store.value, savedId);
    await c.acknowledge();
    expect(store.value, isNull);
    expect(api.submits, isEmpty);
    final another = Store()..value = savedId,
        bad = Gateway()..recoveryOverride = accepted(otherId),
        d = controller(bad, another);
    addTearDown(d.dispose);
    await d.initialize();
    expect(d.phase, 'uncertain');
    expect(d.view, isNull);
    expect(another.clears, 0);
    expect(d.canSubmit, isFalse);
    bad.recoveryOverride = accepted(savedId);
    await d.refresh();
    expect(d.phase, 'accepted');
    expect(another.value, savedId);
  });
  testWidgets(
    'initial session replay is harmless; real signout clears and rejects late authenticated result',
    (t) async {
      final c = await client(t),
          api = Gateway()..pendingCurrent = Completer<Map<String, dynamic>>(),
          store = Store();
      await showPanel(t, c, api, store);
      c.testAuth.events.add(
        AuthState(AuthChangeEvent.signedIn, c.testAuth.currentSession),
      );
      await t.pump();
      api.pendingCurrent!.complete(notice());
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('recovery_consent')), findsOneWidget);
      api.pendingCurrent = Completer<Map<String, dynamic>>();
      await t.ensureVisible(find.byKey(const ValueKey('recovery_refresh')));
      await t.tap(find.byKey(const ValueKey('recovery_refresh')));
      await t.pump();
      c.testAuth.user = null;
      c.testAuth.events.add(const AuthState(AuthChangeEvent.signedOut, null));
      await t.pump();
      api.pendingCurrent!.complete(receipt());
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recovery_receipt_message')),
        findsNothing,
      );
      expect(api.submits, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'authorization denial and malformed closed receipt fail closed without raw errors',
    (t) async {
      final c = await client(t), api = Gateway()..deny = true, store = Store();
      await showPanel(t, c, api, store);
      expect(find.byKey(const ValueKey('recovery_submit')), findsNothing);
      expect(find.textContaining('Private detail'), findsNothing);
      final saved = Store()..value = savedId,
          bad = Gateway()
            ..recoveryOverride = {
              ...resolution(savedId, 'closed'),
              'definitive_failure': false,
            },
          flow = controller(bad, saved);
      addTearDown(flow.dispose);
      await flow.initialize();
      expect(flow.phase, 'uncertain');
      expect(flow.canAcknowledge, isFalse);
      expect(saved.clears, 0);
    },
  );
  testWidgets('shared storage contains only actor-scoped request UUID', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final c = await client(t), store = SharedVisitRecoveryStore(c);
    await store.write(savedId);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys(),
      unorderedEquals(['visit_recovery_submission_uuid_$actorId']),
    );
    expect(prefs.getString(prefs.getKeys().single), savedId);
    await expectLater(store.clear(otherId), throwsStateError);
    expect(await store.read(), savedId);
    c.testAuth.user = User(
      id: otherId,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: '2026-11-15',
    );
    await expectLater(store.read(), throwsStateError);
    expect(await SharedVisitRecoveryStore(c).read(), isNull);
  });
}
