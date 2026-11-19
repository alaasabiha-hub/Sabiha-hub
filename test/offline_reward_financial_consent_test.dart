import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_reward_financial_consent.dart';

import 'visit_recovery_request_test.dart' as auth;

const financialProposal = '22222222-2222-4222-8222-222222222222';
const consentRequest = '33333333-3333-4333-8333-333333333333';
const withdrawal = '44444444-4444-4444-8444-444444444444';
const nextProposal = '55555555-5555-4555-8555-555555555555';
final fingerprint = List.filled(64, 'a').join();
Map<String, dynamic> proposalView({String state = 'proposal'}) => {
  'state': state,
  'proposal_id': financialProposal,
  'fingerprint': fingerprint,
  'terms': {
    'service': {'name_ar': 'الخدمة الفعلية', 'name_en': 'Actual service'},
    'branch': {'name_ar': 'الفرع الفعلي', 'name_en': 'Actual branch'},
    'unit': 'service_visits',
    'visits': 3,
    'gross_amount': 137.45,
    'reward_discount': 137.45,
    'amount_due': 0,
    'currency': 'EGP',
    'expires_at': '2026-11-16T09:30:00Z',
    'rules': {
      'pooling': 'policy_version',
      'expiry': 'snapshot_offer_end',
      'cancellation': 'restore_visits',
      'refunded_contribution': 'offset_future_visits',
    },
  },
  if (state != 'issued')
    'consent': {
      'version': 'offline-reward-financial-v1',
      'notice_ar': 'إشعار الخادم المالي الفعلي: ٣ زيارات؛ المستحق ٠ جنيه. انتهاء المقترح: 2026-11-16T09:30:00Z.',
      'notice_en': 'Actual server financial notice: 3 visits; charge 0 EGP. Proposal expiry: 2026-11-16T09:30:00Z.',
    },
  'issuer_enabled': false,
  'redemption_enabled': false,
  'reward_issued': state == 'issued',
};

class Store implements OfflineFinancialStore {
  OfflineFinancialReference? value;
  bool fail = false;
  final trace = <String>[];
  @override
  Future<OfflineFinancialReference?> read() async => value;
  @override
  Future<void> save(OfflineFinancialReference ref) async {
    trace.add('save');
    if (fail) throw StateError('Storage failed');
    if (value != null) {
      expect(ref.request, value!.request);
      expect(ref.proposal, value!.proposal);
    }
    value = ref;
  }
}

class Gateway implements OfflineFinancialGateway {
  Gateway(this.store);
  final Store store;
  @override
  String? actor = auth.actorId;
  Map<String, dynamic> currentView = proposalView();
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic>? sentConsent;
  String receiptState = 'consent_recorded';
  bool loseAccept = false, loseRevoke = false;
  Completer<Map<String, dynamic>>? pendingAccept;
  @override
  Future<Map<String, dynamic>> proposal(String? id) async {
    calls.add({'name': 'proposal', 'id': id});
    return currentView;
  }

  Map<String, dynamic> receiptValue(String id) {
    if (receiptState == 'absent' || receiptState == 'revoked') {
      return {
        'state': receiptState,
        'request_id': id,
        'issuer_enabled': false,
        'definitive_failure': receiptState == 'revoked',
      };
    }
    final issued = receiptState == 'issued';
    final view = issued ? proposalView(state: 'issued') : currentView;
    return {
      'state': receiptState,
      'request_id': id,
      'proposal_id': financialProposal,
      'fingerprint': fingerprint,
      'consent':
          sentConsent ??
          {
            'accepted': true,
            'version': 'offline-reward-financial-v1',
            'language': 'en',
            'text': (proposalView()['consent'] as Map)['notice_en'],
          },
      'proposal': view,
      'definitive_failure': false,
      'issuer_enabled': false,
      'redemption_enabled': false,
      'reward_issued': issued,
    };
  }

  @override
  Future<Map<String, dynamic>> accept(
    String id,
    String proposalId,
    String hash,
    Map<String, dynamic> consent,
  ) async {
    expect(store.value!.request, id);
    store.trace.add('accept');
    sentConsent = Map.of(consent);
    calls.add({
      'name': 'accept',
      'request': id,
      'proposal': proposalId,
      'fingerprint': hash,
      'consent': Map.of(consent),
    });
    if (pendingAccept != null) return await pendingAccept!.future;
    if (loseAccept) throw TimeoutException('Lost response');
    return receiptValue(id);
  }

  @override
  Future<Map<String, dynamic>> receipt(String id) async {
    calls.add({'name': 'receipt', 'request': id});
    return receiptValue(id);
  }

  @override
  Future<Map<String, dynamic>> revoke(String id, String target) async {
    expect(store.value!.withdrawal, id);
    calls.add({'name': 'revoke', 'request': id, 'target': target});
    if (loseRevoke) {
      loseRevoke = false;
      throw TimeoutException('Lost withdrawal');
    }
    if (receiptState == 'issued') {
      return {
        'state': 'already_issued',
        'request_id': target,
        'revoke_request_id': id,
        'withdrawal_applied': false,
        'reward_issued': true,
        'issuer_enabled': false,
      };
    }
    receiptState = 'revoked';
    return receiptValue(target);
  }
}

OfflineFinancialConsentController controller(
  Gateway api,
  Store store, {
  Duration timeout = const Duration(seconds: 30),
}) => OfflineFinancialConsentController(
  gateway: api,
  store: store,
  timeout: timeout,
);
Future<void> press(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final found = find.byKey(ValueKey(key));
  await tester.ensureVisible(found);
  await tester.tap(found);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> showPanel(
  WidgetTester tester,
  auth.TestClient client,
  Gateway api,
  Store store, {
  String language = 'en',
  double width = 1440,
  String? proposalId,
  Object? scopeKey,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OfflineRewardFinancialConsentPanel(
            client: client,
            proposalId: proposalId,
            scopeKey: scopeKey,
            gateway: api,
            store: store,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('gateway sends only four own-session public RPC shapes and stops before request after actor change', () async {
    final paths = <String>[], payloads = <Map<String, dynamic>>[];
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'fake-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        paths.add(r.url.path.split('/').last);
        payloads.add(Map.from(jsonDecode(r.body) as Map));
        expect(r.headers['apikey'], 'fake-anon');
        expect(
          r.headers['Authorization'] ?? r.headers['authorization'],
          'Bearer widget-gateway-session',
        );
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
    Future<void> session(String actor) => client.auth.setInitialSession(
      jsonEncode(
        Session(
          accessToken: 'widget-gateway-session',
          tokenType: 'bearer',
          user: User(
            id: actor,
            appMetadata: const {},
            userMetadata: const {},
            aud: 'authenticated',
            createdAt: '2026-11-15T00:00:00Z',
          ),
        ).toJson(),
      ),
    );
    try {
      await session(auth.actorId);
      final gateway = SupabaseOfflineFinancialGateway(client);
      await gateway.proposal(null);
      await gateway.accept(consentRequest, financialProposal, fingerprint, {
        'accepted': true,
      });
      await gateway.receipt(consentRequest);
      await gateway.revoke(withdrawal, consentRequest);
      expect(paths, [
        'get_my_offline_reward_financial_proposal',
        'accept_my_offline_reward_financial_consent',
        'get_my_offline_reward_financial_consent',
        'revoke_my_offline_reward_financial_consent',
      ]);
      expect(payloads, [
        {'p_proposal': null},
        {
          'p_request': consentRequest,
          'p_proposal': financialProposal,
          'p_fingerprint': fingerprint,
          'p_consent': {'accepted': true},
        },
        {'p_request': consentRequest},
        {'p_request': withdrawal, 'p_consent_request': consentRequest},
      ]);
      await session('99999999-9999-4999-8999-999999999999');
      await expectLater(gateway.proposal(financialProposal), throwsStateError);
      expect(paths, hasLength(4));
    } finally {
      await client.dispose();
    }
  });

  test('actor store persists only UUIDs, appends same withdrawal nonce and refuses replacing pending request', () async {
    SharedPreferences.setMockInitialValues({});
    final client = auth.TestClient(auth.TestAuth());
    try {
      final store = SharedOfflineFinancialStore(client);
      await store.save(
        const OfflineFinancialReference(consentRequest, financialProposal),
      );
      await store.save(
        const OfflineFinancialReference(
          consentRequest,
          financialProposal,
          withdrawal,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(
        'offline_reward_financial_consent_uuid/${auth.actorId}',
      );
      expect(jsonDecode(raw!), [consentRequest, financialProposal, withdrawal]);
      expect(prefs.getKeys(), {
        'offline_reward_financial_consent_uuid/${auth.actorId}',
      });
      await expectLater(
        store.save(
          const OfflineFinancialReference(withdrawal, financialProposal),
        ),
        throwsStateError,
      );
      await expectLater(
        store.save(
          const OfflineFinancialReference(consentRequest, nextProposal),
        ),
        throwsStateError,
      );
      await expectLater(
        store.save(
          const OfflineFinancialReference(
            consentRequest,
            financialProposal,
            nextProposal,
          ),
        ),
        throwsStateError,
      );
      client.testAuth.user = null;
      await expectLater(store.read(), throwsStateError);
    } finally {
      await client.dispose();
      await client.testAuth.events.close();
      client.testAuth.dispose();
    }
  });

  test('failed local save prevents financial mutation; exact in-memory retry keeps UUID and original server notice', () async {
    final store = Store()..fail = true;
    final gateway = Gateway(store), c = controller(gateway, store);
    addTearDown(c.dispose);
    await c.refresh();
    final scope = c.consentScope;
    await c.consent('ar', accepted: true, scope: scope);
    expect(gateway.calls.where((c) => c['name'] == 'accept'), isEmpty);
    final saved = c.reference!;
    expect(c.canRetry, true);
    store.fail = false;
    await c.retry();
    expect(store.value!.ids, saved.ids);
    expect(c.phase, 'consent_recorded');
    expect(store.trace, ['save', 'save', 'accept']);
    expect(gateway.sentConsent, {
      'accepted': true,
      'version': 'offline-reward-financial-v1',
      'language': 'ar',
      'text': (proposalView()['consent'] as Map)['notice_ar'],
    });
  });

  test('restart absent cannot accept or rotate; explicit withdrawal unknown nonce fences and retries exact command', () async {
    final store = Store();
    final gateway = Gateway(store)..loseAccept = true;
    final first = controller(gateway, store);
    addTearDown(first.dispose);
    await first.refresh();
    await first.consent('en', accepted: true, scope: first.consentScope);
    final saved = store.value!;
    gateway.receiptState = 'absent';
    final restart = controller(gateway, store);
    addTearDown(restart.dispose);
    await restart.refresh();
    expect(restart.phase, 'uncertain');
    expect(restart.canConsent, false);
    expect(restart.canRetry, false);
    gateway.loseRevoke = true;
    await restart.withdraw();
    final target = store.value!;
    expect(target.request, saved.request);
    expect(target.proposal, saved.proposal);
    expect(target.withdrawal, isNotNull);
    await restart.withdraw();
    final withdrawals = gateway.calls
        .where((c) => c['name'] == 'revoke')
        .toList();
    expect(withdrawals, hasLength(2));
    expect(withdrawals[0], withdrawals[1]);
    expect(restart.phase, 'revoked');
    expect(restart.canConsent, false);
    expect(restart.canWithdraw, false);
    expect(gateway.calls.where((c) => c['name'] == 'accept'), hasLength(1));
    expect(store.value!.ids, target.ids);
  });

  test('bounded timeout releases busy and late actor-invalidated result cannot restore financial view or erase nonce', () async {
    final store = Store();
    final api = Gateway(store)
      ..pendingAccept = Completer<Map<String, dynamic>>();
    final c = controller(api, store, timeout: const Duration(milliseconds: 1));
    addTearDown(c.dispose);
    await c.refresh();
    await c.consent('en', accepted: true, scope: c.consentScope);
    expect(c.busy, false);
    expect(c.phase, 'uncertain');
    final saved = store.value!;
    api.actor = null;
    c.invalidate();
    api.pendingAccept!.complete(api.receiptValue(saved.request));
    await Future<void>.delayed(Duration.zero);
    expect(c.view, isNull);
    expect(c.invalid, true);
    expect(store.value!.ids, saved.ids);
  });

  test('unknown currency, nonzero charge, unit/rules/fingerprint drift fail closed and old checkbox scope cannot authorize fresh terms', () async {
    for (final invalid in [
      'currency',
      'charge',
      'unit',
      'rules',
      'fingerprint',
    ]) {
      final store = Store();
      final gateway = Gateway(store);
      final data = proposalView();
      final terms = data['terms'] as Map;
      switch (invalid) {
        case 'currency':
          terms['currency'] = 'USD';
        case 'charge':
          terms['amount_due'] = 1;
        case 'unit':
          terms['unit'] = 'points';
        case 'rules':
          (terms['rules'] as Map)['expiry'] = 'invented';
        case 'fingerprint':
          data['fingerprint'] = 'unverified';
      }
      gateway.currentView = data;
      final c = controller(gateway, store);
      await c.refresh();
      expect(c.view, isNull);
      expect(c.canConsent, false);
      expect(c.error, 'unconfirmed');
      c.dispose();
    }
    final store = Store();
    final gateway = Gateway(store);
    final actual = controller(gateway, store);
    addTearDown(actual.dispose);
    await actual.refresh();
    final old = actual.consentScope;
    gateway.currentView = proposalView()
      ..['fingerprint'] = List.filled(64, 'b').join();
    await actual.refresh();
    await actual.consent('en', accepted: true, scope: old);
    expect(gateway.calls.where((c) => c['name'] == 'accept'), isEmpty);
    expect(store.value, isNull);
  });

  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'financial consent ${config.$1} ${config.$2} displays actual frozen visits/prices/rules and separately checked exact notice',
      (tester) async {
        final client = await auth.client(tester), store = Store();
        final api = Gateway(store), ar = config.$1 == 'ar';
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await showPanel(
          tester,
          client,
          api,
          store,
          language: config.$1,
          width: config.$2,
        );
        expect(
          find.text(ar ? 'الخدمة: الخدمة الفعلية' : 'Service: Actual service'),
          findsOneWidget,
        );
        expect(
          find.text(ar ? 'الفرع: الفرع الفعلي' : 'Branch: Actual branch'),
          findsOneWidget,
        );
        expect(
          find.textContaining(ar ? 'الزيارات المستخدمة' : 'Visits used'),
          findsOneWidget,
        );
        expect(
          find.textContaining(ar ? '١٣٧٫٤٥ جنيه مصري' : 'EGP 137.45'),
          findsNWidgets(2),
        );
        expect(
          find.text(
            ar
                ? 'المستحق النهائي: ٠٫٠٠ جنيه مصري'
                : 'Final customer charge: EGP 0.00',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            (proposalView()['consent'] as Map)[ar ? 'notice_ar' : 'notice_en']
                as String,
          ),
          findsOneWidget,
        );
        expect(find.textContaining('policy_version'), findsNothing);
        expect(find.textContaining('snapshot_offer_end'), findsNothing);
        expect(
          find.textContaining(ar ? 'واجهة تحضيرية' : 'Preparatory interface'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('offline-financial-checkbox')),
              )
              .value,
          false,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('offline-financial-record')),
              )
              .onPressed,
          isNull,
        );
        await press(tester, 'offline-financial-checkbox');
        await press(tester, 'offline-financial-record');
        expect(api.sentConsent!['language'], config.$1);
        expect(
          api.sentConsent!['text'],
          (proposalView()['consent'] as Map)[ar ? 'notice_ar' : 'notice_en'],
        );
        expect(
          find.byKey(const ValueKey('offline-financial-record')),
          findsNothing,
        );
        expect(
          find.textContaining(
            ar ? 'سُجلت الموافقة المالية' : 'Financial consent recorded',
          ),
          findsOneWidget,
        );
        await press(tester, 'offline-financial-withdraw');
        expect(
          find.textContaining(ar ? 'سُحبت الموافقة' : 'Consent was withdrawn'),
          findsOneWidget,
        );
        expect(api.calls.map((c) => c['name']).toSet(), {
          'proposal',
          'accept',
          'revoke',
        });
        expect(store.value!.withdrawal, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real Auth event clears exact notice and late financial receipt; original UUID tuple remains for own recovery',
    (tester) async {
      final client = await auth.client(tester), store = Store();
      final api = Gateway(store)
        ..pendingAccept = Completer<Map<String, dynamic>>();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(tester, client, api, store);
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      );
      await tester.pump();
      await press(tester, 'offline-financial-checkbox');
      await press(tester, 'offline-financial-record', settle: false);
      final saved = store.value!;
      client.testAuth.user = null;
      api.actor = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await tester.pump();
      api.pendingAccept!.complete(api.receiptValue(saved.request));
      await tester.pumpAndSettle();
      expect(find.text('Service: Actual service'), findsNothing);
      expect(
        find.byKey(const ValueKey('offline-financial-exact-notice')),
        findsNothing,
      );
      expect(
        find.text(
          'The session or proposal scope changed. Reopen with the correct account.',
        ),
        findsOneWidget,
      );
      expect(store.value!.ids, saved.ids);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed host scope or proposal clears accepted checkbox and private view without auto-adopting new proposal',
    (tester) async {
      final client = await auth.client(tester), store = Store();
      final api = Gateway(store);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(
        tester,
        client,
        api,
        store,
        proposalId: financialProposal,
        scopeKey: 'case-a',
      );
      await press(tester, 'offline-financial-checkbox');
      await showPanel(
        tester,
        client,
        api,
        store,
        proposalId: nextProposal,
        scopeKey: 'case-b',
      );
      expect(
        find.byKey(const ValueKey('offline-financial-checkbox')),
        findsNothing,
      );
      expect(find.text('Service: Actual service'), findsNothing);
      expect(api.calls, hasLength(1));
      expect(store.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SOURCE31335 forward display only: issued and already-issued withdrawal never claim refund/cancel/reusable consent',
    (tester) async {
      final client = await auth.client(tester),
          store = Store()
            ..value = const OfflineFinancialReference(
              consentRequest,
              financialProposal,
            );
      final api = Gateway(store)..receiptState = 'issued';
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(tester, client, api, store);
      expect(
        find.text(
          'The server receipt reports a reward was issued. This does not authorize reissue or restore the consent.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('offline-financial-record')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('offline-financial-checkbox')),
        findsNothing,
      );
      await press(tester, 'offline-financial-withdraw');
      expect(
        find.text(
          'Withdrawal was not applied because the reward was already issued. The issued invoice is unchanged; this action does not cancel, refund or reissue it.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Consent was withdrawn'), findsNothing);
      expect(store.value!.request, consentRequest);
      expect(store.value!.withdrawal, isNotNull);
      expect(api.calls.where((c) => c['name'] == 'accept'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
