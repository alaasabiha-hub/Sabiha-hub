import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/admin_console.dart';

Map<String, dynamic> fixture() => {
  'role': 'owner',
  'financial': true,
  'branches': [
    {
      'branch_id': 'branch-a',
      'name_ar': 'فرع الاختبار',
      'name_en': 'Test branch',
    },
  ],
  'staff': [
    {
      'user_id': 'staff-a',
      'full_name': 'Test staff',
      'role': 'employee',
      'is_active': true,
    },
  ],
  'catalog': [
    {
      'name': 'Test service',
      'item_type': 'service',
      'price': 300,
      'is_active': true,
    },
  ],
  'bookings': [],
  'customers': [],
  'shifts': [],
  'extra': {},
  'invoices': [
    {
      'invoice_id': 'INV-TEST',
      'service_name': 'Test service',
      'discount': 10,
      'total': 300,
      'status': 'active',
    },
  ],
  'payments': [
    {
      'invoice_id': 'INV-TEST',
      'method': 'cash',
      'event_type': 'sale',
      'amount': 300,
      'created_at': '2026-11-13T08:00:00Z',
      'cairo_hour': 10,
    },
  ],
  'report': {
    'net_billed': 300,
    'net_sales_ex_tax': null,
    'taxes': null,
    'fees': null,
    'discounts': 10,
    'invoice_count': 1,
    'average_invoice': 300,
    'hourly': [],
    'product_mix': [],
    'cash_activity': {'collections': 300, 'refunds': 0, 'transaction_count': 1},
  },
};
Future<SupabaseClient> start(
  WidgetTester tester, {
  String section = 'overview',
  String lang = 'en',
  double width = 1366,
  bool denied = false,
  void Function(Map)? query,
  Future<void> Function(Map)? beforeResponse,
  String? serverDay,
  Map<String, dynamic>? responseData,
  List<AdminAction> actions = const [],
}) async {
  late SupabaseClient client;
  await tester.runAsync(() async {
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      accessToken: () async => 'test',
      httpClient: MockClient((r) async {
        if (r.url.path == '/rest/v1/rpc/default_branch_id') {
          return http.Response(
            jsonEncode('branch-a'),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }
        expect(r.url.path, '/rest/v1/rpc/get_admin_console');
        query?.call(jsonDecode(r.body) as Map);
        await beforeResponse?.call(jsonDecode(r.body) as Map);
        return http.Response(
          jsonEncode(
            denied
                ? {'message': 'Denied', 'code': '42501'}
                : {...fixture(), ...?responseData, 'today_cairo': ?serverDay},
          ),
          denied ? 403 : 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: r,
        );
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AdminConsole(
        client: client,
        initialSection: section,
        actions: actions,
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('mobile owner sections use an accessible drawer ($lang)', (
      tester,
    ) async {
      final c = await start(tester, lang: lang, width: 390);
      expect(find.byKey(const ValueKey('admin-mobile-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-section-scroll')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('admin-mobile-menu')));
      await tester.pumpAndSettle();
      final inventory = find.byKey(const ValueKey('admin-drawer-inventory'));
      expect(inventory, findsOneWidget);
      await tester.tap(inventory);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('admin-mobile-current-section')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('admin-mobile-menu')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(c.dispose);
    });
  }

  testWidgets(
    'owner cashier, intelligence and offers are quick-access sections',
    (tester) async {
      var posOpened = 0;
      final actions = [
        AdminAction(
          'cashier',
          'نقطة البيع',
          'Point of sale',
          Icons.point_of_sale,
          () => posOpened++,
        ),
        AdminAction(
          'intelligence',
          'Sabiha AI',
          'Sabiha AI',
          Icons.auto_awesome,
          () {},
        ),
        AdminAction(
          'promotions',
          'كوبونات الخصم',
          'Discount coupons',
          Icons.local_offer,
          () {},
        ),
      ];
      await start(tester, actions: actions);
      expect(find.text('Owner quick access'), findsOneWidget);
      final pos = find.byKey(const ValueKey('owner-quick-Point of sale'));
      expect(pos, findsOneWidget);
      await tester.tap(pos);
      expect(posOpened, 1);
      await tester.tap(find.byKey(const ValueKey('admin-nav-intelligence')));
      await tester.pumpAndSettle();
      expect(find.text('Evidence-based analysis'), findsOneWidget);
      expect(find.text('Sabiha AI'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('admin-nav-promotions')));
      await tester.pumpAndSettle();
      expect(find.text('Pricing, offers & loyalty'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('owner sales reports provide day, week, month and year ranges', (
    tester,
  ) async {
    final queries = <Map>[];
    await start(
      tester,
      section: 'reports',
      lang: 'en',
      serverDay: '2026-11-17',
      query: (query) => queries.add(Map.from(query)),
    );
    queries.clear();

    for (final expected in {
      'period-this-week': '2026-11-16T00:00:00',
      'period-this-month': '2026-11-01T00:00:00',
      'period-this-year': '2026-01-01T00:00:00',
    }.entries) {
      final button = find.byKey(ValueKey(expected.key));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(queries.last['p_from_local'], expected.value);
      expect(queries.last['p_to_local'], '2026-11-18T00:00:00');
    }
  });

  testWidgets(
    'owner can compare equal-length periods without treating missing data as zero',
    (tester) async {
      final queries = <Map>[];
      await start(
        tester,
        section: 'reports',
        lang: 'en',
        query: (query) => queries.add(Map.from(query)),
        responseData: {
          'extra': {'expenses': []},
        },
      );
      final button = find.byKey(const ValueKey('compare-previous-period'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(queries, hasLength(2));
      expect(queries[0]['p_from_local'], queries[1]['p_to_local']);
      expect(
        DateTime.parse(queries[0]['p_to_local'])
            .difference(DateTime.parse(queries[0]['p_from_local'])),
        DateTime.parse(queries[1]['p_to_local'])
            .difference(DateTime.parse(queries[1]['p_from_local'])),
      );
      expect(find.text('Not recorded / incomplete'), findsWidgets);
      expect(find.textContaining('Actual profit'), findsOneWidget);
    },
  );

  testWidgets('owner period comparison is usable on a narrow Arabic screen', (
    tester,
  ) async {
    final queries = <Map>[];
    await start(
      tester,
      section: 'reports',
      lang: 'ar',
      width: 390,
      query: (query) => queries.add(Map.from(query)),
      responseData: {
        'extra': {'expenses': []},
      },
    );
    final button = find.byKey(const ValueKey('compare-previous-period'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(queries, hasLength(2));
    expect(find.text('مقارنة بعدد أيام مماثل'), findsOneWidget);
    expect(find.textContaining('الربح الفعلي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final lang in ['ar', 'en']) {
    testWidgets('Reviewed invoice refund and earned cost breakdown $lang', (
      tester,
    ) async {
      final c = await start(
        tester,
        section: 'reports',
        lang: lang,
        width: lang == 'ar' ? 390 : 1440,
        responseData: {
          ...fixture(),
          'report': {
            ...fixture()['report'] as Map,
            'contains_reviewed_cashier': true,
            'discount_tax_effect_recorded': 4.8,
            'cashier_refunds_on_active_invoices': 102.6,
            'commissions': 60,
            'cashier_commissions_earned_in_period': 60,
          },
        },
      );
      final title = find.text(lang == 'ar' ? 'صافي المبيعات' : 'Net Sales');
      await tester.ensureVisible(title.first);
      await tester.tap(title.first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          lang == 'ar' ? 'استردادات الفواتير النشطة' : 'Active invoice refunds',
        ),
        findsOneWidget,
      );
      expect(find.text('102.60 EGP'), findsOneWidget);
      expect(
        find.text(
          lang == 'ar'
              ? 'عمولات الخدمات المكتملة'
              : 'Earned service commissions',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      c.dispose();
    });
  }

  for (final lang in ['ar', 'en']) {
    testWidgets('Mixed invoice participation warning $lang', (tester) async {
      final c = await start(
        tester,
        section: 'reports',
        lang: lang,
        width: lang == 'ar' ? 390 : 1440,
        responseData: {
          ...fixture(),
          'report': {
            ...fixture()['report'] as Map,
            'filter_notice_required': true,
          },
        },
      );
      expect(
        find.text(
          lang == 'ar'
              ? 'يعرض الفلتر الفواتير التي شارك فيها الموظف أو تضمنت الخدمة؛ الإجماليات ليست مبيعات بند واحد أو كشف راتب.'
              : 'Filters show invoices involving the employee or service; totals are not single-line sales or a payslip.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      c.dispose();
    });
  }

  for (final lang in ['ar', 'en']) {
    for (final width in [768.0, 1024.0, 1440.0]) {
      testWidgets(
        'Overview fixed navigation fits $lang $width and keeps missing tax unknown',
        (tester) async {
          final c = await start(tester, lang: lang, width: width);
          expect(
            find.byKey(const ValueKey('admin-nav-overview')),
            findsOneWidget,
          );
          expect(
            find.text(
              lang == 'ar' ? 'نظرة عامة على المدفوعات' : 'Payments Overview',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.runAsync(c.dispose);
        },
      );
    }
  }
  testWidgets(
    'Today and Yesterday use the server Cairo day rather than the device date',
    (tester) async {
      final queries = <Map>[];
      final c = await start(
        tester,
        serverDay: '2026-01-01',
        query: queries.add,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(queries.last['p_from_local'], '2026-01-01T00:00:00');
      expect(queries.last['p_to_local'], '2026-01-02T00:00:00');
      await tester.tap(find.text('Yesterday'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(queries.last['p_from_local'], '2025-12-31T00:00:00');
      expect(queries.last['p_to_local'], '2026-01-01T00:00:00');
      await tester.runAsync(c.dispose);
    },
  );
  testWidgets(
    'Refreshing hides stale financial totals until the new authorized result arrives',
    (tester) async {
      Completer<void>? gate;
      final c = await start(
        tester,
        beforeResponse: (_) async {
          if (gate != null) await gate.future;
        },
      );
      expect(find.text('300.00 EGP'), findsWidgets);
      gate = Completer<void>();
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      expect(find.text('300.00 EGP'), findsNothing);
      gate.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('300.00 EGP'), findsWidgets);
      await tester.runAsync(c.dispose);
    },
  );
  testWidgets('Denied RPC renders no financial figures or stale report', (
    tester,
  ) async {
    final c = await start(tester, denied: true);
    expect(
      find.text('Could not load data. Check connection and permissions.'),
      findsOneWidget,
    );
    expect(find.text('300.00 EGP'), findsNothing);
    await tester.runAsync(c.dispose);
  });
  testWidgets(
    'Tab navigation uses the server report and keeps header in place',
    (tester) async {
      final c = await start(tester, section: 'reports');
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('admin-nav-reports')),
      );
      await tester.tap(find.byKey(const ValueKey('report-payments')));
      await tester.pumpAndSettle();
      expect(find.text('INV-TEST'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('admin-nav-reports'))),
        before,
      );
      expect(find.text('Test staff'), findsNothing);
      await tester.runAsync(c.dispose);
    },
  );
  testWidgets(
    'Employee service/payment filters stay scoped to the single default branch',
    (tester) async {
      final queries = <Map>[];
      final c = await start(tester, section: 'reports', query: queries.add);
      expect(queries.single['p_from_local'], contains('T00:00:00'));
      expect(queries.single.containsKey('p_zone'), isFalse);
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      final dropdown = find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField<String>,
      );
      await tester.tap(dropdown.at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test staff').last);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(queries.last['p_employee'], 'staff-a');
      expect(queries.last['p_branch'], 'branch-a');
      Future<void> select(int index, String label) async {
        await tester.tap(dropdown.at(index));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      await select(1, 'Test service');
      expect(queries.last['p_service'], 'Test service');
      await select(2, 'Electronic, unclassified');
      expect(queries.last['p_method'], 'electronic');
      expect(dropdown, findsNWidgets(3));
      expect(queries.last['p_branch'], 'branch-a');
      expect(queries.last['p_employee'], 'staff-a');
      expect(queries.last['p_service'], 'Test service');
      expect(queries.last['p_method'], 'electronic');
      expect(tester.takeException(), isNull);
      await tester.runAsync(c.dispose);
    },
  );
}
