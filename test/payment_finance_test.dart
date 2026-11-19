import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/payment_finance.dart';

void main() {
  final report = <String, dynamic>{
    'period': {'from': '2026-01-01', 'to': '2026-01-31'},
    'summary': {
      'cash_collections': 100,
      'cash_refunds': 10,
      'cash_net': 90,
      'cash_count': 2,
      'card_collections': null,
      'gateway_fees_actual': null,
      'net_collections': 90,
      'revenue_billed': 150,
      'actual_profit': null,
      'expenses_recorded': 20,
    },
    'series': [],
    'services': [],
    'policy_cohorts': [],
    'recommendations': [],
    'alerts': [],
    'sufficient_data': false,
  };
  Future<void> open(
    WidgetTester t, {
    bool policy = true,
    bool denied = false,
    String locale = 'en',
    double width = 390,
    void Function(Map<String, dynamic>)? save,
  }) async {
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late SupabaseClient client;
    await t.runAsync(() async {
      client = SupabaseClient(
        'http://localhost:54321',
        'test',
        accessToken: () async => 'test',
        httpClient: MockClient((r) async {
          if (denied) {
            return http.Response(
              '{"code":"42501","message":"owner required"}',
              403,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }
          dynamic body;
          if (r.url.path.endsWith('save_payment_policy')) {
            save?.call(Map<String, dynamic>.from(jsonDecode(r.body)));
            body = 'saved';
          } else if (r.url.path.endsWith('get_payment_policy_context')) {
            body = {
              'branch_id': 'test',
              'policies': [],
              'history': [],
              'services': [
                {'item_id': 's1', 'name': 'Wash', 'price': 100},
              ],
            };
          } else {
            expect(r.url.path, endsWith('get_ai_payment_analytics'));
            body = report;
          }
          return http.Response(
            jsonEncode(body),
            200,
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
        home: policy
            ? PaymentPolicyScreen(client: client)
            : AiPaymentAnalyticsScreen(client: client),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pumpAndSettle();
  }

  for (final locale in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('Policy $locale $width saves draft without activation', (
        t,
      ) async {
        final writes = <Map<String, dynamic>>[];
        await open(t, locale: locale, width: width, save: writes.add);
        expect(
          find.textContaining(
            locale == 'ar' ? 'الأسعار الفعلية' : 'Actual cash and card prices',
          ),
          findsWidgets,
        );
        final label = locale == 'ar'
            ? 'حفظ إصدار مستقبلي'
            : 'Save future version';
        await t.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await t.tap(find.text(label));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pumpAndSettle();
        expect(writes, hasLength(1));
        expect(writes.first['p_policy']['proposed_mode'], 'equal');
        expect(
          writes.first['p_policy'].containsKey('surcharge_enabled'),
          false,
        );
        expect(t.takeException(), isNull);
      });
      testWidgets('Analytics $locale $width discloses missing data', (t) async {
        await open(t, policy: false, locale: locale, width: width);
        expect(
          find.textContaining(
            locale == 'ar' ? 'غير كافية' : 'Insufficient data',
          ),
          findsOneWidget,
        );
        expect(
          find.text(locale == 'ar' ? 'غير متاح' : 'Unavailable'),
          findsWidgets,
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final policy in [true, false]) {
    testWidgets('Owner denial policy=$policy', (t) async {
      await open(t, denied: true, policy: policy);
      expect(
        find.text('Owner access is required for this data'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Export PDF'), findsNothing);
    });
  }
  testWidgets('Draft value editing never changes actual cash or card price', (
    t,
  ) async {
    await open(t);
    final field = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Draft value',
    );
    await t.ensureVisible(field);
    await t.enterText(field, '25');
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.textContaining('Actual cash: 100.00 EGP'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Actual cash: 100.00 EGP'), findsOneWidget);
    expect(find.textContaining('Actual card: 100.00 EGP'), findsOneWidget);
    expect(find.textContaining('Customer surcharge: 0.00 EGP'), findsWidgets);
  });
  test('PDF actual snapshot AR and EN smoke', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = (await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf'))
        .buffer
        .asUint8List();
    final logo = (await rootBundle.load('assets/sabiha_brand_approved.png'))
        .buffer
        .asUint8List();
    for (final ar in [true, false]) {
      final bytes = await buildPaymentAnalyticsPdf(
        report,
        font,
        logo,
        arabic: ar,
      );
      expect(ascii.decode(bytes.take(4).toList()), '%PDF');
      expect(bytes.length, greaterThan(2000));
      Directory('work/runtime').createSync(recursive: true);
      File('work/runtime/payment-analytics-${ar ? 'ar' : 'en'}-test.pdf')
          .writeAsBytesSync(bytes);
    }
  });
}
