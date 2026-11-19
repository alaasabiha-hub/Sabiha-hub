import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/report_exports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'from_local': '2026-11-01T00:00:00',
    'to_local': '2026-11-14T00:00:00',
    'branch_id': '=UNTRUSTED()',
    'as_of': '2026-11-13T12:00:00Z',
    'net_billed': 150.25,
    'billed_before_discount': 160.25,
    'discounts': 10,
    'invoice_count': 1,
    'taxes': null,
    'actual_profit': null,
    'cash_activity': {'collections': 150.25, 'refunds': 0},
    'hourly': [
      {
        'hour': 10,
        'net_billed': 150.25,
        'refunded_invoice_value': 0,
        'completed_service_visits': 2,
      },
    ],
  };
  test('Unpaid credits have separate export metrics and reconciliation', () {
    final credits = {
      ...report,
      'contains_reviewed_cashier': true,
      'unpaid_credits_are_not_cash_refunds': true,
      'unpaid_service_credits': 102.6,
      'unpaid_credit_tax': 12.6,
    };
    expect(
      reportMetrics(credits).any((m) => m.$1 == 'unpaid_service_credits'),
      true,
    );
    expect(
      reportMetrics(credits).any((m) => m.$1 == 'unpaid_credit_tax'),
      true,
    );
    expect(salesReportEquation(credits), contains('- unpaid service credits'));
    expect(
      salesReportEquation(credits, arabic: true),
      contains('تسويات الخدمات غير المدفوعة'),
    );
    expect(
      salesReportEquation(report),
      isNot(contains('unpaid service credits')),
    );
    final archive = ZipDecoder().decodeBytes(buildSalesReportWorkbook(credits));
    final sheet = utf8.decode(
      archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
    );
    expect(sheet, contains('Unpaid service credits'));
    expect(sheet, contains('Tax included in credits'));
  });
  test(
    'Reviewed metrics retain subcent precision and hide unauthorized costs',
    () {
      final cashier = {
        ...report,
        'contains_reviewed_cashier': true,
        'discount_tax_effect_recorded': 4.3,
        'cashier_refunds_on_active_invoices': 102.6,
        'cashier_payable_rounding': 0.00001,
        'commissions': null,
        'cashier_commissions_earned_in_period': null,
      };
      expect(reportMetrics(cashier).any((m) => m.$1 == 'commissions'), false);
      expect(
        reportMetrics(cashier)
            .any((m) => m.$1 == 'cashier_commissions_earned_in_period'),
        false,
      );
      expect(
        reportMetrics({...cashier, 'commissions': 60})
            .any((m) => m.$1 == 'commissions'),
        true,
      );
      expect(reportValue(0.00001), '0.00001');
      expect(reportValue(double.nan), 'Not recorded / incomplete');
      expect(reportValue(double.infinity), 'Not recorded / incomplete');
      final archive = ZipDecoder().decodeBytes(
        buildSalesReportWorkbook(cashier),
      );
      final sheet = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(sheet, contains('Recorded discount tax effect'));
      expect(sheet, contains('Refunds on active invoices'));
      expect(sheet, isNot(contains('Earned service commissions')));
    },
  );
  test(
    'Mixed refund exports explain net reconciliation without changing legacy',
    () {
      final mixed = {...report, 'contains_reviewed_cashier': true};
      expect(salesReportEquation(mixed), contains('discount tax effect'));
      expect(salesReportEquation(mixed), contains('active invoice refunds'));
      expect(salesReportEquation(mixed, arabic: true), contains('الاستردادات'));
      expect(
        salesReportEquation(report),
        'Before discount - discounts = net invoice value',
      );
      final archive = ZipDecoder().decodeBytes(buildSalesReportWorkbook(mixed));
      final sheet = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(sheet, contains(salesReportEquation(mixed)));
      expect(sheet, contains(salesReportEquation(mixed, arabic: true)));
    },
  );
  test(
    'Excel preserves numeric values, explicit unknowns and labels as strings',
    () {
      final raw = buildSalesReportWorkbook(report, rtl: true);
      final archive = ZipDecoder().decodeBytes(raw);
      final sheet = utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      );
      expect(sheet, contains('<v>150.25</v>'));
      expect(sheet, contains('Not recorded / incomplete'));
      expect(sheet, contains('t="inlineStr"'));
      expect(sheet, contains('=UNTRUSTED()'));
      expect(sheet, isNot(contains('<f>')));
      expect(sheet, contains('rightToLeft="1"'));
      expect(archive.findFile('xl/worksheets/sheet2.xml'), isNotNull);
      final hourly = utf8.decode(
        archive.findFile('xl/worksheets/sheet2.xml')!.content as List<int>,
      );
      expect(hourly, contains('Verified completed visits'));
      expect(hourly, contains('<v>2</v>'));
    },
  );
  test(
    'Excel includes comparable period totals in a separate bilingual sheet',
    () {
      final comparable = {
        ...report,
        'period_comparison': {
          'from_local': '2026-10-18',
          'to_local': '2026-11-01',
          'metrics': [
            {
              'key': 'net_billed',
              'current': 150.25,
              'previous': 120.0,
              'change': 30.25,
              'change_percent': 25.2083,
            },
            {
              'key': 'actual_profit',
              'current': null,
              'previous': null,
              'change': null,
              'change_percent': null,
            },
          ],
        },
      };
      final archive = ZipDecoder().decodeBytes(
        buildSalesReportWorkbook(comparable),
      );
      final workbook = utf8.decode(
        archive.findFile('xl/workbook.xml')!.content as List<int>,
      );
      expect(workbook, contains('Period comparison'));
      final sheet = utf8.decode(
        archive.findFile('xl/worksheets/sheet3.xml')!.content as List<int>,
      );
      expect(sheet, contains('صافي الفواتير'));
      expect(sheet, contains('Net billed'));
      expect(sheet, contains('<v>30.25</v>'));
      expect(sheet, contains('Not recorded / incomplete'));
      expect(sheet, contains('غير مسجل / غير مكتمل'));
    },
  );
  test('Admin export includes filtered invoice, payment and settlement datasets safely', () {
    final exported = {
      ...report,
      'filters': {'service': '=LABEL()'},
      'invoices': [
        {'invoice_id': 'INV-1', 'total': 150.25, 'service_name': '=LABEL()'},
      ],
      'payment_events': [
        {'invoice_id': 'INV-1', 'method': 'cash', 'amount': 150.25},
      ],
      'shifts': [],
      'bookings': [],
    };
    final archive = ZipDecoder().decodeBytes(
      buildSalesReportWorkbook(exported),
    );
    final workbook = utf8.decode(
      archive.findFile('xl/workbook.xml')!.content as List<int>,
    );
    expect(workbook, contains('Payment events'));
    expect(workbook, contains('Cashier settlements'));
    final invoiceSheet = utf8.decode(
      archive.findFile('xl/worksheets/sheet3.xml')!.content as List<int>,
    );
    expect(invoiceSheet, contains('INV-1'));
    expect(invoiceSheet, contains('<v>150.25</v>'));
    expect(invoiceSheet, isNot(contains('<f>')));
    final relations = utf8.decode(
      archive.findFile('xl/_rels/workbook.xml.rels')!.content as List<int>,
    );
    expect(relations, contains('rId7'));
    expect(archive.findFile('xl/worksheets/sheet6.xml'), isNotNull);
  });
  test('PDF uses original logo/font and produces a real A4 document', () async {
    final bytes = await buildSalesReportPdf(
      report,
      (await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf')).buffer
          .asUint8List(),
      (await rootBundle.load('assets/sabiha_brand_approved.png')).buffer
          .asUint8List(),
    );
    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(10000));
  });
  test(
    'optional real local report artifacts for independent PDF/Excel validation',
    () async {
      final report = Map<String, dynamic>.from(
        jsonDecode(
          File(Platform.environment['REPORT_FIXTURE']!).readAsStringSync(),
        ) as Map,
      );
      final folder = Directory(Platform.environment['REPORT_ARTIFACT_DIR']!);
      folder.createSync(recursive: true);
      File('${folder.path}/flutter-sales-window.xlsx')
          .writeAsBytesSync(buildSalesReportWorkbook(report, rtl: true));
      File('${folder.path}/flutter-sales-window.pdf').writeAsBytesSync(
        await buildSalesReportPdf(
          report,
          (await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf')).buffer
              .asUint8List(),
          (await rootBundle.load('assets/sabiha_brand_approved.png')).buffer
              .asUint8List(),
        ),
      );
    },
    skip:
        Platform.environment['REPORT_ARTIFACT_DIR'] == null ||
        Platform.environment['REPORT_FIXTURE'] == null,
  );
}
