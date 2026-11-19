import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/main.dart' show StaffOperationsScreen;
import 'package:sabiha_hub/service_work.dart';

void main() {
  test('routing preserves only explicit legacy compatibility', () {
    expect(
      serviceWorkRoute({}, booking: true, requestedStatus: 'completed'),
      ServiceWorkRoute.review,
    );
    expect(
      serviceWorkRoute(
        {'canonical_work_supported': true},
        booking: true,
        requestedStatus: 'completed',
      ),
      ServiceWorkRoute.canonical,
    );
    expect(
      serviceWorkRoute(
        {'legacy_unpaired_booking': true},
        booking: true,
        requestedStatus: 'completed',
      ),
      ServiceWorkRoute.legacy,
    );
    expect(
      serviceWorkRoute(
        {'legacy_booking_alignment': true},
        booking: true,
        requestedStatus: 'in_progress',
      ),
      ServiceWorkRoute.legacy,
    );
    expect(
      serviceWorkRoute(
        {'legacy_booking_alignment': true},
        booking: true,
        requestedStatus: 'completed',
      ),
      ServiceWorkRoute.review,
    );
    expect(
      serviceWorkRoute(
        {'legacy_active_progress': true},
        booking: false,
        requestedStatus: 'delivered',
      ),
      ServiceWorkRoute.legacy,
    );
  });
  for (final locale in ['ar', 'en']) {
    for (final denied in [false, true]) {
      testWidgets(
        'existing service action $locale denied=$denied never writes status directly',
        (t) async {
          t.view.physicalSize = Size(locale == 'ar' ? 390 : 1440, 1100);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final requests = <http.Request>[];
          const id = '22222222-2222-4222-8222-222222222222';
          final client = (await t.runAsync(
            () async => SupabaseClient(
              'http://localhost:54321',
              'test',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
              httpClient: MockClient((r) async {
                requests.add(r);
                dynamic data = [];
                var code = 200;
                if (r.url.path.endsWith('/get_staff_operations')) {
                  data = {'role':'manager','bookings':[],'staff_directory':[],'orders':[
                    {
                      'order_id': id,
                      'order_number': 'SH-INV-000123',
                      'service_name': 'Saved service',
                      'status': 'received',
                      'order_type': 'service',
                    },
                  ]};
                } else if (r.url.path.endsWith('/get_service_work_context')) {
                  expect(jsonDecode(r.body), {
                    'p_order': id,
                    'p_booking': null,
                  });
                  if (denied) {
                    code = 403;
                    data = {'code': '42501', 'message': 'Denied'};
                  } else {
                    data = {'canonical_work_supported': true, 'order_id': id};
                  }
                }
                return http.Response(
                  jsonEncode(data),
                  code,
                  headers: {'content-type': 'application/json'},
                  request: r,
                );
              }),
            ),
          ))!;
          addTearDown(client.dispose);
          await t.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: StaffOperationsScreen(
                role: 'manager',
                fullName: 'QA',
                client: client,
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(find.text('Saved service'), findsOneWidget);
          final next = find.byTooltip(
            locale == 'ar' ? 'قيد التنفيذ' : 'In progress',
          );
          await t.ensureVisible(next);
          await t.tap(next);
          await t.pumpAndSettle();
          expect(
            requests
                .where((r) => r.url.path.endsWith('/get_service_work_context'))
                .length,
            1,
          );
          expect(
            find.byType(ServiceWorkScreen),
            denied ? findsNothing : findsOneWidget,
          );
          expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
          expect(
            requests.where(
              (r) =>
                  r.url.path.contains('/prepare_service_work') ||
                  r.url.path.contains('/place_service_work'),
            ),
            isEmpty,
          );
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          await t.pumpAndSettle();
        },
      );
    }
  }
}
