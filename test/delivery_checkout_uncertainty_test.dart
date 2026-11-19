import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabiha_hub/delivery_support.dart';

void main() {
  test('timeout retry freezes original identity and deep payload', () {
    final attempt = FulfillmentCheckoutAttempt();
    final items = [
      {'item_id': 'product', 'quantity': 1},
    ];
    final original = attempt.capture({
      'p_request_id': 'original',
      'p_items': items,
      'p_expected_total': 12,
    });
    items.first['quantity'] = 4;
    expect(attempt.rejected(TimeoutException('response lost')), isFalse);
    expect(attempt.unresolved, isTrue);
    final retry = attempt.capture({
      'p_request_id': 'replacement',
      'p_items': items,
      'p_expected_total': 99,
    });
    expect(retry, equals(original));
    (retry['p_items'] as List).clear();
    expect((attempt.capture({})['p_items'] as List).length, 1);
  });
  test('HTTP 500 or unknown API error preserves unresolved request', () {
    final attempt = FulfillmentCheckoutAttempt();
    attempt.capture({'p_request_id': 'same'});
    expect(
      attempt.rejected(
        const PostgrestException(message: 'Server error', code: '500'),
      ),
      isFalse,
    );
    expect(attempt.unresolved, isTrue);
  });
  test(
    'definitive SQL rejection releases editing for fresh reviewed attempt',
    () {
      for (final code in ['40001', '22023', '42501', 'P0001']) {
        final attempt = FulfillmentCheckoutAttempt();
        attempt.capture({'p_request_id': 'old'});
        expect(
          attempt.rejected(PostgrestException(message: 'Rejected', code: code)),
          isTrue,
        );
        expect(attempt.unresolved, isFalse);
        expect(attempt.capture({'p_request_id': 'new'})['p_request_id'], 'new');
      }
    },
  );
  test('successful result resolves identity', () {
    final attempt = FulfillmentCheckoutAttempt();
    attempt.capture({'p_request_id': 'old'});
    attempt.succeeded();
    expect(attempt.unresolved, isFalse);
  });
  test('UUID is persisted before preparing private server draft', () async {
    String? stored;
    final events = <String>[];
    final recovery = DurableCheckoutRecovery(
      read: () async => stored,
      write: (id) async {
        events.add('write');
        stored = id;
      },
      clear: () async {
        stored = null;
      },
      rpc: (name, p) async {
        events.add(name);
        expect(stored, 'uuid-only');
        return {'state': 'open', 'request_id': stored};
      },
    );
    await recovery.prepare({
      'p_request_id': 'uuid-only',
      'p_address': 'private server address',
    });
    expect(events, ['write', 'prepare_checkout_retry']);
    expect(stored, 'uuid-only');
  });
  test('restart restores exact server draft using local UUID only', () async {
    String? stored = 'same-id';
    final payload = {
      'p_request_id': 'same-id',
      'p_items': [
        {'item_id': 'product', 'quantity': 2},
      ],
      'p_address': 'server only',
    };
    final recovery = DurableCheckoutRecovery(
      read: () async => stored,
      write: (id) async {
        stored = id;
      },
      clear: () async {
        stored = null;
      },
      rpc: (name, p) async {
        expect(name, 'get_checkout_retry');
        expect(p, {'p_request': 'same-id'});
        return {'state': 'open', 'request_id': 'same-id', 'payload': payload};
      },
    );
    expect((await recovery.recover())['payload'], payload);
    expect(stored, 'same-id');
  });
  test(
    'committed recovery retains UUID until displayed order is acknowledged',
    () async {
      String? stored = 'same-id';
      final recovery = DurableCheckoutRecovery(
        read: () async => stored,
        write: (id) async {
          stored = id;
        },
        clear: () async {
          stored = null;
        },
        rpc: (name, p) async => {
          'state': 'succeeded',
          'request_id': 'same-id',
          'acknowledged': name == 'acknowledge_checkout_retry',
          'order': {'order_id': 'saved'},
        },
      );
      final result = await recovery.recover();
      expect(result['order'], {'order_id': 'saved'});
      expect(stored, 'same-id');
      await recovery.acknowledge('same-id');
      expect(stored, isNull);
    },
  );
  test(
    'lost recovery response retains UUID; absent preparation safely clears',
    () async {
      String? stored = 'same-id';
      bool fail = true;
      final recovery = DurableCheckoutRecovery(
        read: () async => stored,
        write: (id) async {
          stored = id;
        },
        clear: () async {
          stored = null;
        },
        rpc: (name, p) async {
          if (fail) throw TimeoutException('lost');
          return {'state': 'absent'};
        },
      );
      await expectLater(recovery.recover(), throwsA(isA<TimeoutException>()));
      expect(stored, 'same-id');
      fail = false;
      expect((await recovery.recover())['state'], 'absent');
      expect(stored, isNull);
    },
  );
  test(
    'new device without local UUID restores own open server draft',
    () async {
      String? stored;
      final calls = <Map<String, dynamic>>[];
      final recovery = DurableCheckoutRecovery(
        read: () async => stored,
        write: (id) async {
          stored = id;
        },
        clear: () async {
          stored = null;
        },
        rpc: (name, p) async {
          calls.add(p);
          return {
            'state': 'open',
            'request_id': 'server-id',
            'payload': {'p_zone': 'inactive-zone'},
          };
        },
      );
      final saved = await recovery.recover();
      expect(calls, [
        {'p_request': null},
      ]);
      expect(stored, 'server-id');
      expect((saved['payload'] as Map)['p_zone'], 'inactive-zone');
    },
  );
  testWidgets(
    'restored removed delivery zone renders exact retry without dropdown lookup',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final calls = <String>[];
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://local.example.test',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            calls.add(request.url.path);
            dynamic result;
            if (request.url.path.contains('/auth/')) {
              result = {
                'access_token':
                    '${base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'}))).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode({'sub': '00000000-0000-0000-0000-000000000001', 'role': 'authenticated', 'aud': 'authenticated', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.signature',
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': '00000000-0000-0000-0000-000000000001',
                  'aud': 'authenticated',
                  'email': 'test@example.test',
                  'created_at': '2026-11-14T00:00:00Z',
                },
              };
            } else if (request.url.path.endsWith('get_checkout_retry')) {
              result = {
                'state': 'open',
                'request_id': '00000000-0000-4000-8000-000000000002',
                'branch_id': 'removed-branch',
                'payload': {
                  'p_request_id': '00000000-0000-4000-8000-000000000002',
                  'p_items': [
                    {'item_id': 'removed-product', 'quantity': 1},
                  ],
                  'p_method': 'delivery',
                  'p_zone': 'removed-zone',
                  'p_address': 'private saved address',
                  'p_phone': '+201000000001',
                  'p_note': '',
                  'p_coupon': '',
                  'p_expected_total': 24,
                },
              };
            } else {
              throw StateError('Unexpected stale catalog lookup');
            }
            return http.Response(
              jsonEncode(result),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        await client.auth.signInWithPassword(
          email: 'test@example.test',
          password: 'test-password',
        );
      });
      await tester.pumpWidget(
        MaterialApp(home: FulfillmentShopScreen(client: client)),
      );
      for (
        var i = 0;
        i < 20 && find.text('Retry same request').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pump();
      }
      expect(
        calls.where((p) => p.contains('/rest/')).toList(),
        ['/rest/v1/rpc/get_checkout_retry'],
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .join(' | '),
      );
      expect(find.text('Retry same request'), findsOneWidget);
      expect(find.textContaining('24 EGP'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(calls.where((p) => p.contains('/rest/')).toList(), [
        '/rest/v1/rpc/get_checkout_retry',
      ]);
      expect(tester.takeException(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        'checkout_retry_uuid_00000000-0000-0000-0000-000000000001',
      });
      expect(
        prefs.getString(prefs.getKeys().single),
        '00000000-0000-4000-8000-000000000002',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => client.dispose());
    },
  );
  test(
    'lost new-device success discovery remains recoverable without local UUID',
    () async {
      String? stored;
      bool lose = true;
      int reads = 0;
      final recovery = DurableCheckoutRecovery(
        read: () async => stored,
        write: (id) async {
          stored = id;
        },
        clear: () async {
          stored = null;
        },
        rpc: (name, p) async {
          reads++;
          if (lose) throw TimeoutException('lost discovery response');
          return {
            'state': 'succeeded',
            'request_id': 'saved-id',
            'order': {'order_id': 'existing', 'total': 24},
          };
        },
      );
      await expectLater(recovery.recover(), throwsA(isA<TimeoutException>()));
      expect(stored, isNull);
      lose = false;
      final saved = await recovery.recover();
      expect(saved['state'], 'succeeded');
      expect(stored, 'saved-id');
      expect(reads, 2);
    },
  );
  test('lost acknowledgment response preserves success UUID', () async {
    String? stored = 'saved-id';
    final recovery = DurableCheckoutRecovery(
      read: () async => stored,
      write: (id) async {
        stored = id;
      },
      clear: () async {
        stored = null;
      },
      rpc: (name, p) async => throw TimeoutException('ack response lost'),
    );
    await expectLater(
      recovery.acknowledge('saved-id'),
      throwsA(isA<TimeoutException>()),
    );
    expect(stored, 'saved-id');
  });
}
