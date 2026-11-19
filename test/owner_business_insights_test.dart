import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_business_insights.dart';

class InsightsTestAuth extends GoTrueClient {
  InsightsTestAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  final user = User(
    id: 'owner',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession =>
      Session(accessToken: 'test', tokenType: 'bearer', user: user);
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class InsightsTestClient extends SupabaseClient {
  InsightsTestClient(this.fake, http.Client httpClient)
    : super(
        'http://localhost:54321',
        'test',
        accessToken: () async => 'test',
        httpClient: httpClient,
      );
  final InsightsTestAuth fake;
  @override
  GoTrueClient get auth => fake;
}

void main() {
  Future<void> open(
    WidgetTester t, {
    String locale = 'en',
    bool denied = false,
    bool empty = false,
  }) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final auth = InsightsTestAuth();
    addTearDown(auth.events.close);
    late SupabaseClient client;
    await t.runAsync(() async {
      client = InsightsTestClient(
        auth,
        MockClient((r) async {
          expect(r.url.path, endsWith('/get_owner_business_insights'));
          expect(jsonDecode(r.body)['p_from'], isNotNull);
          return http.Response(
            jsonEncode(
              denied
                  ? {'code': '42501', 'message': 'Owner required'}
                  : {
                      'as_of': '2026-11-14T10:00:00Z',
                      'billed_revenue_basis': 'active_invoice_issue_window_net_cashier_line_refunds',
                      'metrics': empty
                          ? []
                          : [
                              {
                                'code': 'billed_revenue',
                                'value': 47.25,
                                'unit': 'EGP',
                                'source': 'business_invoices',
                                'count': 1,
                                'basis': 'window',
                              },
                              {
                                'code': 'average_review_stars',
                                'value': null,
                                'unit': 'stars',
                                'source': 'employee_service_reviews',
                                'count': 0,
                                'basis': 'window',
                              },
                            ],
                      'insights': [],
                      'limitations': [
                        'incomplete_costs_no_actual_profit',
                        'no_marketing_attribution',
                        'no_forecast_or_causal_inference',
                      ],
                    },
            ),
            denied ? 403 : 200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
      );
    });
    addTearDown(() async {
      await t.runAsync(client.dispose);
    });
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerBusinessInsightsScreen(client: client),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pumpAndSettle();
  }

  for (final locale in ['ar', 'en']) {
    testWidgets(
      'Evidence overview $locale narrow uses actual provenance and unknown',
      (t) async {
        await open(t, locale: locale);
        expect(find.textContaining('47.25'), findsOneWidget);
        expect(
          find.textContaining(
            locale == 'ar' ? 'لا يمثل الربح' : 'is not profit',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            locale == 'ar'
                ? 'صافي قيمة الفواتير النشطة'
                : 'Net active invoice value',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('business_invoices'), findsOneWidget);
        expect(
          find.text(locale == 'ar' ? 'غير متاح' : 'Unavailable'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            locale == 'ar' ? 'قواعد وصفية' : 'Descriptive rules',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026-11-14T10:00:00Z'), findsNothing);
        expect(
          find.textContaining(
            locale == 'ar'
                ? '14 نوفمبر 2026 · 10:00 ص UTC'
                : '14 November 2026 · 10:00 AM UTC',
          ),
          findsOneWidget,
        );
        final period = t
            .widget<Text>(find.byKey(const ValueKey('owner-insights-period')))
            .data!;
        expect(period, startsWith(locale == 'ar' ? 'من: ' : 'From: '));
        expect(period, contains(locale == 'ar' ? '\nإلى: ' : '\nTo: '));
        expect(period, isNot(contains(' — ')));
        await t.scrollUntilVisible(
          find.byKey(const ValueKey('free-owner-assistant')),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.byKey(const ValueKey('free-owner-assistant')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            locale == 'ar' ? 'مزود AI خارجي' : 'external AI provider',
          ),
          findsNothing,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('Owner denied exposes no evidence', (t) async {
    await open(t, denied: true);
    expect(find.text('Owner access is required'), findsOneWidget);
    expect(find.textContaining('business_invoices'), findsNothing);
  });
  testWidgets('Empty evidence has explicit state', (t) async {
    await open(t, empty: true);
    expect(find.textContaining('No evidence records'), findsOneWidget);
    expect(find.textContaining('47.25'), findsNothing);
  });
}
