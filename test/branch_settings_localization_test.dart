import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/branch_settings.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('establishment localization $language $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final methods = <String>[];
        final client = (await tester.runAsync(
          () async => SupabaseClient(
            'http://127.0.0.1:54321',
            'qa-test-only',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              methods.add(request.method);
              expect(request.method, 'GET');
              final data = switch (request.url.path.split('/').last) {
                'business_branches' => <Map<String, dynamic>>[
                  {
                    'branch_id': 'branch-test',
                    'is_default': true,
                    'name_ar': 'مركز اختبار',
                    'name_en': 'QA centre',
                    'address_ar': '',
                    'address_en': '',
                    'maps_url': '',
                    'whatsapp_phone': '',
                    'minimum_subtotal': 0,
                    'is_active': true,
                    'temporarily_closed': false,
                    'delivery_enabled': false,
                    'inspection_required': false,
                  },
                ],
                'staff_profiles' => <Map<String, dynamic>>[
                  {'user_id': 'owner-test', 'full_name': 'QA', 'role': 'owner'},
                ],
                'staff_branch_access' => <Map<String, dynamic>>[
                  {'user_id': 'owner-test', 'can_edit_prices': false},
                ],
                _ => <Map<String, dynamic>>[],
              };
              return http.Response(
                jsonEncode(data),
                200,
                request: request,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          ),
        ))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.runAsync(client.dispose);
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: BranchSettingsScreen(client: client),
          ),
        );
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        await tester.pumpAndSettle();
        final ar = language == 'ar';
        expect(
          find.text(ar ? 'إعدادات المركز والفروع' : 'Establishment settings'),
          findsOneWidget,
        );
        expect(
          find.text(ar ? 'الاسم بالإنجليزية' : 'Name in English'),
          findsOneWidget,
        );
        expect(find.text('English name'), findsNothing);
        expect(
          Directionality.of(tester.element(find.byType(BranchSettingsScreen))),
          ar ? TextDirection.rtl : TextDirection.ltr,
        );
        expect(
          methods.length,
          7,
          reason: 'All read-only fixture tables loaded',
        );
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.axisDirection, AxisDirection.down);
        for (var attempt = 0; attempt < 5; attempt++) {
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pump();
        }
        expect(find.text(ar ? 'QA · المالك' : 'QA · Owner'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(
          find.text(ar ? 'السماح بتعديل الأسعار' : 'Allow price changes'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(methods, isNotEmpty);
        expect(methods.every((method) => method == 'GET'), isTrue);
      });
    }
  }
}
