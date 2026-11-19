import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/offline_customer_registration.dart';

import 'offline_customer_registration_test.dart' as fixture;

const request = '11111111-1111-4111-8111-111111111111';
const branch = 'branch-one';
const receiptReference = '22222222-2222-4222-8222-222222222222';

class CloseGateway extends fixture.FakeRegistrationGateway {
  final closes = <List<String>>[];
  Map<String, dynamic>? closeReply;
  bool loseClose = false;
  Map<String, dynamic> closed(String id) => {
    'state': 'closed',
    'request_id': id,
    'branch_id': branch,
    'registration_created': false,
    'may_retry_same_request': false,
    'definitive_failure': true,
    'enrollment_secret': null,
  };
  @override
  Future<Map<String, dynamic>> close(String id, String branchId) async {
    closes.add([id, branchId]);
    if (loseClose) {
      loseClose = false;
      throw Exception('Lost close response');
    }
    return closeReply ?? closed(id);
  }

  Map<String, dynamic> succeeded() => {
    'state': 'succeeded',
    'request_id': request,
    'branch_id': branch,
    'result': {
      ...result(request),
      'enrollment_receipt_id': receiptReference,
      // The controller must discard even a protocol-violating returned secret.
      'enrollment_secret': 'MUST-NOT-BE-SHOWN',
    },
  };
}

Future<OfflineRegistrationController> reopened(
  CloseGateway api,
  fixture.MemoryRegistrationStore store,
) async {
  final controller = OfflineRegistrationController(
    gateway: api,
    store: store,
    branchId: branch,
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

void main() {
  test('close first retains UUID until explicit acknowledgement', () async {
    final api = CloseGateway();
    final store = fixture.MemoryRegistrationStore()..value = request;
    final c = await reopened(api, store);
    expect(c.locked, isTrue);
    expect(c.canRetry, isFalse);
    expect(c.canClose, isTrue);
    expect(api.closes, isEmpty);
    await c.close();
    expect(api.closes, [
      [request, branch],
    ]);
    expect(c.receipt?['status'], 'closed');
    expect(c.resolved, isTrue);
    expect(c.locked, isTrue);
    expect(c.canRetry, isFalse);
    expect(store.value, request);
    expect(store.clears, 0);
    await c.acknowledge();
    expect(c.locked, isFalse);
    expect(store.value, isNull);
  });

  test(
    'creation wins returns actual receipt without recovering a secret',
    () async {
      final api = CloseGateway();
      api.closeReply = api.succeeded();
      final store = fixture.MemoryRegistrationStore()..value = request;
      final c = await reopened(api, store);
      await c.close();
      expect(c.receipt?['status'], 'created_unverified');
      expect(c.receipt?['enrollment_receipt_id'], receiptReference);
      expect(c.receipt!.containsKey('enrollment_secret'), isFalse);
      expect(c.enrollmentSecret, isNull);
      expect(c.secretWasLost, isTrue);
      expect(c.locked, isTrue);
      expect(store.value, request);
      expect(api.calls, isEmpty);
    },
  );

  test(
    'lost close response stays locked and retries the same nonce and branch',
    () async {
      final api = CloseGateway()..loseClose = true;
      final store = fixture.MemoryRegistrationStore()..value = request;
      final c = await reopened(api, store);
      await c.close();
      expect(c.errorCode, 'unconfirmed');
      expect(c.resolved, isFalse);
      expect(c.locked, isTrue);
      expect(store.value, request);
      expect(store.clears, 0);
      await c.close();
      expect(api.closes, [
        [request, branch],
        [request, branch],
      ]);
      expect(c.receipt?['status'], 'closed');
      expect(store.value, request);
    },
  );

  test(
    'unknown close preserves exact in-memory retry and UUID-only storage',
    () async {
      final api = CloseGateway()..failOnce = true;
      final store = fixture.MemoryRegistrationStore();
      final c = await reopened(api, store);
      await c.submit({'p_branch': branch, 'p_name': 'Private QA field'});
      final exact = Map<String, dynamic>.from(api.calls.single);
      final id = c.requestId;
      api.closeReply = {
        'state': 'absent',
        'request_id': id,
        'branch_id': branch,
      };
      await c.close();
      expect(c.errorCode, 'unconfirmed');
      expect(c.canRetry, isTrue);
      expect(c.locked, isTrue);
      expect(store.writes, [id]);
      expect(store.clears, 0);
      await c.retry();
      expect(api.calls, [exact, exact]);
    },
  );

  test(
    'wrong close state, scope, flags and nested receipt never unlock',
    () async {
      final replies = <Map<String, dynamic>>[
        {'state': 'absent', 'request_id': request, 'branch_id': branch},
        {'state': 'unknown', 'request_id': request, 'branch_id': branch},
        {...CloseGateway().closed(request), 'request_id': 'other-request'},
        {...CloseGateway().closed(request), 'branch_id': 'other-branch'},
        {...CloseGateway().closed(request), 'definitive_failure': false},
        {
          ...CloseGateway().succeeded(),
          'result': {'request_id': request, 'status': 'absent'},
        },
        {
          ...CloseGateway().succeeded(),
          'result': {
            'request_id': 'other-request',
            'status': 'created_unverified',
          },
        },
      ];
      for (final reply in replies) {
        final api = CloseGateway()..closeReply = reply;
        final store = fixture.MemoryRegistrationStore()..value = request;
        final c = await reopened(api, store);
        await c.close();
        expect(c.locked, isTrue, reason: '$reply');
        expect(c.resolved, isFalse, reason: '$reply');
        expect(c.errorCode, 'unconfirmed');
        expect(store.value, request);
        expect(store.clears, 0);
      }
    },
  );

  test('recovered closed result validates branch and remains acknowledgement gated', () async {
    final api = CloseGateway();
    api.recovered = {...api.closed(request), 'status': 'closed'};
    final store = fixture.MemoryRegistrationStore()..value = request;
    final c = await reopened(api, store);
    expect(c.resolved, isTrue);
    expect(c.receipt?['status'], 'closed');
    expect(c.locked, isTrue);
    expect(api.closes, isEmpty);
    final bad = CloseGateway()
      ..recovered = {
        ...api.closed(request),
        'status': 'closed',
        'branch_id': 'other',
      };
    final denied = await reopened(
      bad,
      fixture.MemoryRegistrationStore()..value = request,
    );
    expect(denied.resolved, isFalse);
    expect(denied.locked, isTrue);
  });

  testWidgets(
    'AR390 explicit safe close confirms unused request before a new form',
    (tester) async {
      final api = CloseGateway();
      final store = fixture.MemoryRegistrationStore()..value = request;
      await fixture.mount(tester, api, store, arabic: true, width: 390);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('customer_name')))
            .enabled,
        isFalse,
      );
      await fixture.press(tester, 'close_registration');
      await tester.tap(find.text('متابعة الفحص'));
      await tester.pumpAndSettle();
      expect(api.closes, isEmpty);
      await fixture.press(tester, 'close_registration');
      await tester.tap(
        find.byKey(const ValueKey('confirm_registration_close')),
      );
      await tester.pumpAndSettle();
      expect(find.text('أُغلق طلب التسجيل غير المستخدم بأمان'), findsOneWidget);
      expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
      expect(store.value, request);
      await fixture.press(tester, 'registration_done');
      expect(store.value, isNull);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('customer_name')))
            .enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'EN1440 creation-won close displays actual customer receipt ID separately',
    (tester) async {
      final api = CloseGateway();
      api.closeReply = api.succeeded();
      final store = fixture.MemoryRegistrationStore()..value = request;
      await fixture.mount(tester, api, store);
      await fixture.press(tester, 'close_registration');
      await tester.tap(
        find.byKey(const ValueKey('confirm_registration_close')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Customer record saved · unverified'), findsOneWidget);
      expect(find.text('Customer receipt reference'), findsOneWidget);
      expect(find.text('Staff recovery reference'), findsOneWidget);
      final actual = tester.widget<SelectableText>(
        find.byKey(const ValueKey('enrollment_receipt_reference')),
      );
      expect(actual.data, receiptReference);
      expect(actual.data, isNot(request));
      expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
      expect(
        find.textContaining('original receipt code cannot be displayed again'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('registration_done')),
            )
            .onPressed,
        isNull,
      );
      await fixture.press(tester, 'receipt_acknowledged');
      await fixture.press(tester, 'registration_done');
      expect(store.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
