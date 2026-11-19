import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/vehicle_inspections.dart';

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('inspection hub localized empty state $lang $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <http.Request>[];
        late SupabaseClient client;
        await tester.runAsync(() async {
          client = SupabaseClient(
            'https://local.example.test',
            'anon',
            accessToken: () async => 'test',
            httpClient: MockClient((request) async {
              calls.add(request);
              return http.Response(
                jsonEncode([]),
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
            locale: Locale(lang),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: InspectionHubScreen(client: client, role: 'owner'),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            lang == 'ar'
                ? 'فحص استلام وتسليم السيارات'
                : 'Vehicle intake & delivery inspections',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            lang == 'ar'
                ? 'لا توجد زيارات ظاهرة لحسابك.'
                : 'No visits are visible for your account.',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('receive_new_vehicle')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('receive_vip_vehicle')),
          findsOneWidget,
        );
        final element = tester.element(find.byType(ListView).first);
        expect(
          Directionality.of(element),
          lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        );
        expect(calls.length, 1);
        expect(calls.single.method, 'GET');
        expect(calls.single.url.path, '/rest/v1/bookings');
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final lang in ['ar', 'en']) {
    testWidgets('inspection hub denied read shows localized failure $lang', (
      tester,
    ) async {
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://local.example.test',
          'anon',
          accessToken: () async => 'test',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'code': '42501',
                'message': 'QA internal denied detail',
              }),
              403,
              request: request,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
      });
      addTearDown(() async {
        await tester.runAsync(client.dispose);
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: InspectionHubScreen(client: client, role: 'owner'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          lang == 'ar'
              ? 'تعذر تحميل زيارات السيارة.'
              : 'Unable to load vehicle visits.',
        ),
        findsOneWidget,
      );
      expect(find.text('QA internal denied detail'), findsNothing);
      expect(
        find.text(
          lang == 'ar'
              ? 'لا توجد زيارات ظاهرة لحسابك.'
              : 'No visits are visible for your account.',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
