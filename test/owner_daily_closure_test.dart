import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_daily_closure.dart';

class _DailyCloseFake implements OwnerDailyClosureGateway {
  String? actor = 'qa-owner';
  String? lastRequest;
  int branchLoads = 0;
  int prepareCalls = 0;
  int approveCalls = 0;
  bool failPrepareOnce = false;
  Map<String, dynamic>? record;

  @override
  String? get currentUserId => actor;

  @override
  Future<String> defaultBranchId() async {
    branchLoads++;
    return 'qa-branch';
  }

  @override
  Future<Map<String, dynamic>?> load(String branchId, String date) async =>
      record;

  @override
  Future<Map<String, dynamic>> prepare(
    String requestId,
    String branchId,
    String date,
  ) async {
    prepareCalls++;
    lastRequest ??= requestId;
    if (failPrepareOnce) {
      failPrepareOnce = false;
      throw StateError('simulated network timeout');
    }
    record = {
      'status': 'awaiting_approval',
      'prepared_at': '2026-11-16T16:00:00Z',
      'snapshot': {
        'report': {
          'invoice_count': 2,
          'net_billed': 1250,
          'billed_before_discount': 1300,
          'discounts': 50,
          'taxes': 0,
          'net_sales_ex_tax': 1250,
          'commissions': 80,
          'uncollected_recorded': 0,
          'actual_profit': null,
          'hourly': [
            {'hour': 10, 'net_billed': 120, 'completed_service_visits': 2},
          ],
        },
        'payment_activity': {
          'cash_collected': 500,
          'card_collected': 750,
          'cash_refunded': 0,
          'card_refunded': 0,
          'event_count': 2,
        },
        'expenses': {'total': 120, 'by_category': []},
        'shift_reconciliation': [],
      },
      'corrections': [],
    };
    return record!;
  }

  @override
  Future<Map<String, dynamic>> approve(String branchId, String date) async {
    approveCalls++;
    record = {...record!, 'status': 'approved', 'approved_at': 'now'};
    return record!;
  }
}

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

void main() {
  testWidgets('cashier is blocked before any branch or close request', (
    tester,
  ) async {
    final gateway = _DailyCloseFake();
    await tester.pumpWidget(
      _app(OwnerDailyClosureScreen(gateway: gateway, role: 'cashier')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Owner access only.'), findsOneWidget);
    expect(gateway.branchLoads, 0);
    expect(gateway.prepareCalls, 0);
    expect(gateway.approveCalls, 0);
  });

  testWidgets('expired session does not leave the close page loading', (
    tester,
  ) async {
    final gateway = _DailyCloseFake()..actor = null;
    await tester.pumpWidget(
      _app(OwnerDailyClosureScreen(gateway: gateway, role: 'owner')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your session ended. Reopen this screen.'), findsOneWidget);
    expect(gateway.branchLoads, 0);
  });

  testWidgets('owner prepares snapshot and approval is a separate action', (
    tester,
  ) async {
    final gateway = _DailyCloseFake();
    await tester.pumpWidget(
      _app(OwnerDailyClosureScreen(gateway: gateway, role: 'owner')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('prepare-daily-close')));
    await tester.pumpAndSettle();

    expect(gateway.prepareCalls, 1);
    expect(find.text('Awaiting owner approval'), findsOneWidget);
    expect(find.text('1250.00 EGP'), findsNWidgets(2));
    expect(find.textContaining('cost data is incomplete'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('daily-close-hourly')), 200);
    await tester.tap(find.byKey(const ValueKey('daily-close-hourly')));
    await tester.pumpAndSettle();
    expect(find.text('Verified completed visits: 2'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('approve-daily-close')),
      300,
    );
    expect(find.byKey(const ValueKey('approve-daily-close')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('approve-daily-close')));
    await tester.pumpAndSettle();
    expect(gateway.approveCalls, 1);
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(find.text('Approved by owner'), findsOneWidget);
    expect(find.byKey(const ValueKey('approve-daily-close')), findsNothing);
  });

  testWidgets('retry after uncertain network failure keeps same request id', (
    tester,
  ) async {
    final gateway = _DailyCloseFake()..failPrepareOnce = true;
    await tester.pumpWidget(
      _app(OwnerDailyClosureScreen(gateway: gateway, role: 'owner')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('prepare-daily-close')));
    await tester.pumpAndSettle();
    final firstRequest = gateway.lastRequest;
    expect(find.textContaining('Action failed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('prepare-daily-close')));
    await tester.pumpAndSettle();
    expect(gateway.prepareCalls, 2);
    expect(gateway.lastRequest, firstRequest);
    expect(find.text('Awaiting owner approval'), findsOneWidget);
  });

  testWidgets('daily close screen localizes Arabic', (tester) async {
    final gateway = _DailyCloseFake();
    await tester.pumpWidget(
      _app(
        OwnerDailyClosureScreen(gateway: gateway, role: 'owner'),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تقفيل يوم العمل'), findsOneWidget);
    expect(find.text('لا يوجد تقفيل محفوظ لهذا اليوم.'), findsOneWidget);
  });

  testWidgets('daily close remains usable on phone and desktop widths', (
    tester,
  ) async {
    final gateway = _DailyCloseFake();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(OwnerDailyClosureScreen(gateway: gateway, role: 'owner')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('daily-close-date')), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.text('Business day close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
