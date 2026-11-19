import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/hr_payroll.dart';

class FakeHr implements HrGateway {
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];
  bool failClockOnce = false;
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async {
    calls.add(action);
    payloads.add(Map<String, dynamic>.from(data));
    if (action == 'clock_in' && failClockOnce) {
      failClockOnce = false;
      throw Exception('Connection interrupted');
    }
    return {
      'staff': [],
      'employment': null,
      'attendance': [],
      'leave': [],
      'adjustments': [],
      'payroll': [],
    };
  }
}

void main() {
  test('request identifiers are unique valid v4 UUIDs', () {
    final ids = List.generate(100, (_) => hrRequestId());
    expect(ids.toSet().length, 100);
    for (final id in ids) {
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id),
        isTrue,
      );
    }
  });
  testWidgets(
    'employee sees own attendance and explicit missing compensation',
    (tester) async {
      final fake = FakeHr();
      await tester.pumpWidget(
        MaterialApp(
          home: HrPayrollScreen(
            client: SupabaseClient(
              'http://localhost:54321',
              'test',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
            ),
            gateway: fake,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No compensation configured. Payroll is blocked.'),
        findsOneWidget,
      );
      expect(find.text('Configure employment'), findsNothing);
      await tester.tap(find.text('Clock in now'));
      await tester.pumpAndSettle();
      expect(fake.calls, ['read', 'clock_in', 'read']);
      expect(find.text('Approve closed payroll period'), findsNothing);
    },
  );
  testWidgets('retry preserves request identity after an uncertain response', (
    tester,
  ) async {
    final fake = FakeHr()..failClockOnce = true;
    await tester.pumpWidget(
      MaterialApp(
        home: HrPayrollScreen(
          client: SupabaseClient(
            'http://localhost:54321',
            'test',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
          gateway: fake,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clock in now'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hr-error')), findsOneWidget);
    await tester.tap(find.text('Clock in now'));
    await tester.pumpAndSettle();
    final attempts = [
      for (var i = 0; i < fake.calls.length; i++)
        if (fake.calls[i] == 'clock_in') fake.payloads[i],
    ];
    expect(attempts.length, 2);
    expect(attempts[0]['request_id'], attempts[1]['request_id']);
  });
  testWidgets('Arabic mobile shows own attendance with RTL direction', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: HrPayrollScreen(
          client: SupabaseClient(
            'http://localhost:54321',
            'test',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
          gateway: FakeHr(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('الموظفون والرواتب'), findsOneWidget);
    expect(find.text('تسجيل الحضور الآن'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('تسجيل الحضور الآن'))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'owner sees compensation controls on narrow screen without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: HrPayrollScreen(
            client: SupabaseClient(
              'http://localhost:54321',
              'test',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
            ),
            owner: true,
            gateway: FakeHr(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Configure employment'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Configure employment'));
      await tester.pumpAndSettle();
      expect(find.text('Employment terms'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
