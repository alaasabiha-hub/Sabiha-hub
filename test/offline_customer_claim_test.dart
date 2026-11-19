import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const receiptId = '11111111-1111-4111-8111-111111111111';
const claimId = '22222222-2222-4222-8222-222222222222';
const linkId = '33333333-3333-4333-8333-333333333333';
const proof =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class MemoryClaimStore implements OfflineClaimStore {
  String? value;
  final writes = <String>[];
  int clears = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async {
    value = id;
    writes.add(id);
  }

  @override
  Future<void> clear() async {
    value = null;
    clears++;
  }
}

class FakeClaimGateway implements OfflineClaimGateway {
  final calls = <Map<String, dynamic>>[];
  String customerStatus = 'pending_owner_review';
  bool failCustomer = false,
      denyOwner = false,
      failDecision = false,
      closeWon = true;
  Map<String, dynamic>? command;
  List<Map<String, dynamic>> rows = [
    {
      'claim_id': claimId,
      'name': 'Actual reception customer',
      'mode': 'original_receipt',
      'secret_proved': true,
      'confirmed_account_current': true,
      'contact_current': true,
      'status': 'pending_owner_review',
      'link_id': null,
    },
  ];
  Map<String, dynamic> envelope(String id, String state) => {
    'state': state,
    'request_id': id,
    'kind': null,
    'payload': null,
    'result': null,
  };
  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) async {
    final args = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(parameters)) as Map,
    );
    calls.add({'name': name, 'args': args});
    if (name == 'request_offline_customer_claim') {
      if (failCustomer) {
        failCustomer = false;
        throw Exception('Synthetic connection loss');
      }
      return {
        'request_id': args['p_request'],
        'status': customerStatus,
        'capabilities': {
          'history_visible': false,
          'wallet_access': false,
          'guest_redemption': false,
        },
      };
    }
    if (name == 'get_my_offline_customer_claim') {
      return {'request_id': args['p_request'], 'status': customerStatus};
    }
    if (name == 'list_offline_customer_claim_reviews') {
      if (denyOwner) {
        throw const PostgrestException(message: 'Denied', code: '42501');
      }
      return rows;
    }
    if (name == 'prepare_offline_claim_command') {
      command = {
        ...envelope(args['p_request'] as String, 'open'),
        'kind': args['p_kind'],
        'payload': args['p_payload'],
      };
      return command;
    }
    if (name == 'get_offline_customer_claim_command') {
      return command ?? envelope(args['p_request'] as String, 'absent');
    }
    if (name == 'decide_offline_customer_claim') {
      if (failDecision) {
        failDecision = false;
        throw Exception('Synthetic unknown response');
      }
      final result = {
        'claim_id': args['p_claim'],
        'decision': args['p_decision'],
        'link_id': linkId,
        'status': args['p_decision'] == 'hold' || args['p_decision'] == 'reject'
            ? args['p_decision']
            : 'approved_pending_reader_bridge',
      };
      command = {...command!, 'state': 'succeeded', 'result': result};
      return result;
    }
    if (name == 'revoke_offline_customer_link') {
      final result = {'link_id': args['p_link'], 'status': 'revoked'};
      command = {...command!, 'state': 'succeeded', 'result': result};
      return result;
    }
    if (name == 'close_offline_claim_command') {
      if (!closeWon) {
        return {
          ...envelope(args['p_request'] as String, 'succeeded'),
          'result': {'status': 'approved_pending_reader_bridge'},
        };
      }
      command = envelope(args['p_request'] as String, 'closed');
      return command;
    }
    throw StateError('Unexpected RPC name');
  }
}

SupabaseClient client() => SupabaseClient(
  'http://127.0.0.1:54321',
  'widget-test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);
Future<void> mount(
  WidgetTester tester,
  FakeClaimGateway api,
  MemoryClaimStore store, {
  bool owner = false,
  bool arabic = false,
  double width = 1440,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(arabic ? 'ar' : 'en'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: owner
          ? OwnerOfflineClaimReviewsScreen(
              client: client(),
              gateway: api,
              store: store,
            )
          : CustomerOfflineClaimScreen(
              client: client(),
              gateway: api,
              store: store,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String key) async {
  tester.testTextInput.hide();
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String key, String value) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.enterText(target, value);
}

Future<void> fillCustomer(WidgetTester tester, {bool consent = true}) async {
  await enter(tester, 'receipt_reference', receiptId);
  await enter(tester, 'receipt_secret', proof);
  if (consent) await press(tester, 'claim_consent');
}

void main() {
  testWidgets(
    'AR390 customer requires distinct receipt reference and fixed consent',
    (tester) async {
      final api = FakeClaimGateway(), store = MemoryClaimStore();
      await mount(tester, api, store, arabic: true, width: 390);
      await fillCustomer(tester, consent: false);
      await press(tester, 'submit_claim');
      expect(api.calls, isEmpty);
      expect(store.writes, isEmpty);
      expect(find.text(offlineClaimNoticeArabic), findsOneWidget);
      expect(find.textContaining('وليس مرجع طلب التسجيل'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'customer known review clears proof and persists only request UUID',
    (tester) async {
      final api = FakeClaimGateway(), store = MemoryClaimStore();
      await mount(tester, api, store);
      await fillCustomer(tester);
      await press(tester, 'submit_claim');
      expect(api.calls.single['args']['p_receipt'], receiptId);
      expect(api.calls.single['args']['p_consent'], {
        'accepted': true,
        'version': offlineClaimNoticeVersion,
        'text': offlineClaimNoticeEnglish,
        'language': 'en',
      });
      expect(store.writes.single, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(store.writes.single, isNot(proof));
      expect(find.byKey(const ValueKey('receipt_secret')), findsNothing);
      expect(find.byKey(const ValueKey('new_claim')), findsNothing);
      expect(find.textContaining('does not give access'), findsOneWidget);
      await press(tester, 'refresh_claim');
      expect(api.calls.last['name'], 'get_my_offline_customer_claim');
      expect(api.calls.last['args'].containsKey('p_secret'), isFalse);
    },
  );
  testWidgets(
    'customer unknown request freezes fields and retries same proof and nonce',
    (tester) async {
      final api = FakeClaimGateway()..failCustomer = true;
      final store = MemoryClaimStore();
      await mount(tester, api, store);
      await fillCustomer(tester);
      await press(tester, 'submit_claim');
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('receipt_reference')),
            )
            .enabled,
        isFalse,
      );
      await press(tester, 'retry_claim');
      expect(api.calls[0], api.calls[1]);
      expect(store.writes, hasLength(1));
      expect(find.byKey(const ValueKey('receipt_secret')), findsNothing);
    },
  );
  testWidgets(
    'reopened unavailable customer status never invents failure or another nonce',
    (tester) async {
      final api = FakeClaimGateway()..customerStatus = 'unavailable';
      final store = MemoryClaimStore()..value = claimId;
      await mount(tester, api, store, arabic: true, width: 390);
      expect(find.byKey(const ValueKey('retry_claim')), findsNothing);
      expect(find.byKey(const ValueKey('new_claim')), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('receipt_secret')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('submit_claim')))
            .onPressed,
        isNull,
      );
      await press(tester, 'refresh_claim');
      expect(store.clears, 0);
      expect(store.value, claimId);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'known generic failure allows only explicit acknowledgement before a fresh request',
    (tester) async {
      final api = FakeClaimGateway()..customerStatus = 'verification_failed';
      final store = MemoryClaimStore();
      await mount(tester, api, store);
      await fillCustomer(tester);
      await press(tester, 'submit_claim');
      expect(find.text('The evidence could not be confirmed'), findsOneWidget);
      expect(api.calls, hasLength(1));
      await press(tester, 'new_claim');
      expect(store.value, isNull);
      expect(api.calls, hasLength(1));
      expect(find.byKey(const ValueKey('receipt_secret')), findsOneWidget);
    },
  );
  testWidgets('owner access denial exposes no review records or actions', (
    tester,
  ) async {
    final api = FakeClaimGateway()..denyOwner = true;
    final store = MemoryClaimStore();
    await mount(tester, api, store, owner: true);
    expect(find.textContaining('active owner account'), findsOneWidget);
    expect(find.text('Actual reception customer'), findsNothing);
    expect(find.byKey(const ValueKey('approve_with_secret')), findsNothing);
    expect(store.writes, isEmpty);
  });
  testWidgets(
    'AR390 exception requires in-person evidence, reason and attestation',
    (tester) async {
      final api = FakeClaimGateway();
      api.rows.single['mode'] = 'lost_secret_review';
      api.rows.single['secret_proved'] = false;
      final store = MemoryClaimStore();
      await mount(tester, api, store, owner: true, arabic: true, width: 390);
      await press(tester, 'select_$claimId');
      await enter(
        tester,
        'owner_review_reason',
        'Actual original service documents checked in person',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve_exception')),
            )
            .onPressed,
        isNull,
      );
      await press(tester, 'continuity_evidence');
      await tester.tap(find.text('مستندات الخدمة الأصلية').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve_exception')),
            )
            .onPressed,
        isNull,
      );
      await press(tester, 'continuity_attestation');
      await press(tester, 'approve_exception');
      final prepared = api.calls.firstWhere(
        (call) => call['name'] == 'prepare_offline_claim_command',
      );
      expect(prepared['args']['p_kind'], 'decide');
      expect(
        prepared['args']['p_payload']['p_evidence_type'],
        'in_person_original_service_documents',
      );
      expect(prepared['args']['p_payload']['p_decision'], 'approve_exception');
      expect(store.writes, hasLength(1));
      expect(store.writes.single, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(
        find.textContaining('السجلات السابقة والمكافآت ما زالت غير متاحة'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('owner restart retries exact server payload without persisting review notes', () async {
    final api = FakeClaimGateway(), store = MemoryClaimStore()..value = claimId;
    final canonical = {
      'p_claim': receiptId,
      'p_decision': 'hold',
      'p_reason': 'Actual pending evidence review',
      'p_evidence_type': null,
    };
    api.command = {
      ...api.envelope(claimId, 'open'),
      'kind': 'decide',
      'payload': canonical,
    };
    final flow = OwnerOfflineClaimController(gateway: api, store: store);
    addTearDown(flow.dispose);
    await flow.initialize();
    await flow.retry();
    final sent = api.calls.singleWhere(
      (call) => call['name'] == 'decide_offline_customer_claim',
    );
    expect(sent['args'], {'p_request': claimId, ...canonical});
    expect(flow.succeeded, isTrue);
    expect(store.writes, isEmpty);
    await flow.acknowledge();
    expect(store.value, isNull);
  });
  test(
    'owner authoritative close handles both absent and business-won outcomes',
    () async {
      final api = FakeClaimGateway(),
          store = MemoryClaimStore()..value = claimId;
      final flow = OwnerOfflineClaimController(gateway: api, store: store);
      addTearDown(flow.dispose);
      await flow.initialize();
      expect(flow.state, 'absent');
      expect(flow.locked, isTrue);
      await flow.close();
      expect(flow.state, 'closed');
      expect(store.value, isNull);
      expect(
        api.calls.any(
          (call) => call['name'] == 'decide_offline_customer_claim',
        ),
        isFalse,
      );
      final wonApi = FakeClaimGateway()..closeWon = false;
      final wonStore = MemoryClaimStore()..value = claimId;
      final won = OwnerOfflineClaimController(gateway: wonApi, store: wonStore);
      addTearDown(won.dispose);
      await won.initialize();
      await won.close();
      expect(won.succeeded, isTrue);
      expect(wonStore.value, claimId);
      await won.acknowledge();
      expect(wonStore.value, isNull);
    },
  );
  testWidgets('owner revokes actual listed link through prepared nonce', (
    tester,
  ) async {
    final api = FakeClaimGateway();
    api.rows.single['status'] = 'approved_pending_reader_bridge';
    api.rows.single['link_id'] = linkId;
    final store = MemoryClaimStore();
    await mount(tester, api, store, owner: true);
    await press(tester, 'select_$claimId');
    await enter(
      tester,
      'owner_review_reason',
      'Actual owner continuity review revoked approval',
    );
    await press(tester, 'revoke_link');
    final prepared = api.calls.firstWhere(
      (call) => call['name'] == 'prepare_offline_claim_command',
    );
    final revoked = api.calls.singleWhere(
      (call) => call['name'] == 'revoke_offline_customer_link',
    );
    expect(prepared['args']['p_kind'], 'revoke');
    expect(prepared['args']['p_payload']['p_link'], linkId);
    expect(revoked['args']['p_request'], prepared['args']['p_request']);
    expect(
      find.textContaining('original receipt cannot be reused'),
      findsOneWidget,
    );
  });
}
