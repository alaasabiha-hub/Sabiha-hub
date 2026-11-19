import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

import 'package:sabiha_hub/owner_finance_dashboard.dart';

class FinanceGatewayFake implements OwnerFinanceGateway {
  @override
  String? currentUserId = 'qa-owner';
  String? selectedBranch = 'branch-1';
  final saves = <Map<String, dynamic>>[];
  final statuses = <String>[];
  Map<String, dynamic> report = {
    'time_zone': 'Africa/Cairo',
    'currency': 'EGP',
    'branches': [
      {'branch_id': 'branch-1', 'name_ar': 'الفرع الرئيسي', 'name_en': 'Main'},
      {'branch_id': 'branch-2', 'name_ar': 'فرع QA', 'name_en': 'QA branch'},
    ],
    'sales': {
      'active_invoice_count': 2,
      'billed_net_after_refunds': 1200,
      'discounts': 50,
      'refunds': 0,
      'revenue_ex_vat': 1052.63,
      'actual_profit': null,
      'profit_status': 'cost_coverage_incomplete',
    },
    'collections': {
      'paid_net': 900,
      'pending_invoice_balance': 300,
      'methods': [],
    },
    'operations': {
      'verified_cars_serviced': 2,
      'bookings_by_status': {'completed': 2},
    },
    'commissions': [
      {
        'staff_id': 'worker-1',
        'full_name': 'QA Worker',
        'commission_earned': 90,
        'commission_paid': null,
        'commission_remaining': null,
        'cars_serviced': 2,
        'completed_services': 3,
      },
    ],
    'expenses': {
      'incurred_total': 100,
      'legacy_payment_status_unknown': 0,
      'managed_paid': 100,
      'managed_unpaid': 0,
      'by_category': [],
    },
    'pnl': {
      'revenue_ex_vat': 1052.63,
      'inventory_cogs': null,
      'gross_profit': null,
      'payroll_cost': null,
      'operating_expenses': null,
      'net_profit': null,
      'status': 'cost_and_period_allocation_incomplete',
      'reason': 'QA costs are incomplete',
    },
    'limitations': ['inventory_cost_of_goods_not_allocated_to_sold_units'],
    'daily': [
      {'date': '2026-11-18', 'billed': 1200, 'collected': 900, 'cars': 2},
    ],
  };
  Map<String, dynamic> context = {
    'branch_id': 'branch-1',
    'branches': [
      {'branch_id': 'branch-1', 'name_ar': 'الفرع الرئيسي', 'name_en': 'Main'},
    ],
    'can_manage_expenses': true,
    'expenses': [],
  };

  @override
  Future<String> defaultBranch() async => selectedBranch!;
  @override
  Future<Map<String, dynamic>> dashboard(
    String branch,
    DateTime from,
    DateTime to,
  ) async => report;
  @override
  Future<Map<String, dynamic>> expenseContext(
    String branch,
    DateTime from,
    DateTime to,
  ) async => context;
  @override
  Future<Map<String, dynamic>> saveExpense(
    String requestId,
    Map<String, dynamic> payload,
  ) async {
    saves.add(payload);
    context = {
      ...context,
      'expenses': [
        {
          'expense_id': 'exp-1',
          'branch_id': payload['branch_id'],
          'category': payload['category'],
          'amount': payload['amount'],
          'expense_date': payload['expense_date'],
          'status': 'unpaid',
        },
      ],
    };
    return {'expense_id': 'exp-1'};
  }

  @override
  Future<Map<String, dynamic>> setExpenseStatus({
    required String requestId,
    required String expenseId,
    required String status,
    String? method,
  }) async {
    statuses.add(status);
    return {'expense_id': expenseId, 'status': status};
  }

  @override
  Future<String> uploadReceipt({
    required String branch,
    required String requestId,
    required String name,
    required Uint8List bytes,
    required String contentType,
  }) async => '$branch/expenses/$requestId/$name';
  @override
  Future<String> receiptUrl(String path) async => 'https://qa.invalid/$path';
}

Widget buildDashboard(FinanceGatewayFake gateway, Locale locale) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('ar'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: OwnerFinanceDashboardScreen(gateway: gateway),
);

void main() {
  testWidgets('Arabic dashboard uses QA facts and labels profit unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FinanceGatewayFake();
    await tester.pumpWidget(buildDashboard(gateway, const Locale('ar')));
    await tester.pumpAndSettle();
    expect(find.text('لوحة المالية والتشغيل'), findsOneWidget);
    expect(find.text('Sabiha AI - مؤشرات مالية من بيانات QA'), findsOneWidget);
    expect(
      find.textContaining('لن نعرض توقع مبيعات أو تكلفة غير موثوق.'),
      findsOneWidget,
    );
    expect(find.text('1200.00 EGP'), findsWidgets);
    expect(find.text('90.00 EGP'), findsWidgets);
    expect(
      find.text(
        'لا توجد تكلفة مكتملة للمواد والخدمات ولا دفتر صرف الرواتب والعمولات.',
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('finance-card-profit')));
    await tester.pumpAndSettle();
    expect(find.text('الربح غير متاح'), findsOneWidget);
    expect(find.textContaining('لن نعرض رقم ربح مضلل.'), findsOneWidget);
  });

  testWidgets(
    'English dashboard keeps actual collection separate from pending',
    (tester) async {
      final gateway = FinanceGatewayFake();
      await tester.pumpWidget(buildDashboard(gateway, const Locale('en')));
      await tester.pumpAndSettle();
      expect(find.text('Finance & Operations'), findsOneWidget);
      expect(find.byKey(const ValueKey('finance-export-pdf')), findsOneWidget);
      expect(find.text('900.00 EGP'), findsOneWidget);
      expect(find.text('300.00 EGP'), findsOneWidget);
      expect(find.text('Estimated net profit'), findsOneWidget);
    },
  );

  testWidgets('owner can create an audited expense with QA gateway', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FinanceGatewayFake();
    await tester.pumpWidget(buildDashboard(gateway, const Locale('en')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
    }
    expect(
      find.text('No expenses are recorded in this period.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('finance-add-expense')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('finance-add-expense')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('finance-expense-amount')),
      '125.50',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(gateway.saves, hasLength(1));
    expect(gateway.saves.single['amount'], 125.5);
    expect(gateway.saves.single['branch_id'], 'branch-1');
  });

  testWidgets('failed QA authorization never exposes finance details', (
    tester,
  ) async {
    final gateway = FinanceGatewayFake()..currentUserId = null;
    await tester.pumpWidget(buildDashboard(gateway, const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Finance & Operations'), findsOneWidget);
    expect(
      find.text('Owner access or explicit financial permission is required.'),
      findsOneWidget,
    );
    expect(find.text('1,200.00 EGP'), findsNothing);
  });
}
