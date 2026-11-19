import 'dart:io';

import '../lib/owner_finance_pdf.dart';

Future<void> main() async {
  final font = await File('assets/NotoNaskhArabic-Regular.ttf').readAsBytes();
  final logo = await File('assets/sabiha_brand_approved.png').readAsBytes();
  final report = <String, dynamic>{
    'time_zone': 'Africa/Cairo',
    'as_of': 'QA visual sample',
    'sales': {
      'billed_net_after_refunds': 1250,
      'discounts': 50,
      'refunds': 0,
      'revenue_ex_vat': 1096.49,
      'average_invoice': 625,
    },
    'collections': {'paid_net': 900, 'pending_invoice_balance': 350},
    'operations': {'verified_cars_serviced': 2},
    'expenses': {'incurred_total': 100},
    'pnl': {
      'gross_profit': null,
      'inventory_cogs': null,
      'payroll_cost': null,
      'operating_expenses': null,
      'net_profit': null,
    },
    'payroll': {'period_complete': false},
    'commissions': [
      {
        'full_name': 'أحمد محمد',
        'cars_serviced': 2,
        'completed_services': 3,
        'commission_earned': 90,
        'commission_paid': 30,
        'commission_remaining': 60,
      },
      {
        'full_name': 'QA Worker',
        'cars_serviced': 1,
        'completed_services': 1,
        'commission_earned': 20,
        'commission_paid': null,
        'commission_remaining': null,
      },
    ],
  };
  final expenseContext = {
    'expenses': [
      {
        'expense_date': '2026-11-18',
        'category': 'utilities',
        'custom_category': 'كهرباء ومياه',
        'amount': 100,
        'status': 'paid',
        'due_date': '2026-11-18',
      },
    ],
  };
  final out = Directory('build/staging/pdf-review')..createSync(recursive: true);
  for (final arabic in [true, false]) {
    final bytes = await buildOwnerFinancePdf(
      report: report,
      expenseContext: expenseContext,
      branch: 'فرع QA / QA Branch',
      from: DateTime(2026, 11, 1),
      to: DateTime(2026, 11, 18),
      fontBytes: font,
      logoBytes: logo,
      arabic: arabic,
    );
    await File('${out.path}/owner-finance-${arabic ? 'ar' : 'en'}.pdf')
        .writeAsBytes(bytes);
  }
}
