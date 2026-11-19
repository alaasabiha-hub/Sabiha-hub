import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_finance_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'owner finance PDF exports unavailable P&L without inventing profit',
    () async {
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildOwnerFinancePdf(
        report: {
          'time_zone': 'Africa/Cairo',
          'sales': {
            'billed_net_after_refunds': 1200,
            'revenue_ex_vat': 1052.63,
            'discounts': 50,
            'refunds': 0,
            'average_invoice': 600,
          },
          'collections': {'paid_net': 900, 'pending_invoice_balance': 300},
          'operations': {'verified_cars_serviced': 2},
          'commissions': [
            {
              'full_name': 'QA Worker',
              'cars_serviced': 2,
              'completed_services': 3,
              'commission_earned': 90,
              'commission_paid': null,
              'commission_remaining': null,
            },
          ],
          'payroll': {'period_complete': false},
          'expenses': {'incurred_total': 100},
          'pnl': {
            'gross_profit': null,
            'inventory_cogs': null,
            'payroll_cost': null,
            'operating_expenses': null,
            'net_profit': null,
          },
        },
        expenseContext: {
          'expenses': [
            {
              'expense_date': '2026-11-18',
              'category': 'utilities',
              'amount': 100,
              'status': 'paid',
            },
          ],
        },
        branch: 'qa-branch',
        from: DateTime(2026, 11, 18),
        to: DateTime(2026, 11, 18),
        fontBytes: font.buffer.asUint8List(),
        logoBytes: logo.buffer.asUint8List(),
        arabic: true,
      );

      expect(bytes.length, greaterThan(5000));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    },
  );
}
