import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sabiha_hub/invoices.dart' show InvoiceDocumentsScreen;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_walk_in.dart';

const savedId = '11111111-1111-4111-8111-111111111111';
const registrationId = '22222222-2222-4222-8222-222222222222';
final flags = {
  'work_start_supported': false,
  'walk_in_loyalty_accrual': false,
  'redemption_enabled': false,
};

class MemoryStore implements OfflineWalkInStore {
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

class Gateway implements OfflineWalkInGateway {
  final preparations = <Map<String, dynamic>>[],
      places = <String>[],
      closes = <String>[],
      acks = <String>[],
      recoveries = <String?>[];
  Map<String, dynamic>? current;
  bool losePrepare = false,
      losePlace = false,
      loseClose = false,
      ackConfirmed = true,
      employee = false;
  final requestedPriorities = <String>[];
  final priorityRequests = <String>[];
  Map<String, dynamic> contextResult() => {
    'registration_request_id': registrationId,
    'branch': {'id': 'branch', 'currency': 'EGP'},
    'subject': {
      'name': 'Actual QA reception',
      'plate_number': 'QA123',
      'identity_verified': false,
    },
    'bound_cashier': {'id': 'cashier', 'name': 'Actual cashier'},
    'can_prepare': !employee,
    'services': employee
        ? []
        : [
            {
              'id': 'service',
              'name': 'Actual QA service',
              'price': 137.45,
              'duration_minutes': 30,
            },
          ],
    'workers': employee
        ? []
        : [
            {'id': 'worker', 'name': 'Actual configured worker'},
          ],
    'capabilities': flags,
  };
  @override
  Future<Map<String, dynamic>> context(String registration) async =>
      contextResult();
  Map<String, dynamic> prepared(String id) => {
    'request_id': id,
    'status': 'prepared',
    'payload': {
      'registration_request_id': registrationId,
      'service_id': 'service',
      'expected_price': 137.45,
      'cashier_id': 'cashier',
      'staff_ids': ['worker'],
      'notes': null,
    },
    'result': null,
    'acknowledged': false,
    'capabilities': flags,
  };
  Map<String, dynamic> succeeded(String id) => {
    ...prepared(id),
    'status': 'succeeded',
    'executed_by': 'owner',
    'result': {
      'order_id': 'order',
      'invoice_id': 'invoice',
      'invoice_token': 'token',
      'invoice_number': 'SH-INV-000123',
      'work_reference': 'SH-INV-000123',
      'gross_amount': 137.45,
      'currency': 'EGP',
      'work_status': 'received',
      'invoice_status': 'active',
      'payment_status': 'unpaid',
      'collectible': true,
      'collectible_amount': 137.45,
    },
  };
  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> body) async {
    preparations.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(body)) as Map),
    );
    current = {
      ...prepared(body['p_request']),
      'payload': {
        'registration_request_id': body['p_registration'],
        'service_id': body['p_service'],
        'expected_price': body['p_expected_price'],
        'cashier_id': body['p_cashier'],
        'staff_ids': body['p_staff_ids'],
        'notes': body['p_notes'],
      },
    };
    if (losePrepare) {
      losePrepare = false;
      throw Exception('Lost preparation response');
    }
    return current!;
  }

  @override
  Future<Map<String, dynamic>> recover(String? id) async {
    recoveries.add(id);
    return current != null && (id == null || current!['request_id'] == id)
        ? current!
        : {
            'status': 'absent',
            'definitive_failure': false,
            'capabilities': flags,
          };
  }

  @override
  Future<Map<String, dynamic>> place(String id) async {
    places.add(id);
    current = succeeded(id);
    if (losePlace) {
      losePlace = false;
      throw Exception('Lost placement response');
    }
    return current!;
  }

  @override
  Future<Map<String, dynamic>> placeWithPriority(
    String id, {
    required String priority,
  }) async {
    requestedPriorities.add(priority);
    priorityRequests.add(id);
    return place(id);
  }

  @override
  Future<Map<String, dynamic>> close(String id) async {
    closes.add(id);
    if (current?['status'] != 'succeeded') {
      current = {
        'request_id': id,
        'status': 'closed',
        'payload': {},
        'result': {'status': 'closed'},
        'acknowledged': false,
        'capabilities': flags,
      };
    }
    if (loseClose) {
      loseClose = false;
      throw Exception('Lost close response');
    }
    return current!;
  }

  @override
  Future<Map<String, dynamic>> acknowledge(String id) async {
    acks.add(id);
    return {...current!, 'acknowledged': ackConfirmed};
  }
}

Future<OfflineWalkInController> controller(
  Gateway api,
  MemoryStore store,
) async {
  final c = OfflineWalkInController(gateway: api, store: store);
  addTearDown(c.dispose);
  await c.initialize();
  return c;
}

Future<void> mount(
  WidgetTester tester,
  Gateway api,
  MemoryStore store, {
  bool arabic = false,
  double width = 1440,
  String role = 'owner',
  String? registration = registrationId,
}) async {
  tester.view.physicalSize = Size(width, 1000);
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
      home: OfflineWalkInScreen(
        client: SupabaseClient(
          'http://127.0.0.1:54321',
          'mock-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        role: role,
        initialRegistrationRequestId: registration,
        gateway: api,
        store: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'lost preparation persists UUID only and reopens exact server command',
    () async {
      final api = Gateway()..losePrepare = true;
      final store = MemoryStore();
      final c = await controller(api, store);
      await c.loadContext(registrationId);
      await c.prepareSelection('service', [
        'worker',
      ], 'Private operational note');
      expect(c.locked, isTrue);
      expect(c.errorCode, 'unconfirmed');
      final id = store.value!;
      expect(store.writes, [id]);
      expect(store.writes.single, matches(RegExp(r'^[a-f0-9-]{36}$')));
      expect(api.preparations.single, {
        'p_request': id,
        'p_registration': registrationId,
        'p_service': 'service',
        'p_expected_price': 137.45,
        'p_cashier': 'cashier',
        'p_staff_ids': ['worker'],
        'p_notes': 'Private operational note',
      });
      final reopened = await controller(api, store);
      expect(reopened.status, 'prepared');
      expect(
        (reopened.view['payload'] as Map)['notes'],
        'Private operational note',
      );
      await reopened.place();
      expect(api.preparations, hasLength(1));
      expect(api.places, [id]);
      expect(reopened.result?['invoice_number'], 'SH-INV-000123');
      expect(store.value, id);
    },
  );
  test(
    'lost placement recovers actual success without creating another order',
    () async {
      final api = Gateway()
        ..current = Gateway().prepared(savedId)
        ..losePlace = true;
      final store = MemoryStore()..value = savedId;
      final c = await controller(api, store);
      await c.place();
      expect(c.locked, isTrue);
      expect(c.errorCode, 'unconfirmed');
      await c.place();
      expect(api.places, [savedId]);
      expect(c.status, 'succeeded');
      expect(store.clears, 0);
    },
  );

  test('VIP is carried into the same durable placement command', () async {
    final api = Gateway();
    final store = MemoryStore();
    final c = OfflineWalkInController(
      gateway: api,
      store: store,
      priority: 'vip',
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['worker'], 'VIP intake');
    await c.place();
    expect(api.requestedPriorities, ['vip']);
    expect(api.priorityRequests, api.places);
    expect(c.status, 'succeeded');
    expect(c.result?['work_status'], 'received');
  });
  test(
    'absent after reopening never unlocks; lost close retries same UUID',
    () async {
      final api = Gateway()..loseClose = true;
      final store = MemoryStore()..value = savedId;
      final c = await controller(api, store);
      expect(c.locked, isTrue);
      expect(c.canRetryPreparation, isFalse);
      await c.close();
      expect(c.locked, isTrue);
      expect(store.value, savedId);
      await c.close();
      expect(api.closes, [savedId, savedId]);
      expect(c.status, 'closed');
      expect(c.locked, isTrue);
      expect(store.clears, 0);
      await c.acknowledge();
      expect(api.acks, [savedId]);
      expect(store.value, isNull);
    },
  );
  test(
    'creation wins close and unconfirmed acknowledgement retains recovery UUID',
    () async {
      final api = Gateway()
        ..current = Gateway().prepared(savedId)
        ..ackConfirmed = false;
      final store = MemoryStore()..value = savedId;
      final c = await controller(api, store);
      api.current = api.succeeded(savedId);
      await c.close();
      expect(c.status, 'succeeded');
      expect(api.closes, [savedId]);
      await c.acknowledge();
      expect(c.locked, isTrue);
      expect(store.value, savedId);
      expect(store.clears, 0);
      api.ackConfirmed = true;
      await c.acknowledge();
      expect(api.acks, [savedId, savedId]);
      expect(store.value, isNull);
    },
  );
  test('employee context never prepares and invalid local choices dispatch nothing', () async {
    final api = Gateway()..employee = true;
    final store = MemoryStore();
    final c = await controller(api, store);
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['worker'], '');
    expect(api.preparations, isEmpty);
    expect(store.writes, isEmpty);
    api.employee = false;
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['not-eligible'], '');
    expect(api.preparations, isEmpty);
    expect(store.writes, isEmpty);
    expect(c.locked, isFalse);
  });
  test(
    'live paid and cancelled states replace the prior creation display',
    () async {
      final api = Gateway()..current = Gateway().succeeded(savedId);
      final c = await controller(api, MemoryStore()..value = savedId);
      api.current = {
        ...api.current!,
        'result': {
          ...api.current!['result'] as Map,
          'payment_status': 'paid',
          'collectible': false,
          'collectible_amount': 0,
        },
      };
      await c.recover();
      expect(c.result?['payment_status'], 'paid');
      expect(c.result?['collectible_amount'], 0);
      api.current = {
        ...api.current!,
        'result': {
          ...api.current!['result'] as Map,
          'payment_status': 'cancelled',
          'work_status': 'cancelled',
          'invoice_status': 'void',
        },
      };
      await c.recover();
      expect(c.result?['work_status'], 'cancelled');
      expect(c.result?['invoice_status'], 'void');
    },
  );
  for (final (ar, width) in [(true, 390.0), (false, 1440.0)]) {
    testWidgets(
      'explicit actual preparation and received receipt ${ar ? 'AR390' : 'EN1440'}',
      (tester) async {
        final api = Gateway();
        final store = MemoryStore();
        await mount(tester, api, store, arabic: ar, width: width);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('prepare_walk_in')),
              )
              .onPressed,
          isNull,
        );
        await press(tester, 'walk_in_service');
        await tester.tap(find.text('Actual QA service · 137.45 EGP').last);
        await tester.pumpAndSettle();
        await press(tester, 'walk_in_worker_worker');
        await press(tester, 'prepare_walk_in');
        expect(api.preparations.single['p_staff_ids'], ['worker']);
        expect(find.byKey(const ValueKey('walk_in_notes')), findsNothing);
        await press(tester, 'place_walk_in');
        expect(find.textContaining('SH-INV-000123'), findsWidgets);
        expect(find.byKey(const ValueKey('walk_in_invoice')), findsOneWidget);
        expect(find.textContaining('rate_percent'), findsNothing);
        expect(find.byKey(const ValueKey('start_walk_in')), findsNothing);
        expect(store.value, isNotNull);
        await press(tester, 'ack_walk_in');
        expect(store.value, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'employee consumes only own recovered preparation without assignment controls',
    (tester) async {
      final api = Gateway()
        ..employee = true
        ..current = Gateway().prepared(savedId);
      final store = MemoryStore();
      await mount(
        tester,
        api,
        store,
        role: 'employee',
        registration: null,
        width: 390,
      );
      expect(find.byKey(const ValueKey('walk_in_registration')), findsNothing);
      expect(find.byKey(const ValueKey('walk_in_service')), findsNothing);
      expect(find.byKey(const ValueKey('prepare_walk_in')), findsNothing);
      expect(store.value, savedId);
      await press(tester, 'place_walk_in');
      expect(api.places, [savedId]);
      expect(api.preparations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual registration context load enables from actual typed UUID',
    (tester) async {
      final api = Gateway();
      await mount(tester, api, MemoryStore(), registration: null);
      final input = find.byKey(const ValueKey('walk_in_registration'));
      await tester.enterText(input, registrationId);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('load_walk_in_context')),
            )
            .onPressed,
        isNotNull,
      );
      await press(tester, 'load_walk_in_context');
      expect(find.text('Actual QA reception · QA123'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'staff invoice route preserves role and omits customer payment flow',
    (tester) async {
      const token = '33333333-3333-4333-8333-333333333333';
      final api = Gateway();
      api.current = api.succeeded(savedId);
      api.current = {
        ...api.current!,
        'result': {...api.current!['result'] as Map, 'invoice_token': token},
      };
      final paths = <String>[];
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'http://127.0.0.1:54321',
          'mock-key',
          accessToken: () async => 'local-widget-token',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            final dynamic body;
            if (request.url.path.endsWith('/list_invoice_documents')) {
              body = [
                {'invoice_id': 'invoice', 'document_token': token},
              ];
            } else if (request.url.path.endsWith('/resolve_invoice_document')) {
              body = {
                'invoice_id': 'invoice',
                'invoice_number': 'SH-INV-000123',
                'document_token': token,
                'issued_at_cairo': '2026-11-14T20:00:00',
                'payment_status': 'unpaid',
                'payment_method': 'cash_on_receipt',
                'service_status': 'received',
                'snapshot': {
                  'branch': {
                    'name_ar': 'اختبار',
                    'name_en': 'QA',
                    'address_ar': 'QA',
                  },
                  'lines': [
                    {
                      'name': 'Actual QA service',
                      'quantity': 1,
                      'unit_price': 137.45,
                      'subtotal': 137.45,
                    },
                  ],
                  'total': 137.45,
                  'discount': 0,
                },
              };
            } else {
              throw StateError('Unexpected API path: ${request.url.path}');
            }
            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => client.dispose());
      });
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineWalkInScreen(
            client: client,
            role: 'employee',
            gateway: api,
            store: MemoryStore()..value = savedId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await press(tester, 'walk_in_invoice');
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        if (find.textContaining('Print / Reprint').evaluate().isNotEmpty) break;
      }
      expect(
        tester
            .widget<InvoiceDocumentsScreen>(find.byType(InvoiceDocumentsScreen))
            .role,
        'employee',
      );
      expect(
        find.text('تعذر تحميل الفواتير / Unable to load invoices'),
        findsNothing,
        reason: 'Invoice load must not swallow a mock/SDK error; paths: $paths',
      );
      expect(paths, contains('/rest/v1/rpc/resolve_invoice_document'));
      expect(find.textContaining('Payment options & prices'), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('Print / Reprint'),
        150,
        maxScrolls: 15,
        scrollable: find
            .descendant(
              of: find.byType(InvoiceDocumentsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Print / Reprint'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
