import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/report_exports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('period comparison preserves unknown profit and calculates recorded expenses', () {
    final current = {
      'report': {
        'net_billed': 100,
        'discounts': 10,
        'refunded_invoice_value': 0,
        'actual_profit': null,
      },
      'extra': {'expenses': <Map<String, dynamic>>[]},
    };
    final previous = {
      'report': {
        'net_billed': 80,
        'discounts': 5,
        'refunded_invoice_value': 20,
        'actual_profit': null,
      },
      'extra': {
        'expenses': [
          {'amount': 2.5},
        ],
      },
    };

    final rows = ownerPeriodComparison(current, previous);
    expect(rows.firstWhere((row) => row.key == 'net_billed').change, 20);
    expect(rows.firstWhere((row) => row.key == 'net_billed').changePercent, 25);
    expect(rows.firstWhere((row) => row.key == 'expenses').current, 0);
    expect(rows.firstWhere((row) => row.key == 'expenses').change, -2.5);
    expect(rows.firstWhere((row) => row.key == 'actual_profit').change, isNull);
  });

  test(
    'sales PDF generation accepts a previous period comparison snapshot',
    () async {
      final font = (await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf'))
          .buffer
          .asUint8List();
      final logo = (await rootBundle.load('assets/sabiha_brand_approved.png'))
          .buffer
          .asUint8List();
      final bytes = await buildSalesReportPdf(
        {
          'from_local': '2026-11-16',
          'to_local': '2026-11-17',
          'branch_id': null,
          'hourly': <Map<String, dynamic>>[],
          'cash_activity': <String, dynamic>{},
          'period_comparison': {
            'from_local': '2026-11-15',
            'to_local': '2026-11-16',
            'metrics': [
              {
                'key': 'net_billed',
                'current': 100,
                'previous': 80,
                'change': 20,
              },
              {
                'key': 'actual_profit',
                'current': null,
                'previous': null,
                'change': null,
              },
            ],
          },
        },
        font,
        logo,
      );

      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    },
  );
}
