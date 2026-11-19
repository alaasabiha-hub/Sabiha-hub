import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/wash_reception.dart';

void main() {
  test('reception management is owner and manager only', () {
    expect(canManageReception('owner'), isTrue);
    expect(canManageReception('manager'), isTrue);
    for (final role in ['employee', 'customer', null]) {
      expect(canManageReception(role), isFalse);
    }
  });
  test('arrival and in-service labels remain distinct from VIP', () {
    expect(
      receptionState({'branch_conflict': true}, false),
      'Reception branch needs review',
    );
    expect(
      receptionState({'status': 'in_progress', 'vip': true}, false),
      'In service',
    );
    expect(
      receptionState({
        'status': 'confirmed',
        'arrived': true,
        'vip': true,
      }, false),
      'VIP',
    );
    expect(
      receptionState({'status': 'confirmed', 'arrived': false}, false),
      'Not arrived',
    );
  });
  for (final locale in ['en', 'ar']) {
    for (final role in ['owner', 'employee']) {
      testWidgets(
        '$role queue $locale preserves server ordering and staff action scope',
        (tester) async {
          final arabic = locale == 'ar';
          tester.view.physicalSize = Size(arabic ? 390 : 1440, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final calls = <String>[];
          late SupabaseClient client;
          // Construct and dispose the native JSON isolate in the real async zone,
          // matching the existing owner-insights RPC widget harness.
          await tester.runAsync(() async {
            client = SupabaseClient(
              'https://local.example.test',
              'anon',
              accessToken: () async => 'test',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
              httpClient: MockClient((request) async {
                calls.add(request.url.path);
                return http.Response(
                  jsonEncode(
                    request.url.path.endsWith('list_offline_walk_in_reception')
                        ? []
                        : [
                            {
                              'id': 'vip',
                              'booking_number': 'SH-BKG-000002',
                              'service_name': arabic
                                  ? 'زيارة VIP'
                                  : 'VIP visit',
                              'booking_time': '11:00',
                              'status': 'confirmed',
                              'arrived': true,
                              'priority': 'vip',
                              'vip': true,
                              'branch_name_en': 'Branch',
                              'branch_name_ar': 'الفرع',
                              'revision': 1,
                            },
                            {
                              'id': 'standard',
                              'booking_number': 'SH-BKG-000001',
                              'service_name': arabic
                                  ? 'زيارة عادية'
                                  : 'Standard visit',
                              'booking_time': '10:00',
                              'status': 'confirmed',
                              'arrived': true,
                              'priority': 'normal',
                              'vip': false,
                              'branch_name_en': 'Branch',
                              'branch_name_ar': 'الفرع',
                              'revision': 1,
                            },
                          ],
                  ),
                  200,
                  request: request,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
          });
          addTearDown(() async {
            await tester.runAsync(client.dispose);
          });
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              supportedLocales: const [Locale('en'), Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: WashReceptionScreen(client: client, role: role),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          final vip = find.textContaining('SH-BKG-000002').first;
          final standard = find.textContaining('SH-BKG-000001').first;
          expect(vip, findsOneWidget);
          expect(standard, findsOneWidget);
          expect(
            tester.getTopLeft(vip).dy,
            lessThan(tester.getTopLeft(standard).dy),
          );
          expect(
            find.text(arabic ? 'الأولوية' : 'Priority'),
            role == 'owner' ? findsNWidgets(2) : findsNothing,
          );
          expect(calls, [
            '/rest/v1/rpc/get_wash_reception_queue',
            '/rest/v1/rpc/list_offline_walk_in_reception',
          ]);
          expect(
            tester.takeException(),
            isNull,
            reason: '$locale layout must fit ${arabic ? 390 : 1440}px',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }
  }

  testWidgets('typed walk-in VIP rows are included ahead of standard visits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late SupabaseClient client;
    await tester.runAsync(() async {
      client = SupabaseClient(
        'https://local.example.test',
        'anon',
        accessToken: () async => 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final walkIn = request.url.path.endsWith(
            'list_offline_walk_in_reception',
          );
          return http.Response(
            jsonEncode(
              walkIn
                  ? [
                      {
                        'source_kind': 'walk_in',
                        'work_reference': 'SH-WALKIN-1',
                        'service_name': 'Walk-in service',
                        'plate_number': 'QA 123',
                        'status': 'received',
                        'arrived_at': '2026-11-19T08:00:00Z',
                        'priority': 'vip',
                      },
                    ]
                  : [
                      {
                        'id': 'standard',
                        'booking_number': 'SH-BKG-000001',
                        'service_name': 'Standard visit',
                        'booking_time': '09:00',
                        'status': 'confirmed',
                        'arrived': true,
                        'priority': 'normal',
                        'vip': false,
                      },
                    ],
            ),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });
    addTearDown(() async => tester.runAsync(client.dispose));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: WashReceptionScreen(client: client, role: 'owner'),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final walkIn = find.textContaining('SH-WALKIN-1');
    final standard = find.textContaining('SH-BKG-000001');
    expect(walkIn, findsOneWidget);
    expect(standard, findsOneWidget);
    expect(
      tester.getTopLeft(walkIn).dy,
      lessThan(tester.getTopLeft(standard).dy),
    );
    expect(find.textContaining('VIP'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });
}
