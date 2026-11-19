import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/offline_customer_registration.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MemoryRegistrationStore implements OfflineRegistrationStore {
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
    clears++;
    value = null;
  }
}

class FakeRegistrationGateway implements OfflineRegistrationGateway {
  @override
  Future<Map<String, dynamic>> close(String requestId, String branchId) async =>
      throw UnimplementedError('Existing cases do not close registrations');
  final calls = <Map<String, dynamic>>[];
  final recoveries = <String>[];
  bool failOnce = false, denied = false, reviewFirst = false;
  Map<String, dynamic>? recovered;
  Map<String, dynamic> result(
    String id, {
    String status = 'created_unverified',
  }) => {
    'request_id': id,
    'status': status,
    'offline_profile_id': status == 'review_required'
        ? null
        : 'offline-profile',
    'phone_masked': '******2233',
    'identity_verified': false,
    'enrollment_secret_issued': status == 'created_unverified',
    'enrollment_secret_recoverable': false,
    'capabilities': {
      'offline_registration': true,
      'phone_verification': false,
      'guest_redemption': false,
      'auth_linking': false,
      'walk_in_loyalty_accrual': false,
    },
  };
  @override
  Future<Map<String, dynamic>> register(Map<String, dynamic> parameters) async {
    calls.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(parameters)) as Map),
    );
    if (denied) {
      throw const PostgrestException(message: 'Denied', code: '42501');
    }
    if (failOnce) {
      failOnce = false;
      throw Exception('Synthetic connection failure');
    }
    final id = parameters['p_request'] as String;
    if (reviewFirst && calls.length == 1) {
      return result(id, status: 'review_required');
    }
    return {...result(id), 'enrollment_secret': 'SYNTHETIC-PRIVATE-RECEIPT'};
  }

  @override
  Future<Map<String, dynamic>> recover(String id) async {
    recoveries.add(id);
    return recovered ??
        {
          'request_id': id,
          'status': 'absent',
          'may_retry_same_request': true,
          'definitive_failure': false,
        };
  }
}

SupabaseClient testClient() => SupabaseClient(
  'http://127.0.0.1:54321',
  'local-widget-test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

Future<void> mount(
  WidgetTester tester,
  FakeRegistrationGateway api,
  MemoryRegistrationStore store, {
  bool arabic = false,
  String role = 'employee',
  double width = 1440,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(arabic ? 'ar' : 'en'),
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: OfflineCustomerRegistrationScreen(
        client: testClient(),
        branchId: 'branch-one',
        role: role,
        gateway: api,
        store: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
}

Future<void> press(WidgetTester tester, String key) async {
  tester.testTextInput.hide();
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> fill(
  WidgetTester tester, {
  bool agree = true,
  bool arabic = false,
}) async {
  await enter(tester, 'customer_name', 'Actual QA Customer');
  await enter(tester, 'customer_phone', '01001112233');
  await enter(tester, 'car_plate', 'QA 123');
  final vehicleClass = find.byKey(const ValueKey('vehicle_class_code'));
  await tester.ensureVisible(vehicleClass);
  await tester.tap(vehicleClass);
  await tester.pumpAndSettle();
  await tester.tap(find.text(arabic ? 'سيدان' : 'Sedan').last);
  await tester.pumpAndSettle();
  if (agree) await press(tester, 'registration_consent');
}

void main() {
  test('explicit EG input normalization accepts mobile, landline and Arabic digits', () {
    for (final phone in [
      '01001112233',
      '+20 100 111 2233',
      '00201001112233',
      '٠١٠٠١١١٢٢٣٣',
      '0212345678',
      '+442071234567',
    ]) {
      expect(validOfflineRegistrationPhone(phone), isTrue, reason: phone);
    }
    for (final phone in [
      '',
      '123',
      'customer@example.com',
      '20 1001112233',
      '+00012345678',
    ]) {
      expect(validOfflineRegistrationPhone(phone), isFalse, reason: phone);
    }
  });

  testWidgets(
    'Arabic narrow form requires explicit consent and has no account fields',
    (tester) async {
      final api = FakeRegistrationGateway(), store = MemoryRegistrationStore();
      await mount(tester, api, store, arabic: true, width: 390);
      await fill(tester, agree: false, arabic: true);
      await press(tester, 'submit_registration');
      expect(api.calls, isEmpty);
      expect(store.writes, isEmpty);
      expect(find.text(offlineRegistrationConsentArabic), findsOneWidget);
      expect(find.textContaining('كلمة المرور'), findsNothing);
      expect(find.textContaining('البريد الإلكتروني'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide success displays one-time code but persists only UUID', (
    tester,
  ) async {
    final api = FakeRegistrationGateway(), store = MemoryRegistrationStore();
    await mount(tester, api, store);
    await fill(tester);
    await press(tester, 'submit_registration');
    expect(api.calls.single['p_consent'], {
      'accepted': true,
      'version': offlineRegistrationConsentVersion,
      'text': offlineRegistrationConsentEnglish,
      'language': 'en',
    });
    expect(api.calls.single['p_country'], 'EG');
    expect((api.calls.single['p_car'] as Map)['vehicle_class_code'], 'sedan');
    expect(
      api.calls.single.keys.any(
        (key) => key.contains('email') || key.contains('password'),
      ),
      isFalse,
    );
    expect(find.byKey(const ValueKey('enrollment_secret')), findsOneWidget);
    expect(find.textContaining('cannot be recovered'), findsOneWidget);
    expect(store.writes, [api.calls.single['p_request']]);
    expect(store.writes.single, matches(RegExp(r'^[a-f0-9-]{36}$')));
    expect(store.value, isNot(contains('PRIVATE')));
    final done = tester.widget<FilledButton>(
      find.byKey(const ValueKey('registration_done')),
    );
    expect(done.onPressed, isNull);
    await press(tester, 'receipt_acknowledged');
    await press(tester, 'registration_done');
    expect(store.value, isNull);
    expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'uncertain request freezes all inputs and retries exact payload and UUID',
    (tester) async {
      final api = FakeRegistrationGateway()..failOnce = true;
      final store = MemoryRegistrationStore();
      await mount(tester, api, store);
      await fill(tester);
      await press(tester, 'submit_registration');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('customer_name')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('submit_registration')),
            )
            .onPressed,
        isNull,
      );
      await press(tester, 'retry_registration');
      expect(api.calls, hasLength(2));
      expect(api.calls[1], api.calls[0]);
      expect(store.writes, hasLength(1));
      expect(find.text('Customer record saved · unverified'), findsOneWidget);
    },
  );

  testWidgets(
    'reopened absent UUID stays frozen without a fabricated retry payload',
    (tester) async {
      final api = FakeRegistrationGateway();
      final store = MemoryRegistrationStore()
        ..value = '11111111-1111-4111-8111-111111111111';
      await mount(tester, api, store, width: 390);
      expect(api.recoveries, [store.value]);
      expect(api.calls, isEmpty);
      expect(store.clears, 0);
      expect(find.byKey(const ValueKey('retry_registration')), findsNothing);
      expect(find.byKey(const ValueKey('registration_done')), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('customer_phone')))
            .enabled,
        isFalse,
      );
      await press(tester, 'recover_registration');
      expect(api.recoveries, hasLength(2));
      expect(store.value, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cashier review cannot override while owner uses a new immutable request',
    (tester) async {
      var api = FakeRegistrationGateway()..reviewFirst = true;
      var store = MemoryRegistrationStore();
      await mount(tester, api, store, role: 'employee');
      await fill(tester);
      await press(tester, 'submit_registration');
      expect(find.byKey(const ValueKey('create_separate')), findsNothing);
      expect(api.calls.single['p_duplicate_action'], isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      api = FakeRegistrationGateway()..reviewFirst = true;
      store = MemoryRegistrationStore();
      await mount(tester, api, store, role: 'owner');
      await fill(tester);
      await press(tester, 'submit_registration');
      await enter(
        tester,
        'review_reason',
        'Confirmed separate family member after review',
      );
      await press(tester, 'create_separate');
      expect(api.calls, hasLength(2));
      expect(api.calls[1]['p_request'], isNot(api.calls[0]['p_request']));
      expect(api.calls[1]['p_duplicate_action'], 'create_separate');
      expect(api.calls[1]['p_car'], api.calls[0]['p_car']);
      expect(api.calls[1]['p_name'], api.calls[0]['p_name']);
      expect(store.clears, 1);
    },
  );

  testWidgets(
    'recovered receipt never recovers secret and requires acknowledgement',
    (tester) async {
      final api = FakeRegistrationGateway();
      final store = MemoryRegistrationStore()
        ..value = '22222222-2222-4222-8222-222222222222';
      api.recovered = api.result(store.value!);
      await mount(tester, api, store, arabic: true, width: 390);
      expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
      expect(find.textContaining('لا يمكن عرض رمز الإيصال'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('registration_done')),
            )
            .onPressed,
        isNull,
      );
      await press(tester, 'receipt_acknowledged');
      await press(tester, 'registration_done');
      expect(store.value, isNull);
      expect(api.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'current server role denial keeps attempt reference and does not grant access',
    (tester) async {
      final api = FakeRegistrationGateway()..denied = true;
      final store = MemoryRegistrationStore();
      await mount(tester, api, store, role: 'owner');
      await fill(tester);
      await press(tester, 'submit_registration');
      expect(api.calls, hasLength(1));
      expect(store.value, isNotNull);
      expect(
        find.textContaining('cannot access this registration'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
      expect(find.byKey(const ValueKey('create_separate')), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('car_plate')))
            .enabled,
        isFalse,
      );
    },
  );
}
