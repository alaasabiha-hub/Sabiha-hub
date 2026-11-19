import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const salesReportMetrics = [
  (
    'billed_before_discount',
    'قيمة الفواتير قبل الخصم شاملة الضريبة والرسوم',
    'Billed before discount (includes tax and fees)',
  ),
  ('discounts', 'الخصومات', 'Discounts'),
  ('taxes', 'الضرائب المسجلة', 'Recorded taxes'),
  ('fees', 'رسوم التوصيل المسجلة', 'Recorded delivery fees'),
  (
    'gross_sales_ex_tax',
    'إجمالي المبيعات دون الضريبة والرسوم',
    'Gross sales excluding tax and fees',
  ),
  (
    'net_sales_ex_tax',
    'صافي المبيعات دون الضريبة والرسوم',
    'Net sales excluding tax and fees',
  ),
  ('net_billed', 'صافي قيمة الفواتير النشطة', 'Net active invoice value'),
  ('invoice_count', 'الفواتير النشطة', 'Active invoices'),
  ('average_invoice', 'متوسط الفاتورة', 'Average invoice'),
  (
    'refunded_invoice_value',
    'قيمة الفواتير المستردة',
    'Refunded invoice value',
  ),
  (
    'uncollected_recorded',
    'غير المحصل حسب سجل الدفع',
    'Uncollected per payment ledger',
  ),
  ('actual_profit', 'الربح الفعلي', 'Actual profit'),
];
List<(String, String, String)> reportMetrics(Map<String, dynamic> report) => [
  ...salesReportMetrics,
  if (report['contains_reviewed_cashier'] == true) ...[
    (
      'discount_tax_effect_recorded',
      'أثر الخصم على الضريبة المسجلة',
      'Recorded discount tax effect',
    ),
    (
      'cashier_refunds_on_active_invoices',
      'استردادات الفواتير النشطة',
      'Refunds on active invoices',
    ),
    if (report['unpaid_credits_are_not_cash_refunds'] == true) ...[
      (
        'unpaid_service_credits',
        'تسويات الخدمات غير المدفوعة',
        'Unpaid service credits',
      ),
      ('unpaid_credit_tax', 'الضريبة ضمن التسويات', 'Tax included in credits'),
    ],
    ('cashier_payable_rounding', 'تقريب المبلغ المستحق', 'Payable rounding'),
    if (report['commissions'] is num)
      (
        'commissions',
        'عمولات الخدمات المكتملة للفواتير المحددة',
        'Earned service commissions for selected invoices',
      ),
    if (report['cashier_commissions_earned_in_period'] is num)
      (
        'cashier_commissions_earned_in_period',
        'عمولات مكتسبة حسب وقت الإكمال خلال الفترة',
        'Commissions earned by completion time in period',
      ),
  ],
];

String salesReportEquation(Map<String, dynamic> report, {bool arabic = false}) {
  if (report['unpaid_credits_are_not_cash_refunds'] == true) {
    return arabic
        ? 'قبل الخصم − الخصومات − أثر الخصم الضريبي − الاستردادات من الفواتير النشطة − تسويات الخدمات غير المدفوعة + التقريب = صافي قيمة الفواتير النشطة'
        : 'Before discount - discounts - discount tax effect - active invoice refunds - unpaid service credits + rounding = net active invoice value';
  }
  if (report['contains_reviewed_cashier'] == true) {
    return arabic
        ? 'قبل الخصم − الخصومات − أثر الخصم الضريبي − الاستردادات من الفواتير النشطة + التقريب = صافي قيمة الفواتير النشطة'
        : 'Before discount - discounts - discount tax effect - active invoice refunds + rounding = net active invoice value';
  }
  return arabic
      ? 'قبل الخصم ناقص الخصومات يساوي صافي قيمة الفواتير'
      : 'Before discount - discounts = net invoice value';
}

String reportValue(dynamic value) {
  if (value == null || (value is num && !value.isFinite)) {
    return 'Not recorded / incomplete';
  }
  if (value is num) {
    final rounded = num.parse(value.toStringAsFixed(2));
    return value.toStringAsFixed((value - rounded).abs() > 0.00000001 ? 5 : 2);
  }
  return '$value';
}

class ReportComparisonMetric {
  const ReportComparisonMetric(this.key, this.current, this.previous);
  final String key;
  final num? current;
  final num? previous;
  num? get change =>
      current == null || previous == null ? null : current! - previous!;
  num? get changePercent => change == null || previous == null || previous == 0
      ? null
      : change! / previous! * 100;
}

/// Compares only values recorded by the server. Missing financial snapshots
/// stay null; an absent expense list is not silently treated as zero.
List<ReportComparisonMetric> ownerPeriodComparison(
  Map<String, dynamic> current,
  Map<String, dynamic> previous,
) {
  Map<String, dynamic> summary(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(value['report'] as Map? ?? const {});
  num? number(dynamic value) => value is num && value.isFinite ? value : null;
  num? expenses(Map<String, dynamic> value) {
    final extra = value['extra'];
    if (extra is! Map || extra['expenses'] is! List) return null;
    final rows = extra['expenses'] as List;
    num total = 0;
    for (final row in rows) {
      if (row is! Map || number(row['amount']) == null) return null;
      total += row['amount'] as num;
    }
    return total;
  }

  final now = summary(current), before = summary(previous);
  return [
    ReportComparisonMetric(
      'net_billed',
      number(now['net_billed']),
      number(before['net_billed']),
    ),
    ReportComparisonMetric(
      'discounts',
      number(now['discounts']),
      number(before['discounts']),
    ),
    ReportComparisonMetric(
      'refunded_invoice_value',
      number(now['refunded_invoice_value']),
      number(before['refunded_invoice_value']),
    ),
    ReportComparisonMetric(
      'actual_profit',
      number(now['actual_profit']),
      number(before['actual_profit']),
    ),
    ReportComparisonMetric('expenses', expenses(current), expenses(previous)),
  ];
}

/// Immutable export of the server report. No payment, price or ledger mutation.
Future<Uint8List> buildSalesReportPdf(
  Map<String, dynamic> report,
  Uint8List fontBytes,
  Uint8List logoBytes,
) async {
  final document = pw.Document(
    title: 'Sabiha Hub Sales Summary',
    author: 'Sabiha Hub',
  );
  final arabic = pw.Font.ttf(fontBytes.buffer.asByteData());
  final latin = pw.Font.helvetica();
  pw.Widget ar(String text) => pw.Text(
    text,
    textDirection: pw.TextDirection.rtl,
    style: pw.TextStyle(font: arabic, fontFallback: [latin], fontSize: 10),
  );
  pw.Widget en(String text) => pw.Text(
    text,
    textDirection: pw.TextDirection.ltr,
    style: pw.TextStyle(font: latin, fontFallback: [arabic], fontSize: 9),
  );
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        pw.Center(
          child: pw.Image(pw.MemoryImage(logoBytes), width: 130, height: 106),
        ),
        pw.SizedBox(height: 12),
        ar('ملخص المبيعات'),
        en('Sabiha Hub Sales Summary - EGP - Africa/Cairo'),
        en('From (inclusive): ${report['from_local']}'),
        en('To (exclusive): ${report['to_local']}'),
        en('Branch: ${report['branch_id'] ?? 'All branches'}'),
        en('As of: ${report['as_of']}'),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(),
            2: const pw.FlexColumnWidth(2),
          },
          children: [
            for (final m in reportMetrics(report))
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: en(m.$3),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: en(reportValue(report[m.$1])),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: ar(m.$2),
                  ),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 12),
        ar(salesReportEquation(report, arabic: true)),
        en(salesReportEquation(report)),
        ar(
          'الربح الفعلي غير متاح قبل اكتمال تكاليف المنتجات والرواتب. القيم المفقودة لا تفترض صفرًا.',
        ),
        en(
          'Actual profit unavailable until costs and payroll are complete. Missing values are not zero.',
        ),
        en(
          'Payment activity is based on payment event time and may concern another invoice period.',
        ),
        ar('عدد الزيارات المكتملة يعتمد على انتهاء خدمة موثق؛ لا يستنتج من وقت إصدار الفاتورة.'),
        en('Completed visit counts require a recorded service completion; invoice issue time is not used as a substitute.'),
        en(
          'Recorded collections: ${reportValue((report['cash_activity'] as Map?)?['collections'])} EGP',
        ),
        en(
          'Recorded refunds: ${reportValue((report['cash_activity'] as Map?)?['refunds'])} EGP',
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: [
            'Hour (Cairo)',
            'Active invoices EGP',
            'Refunded invoices EGP',
            'Verified completed visits',
          ],
          data: [
            for (final r in report['hourly'] as List? ?? [])
              [
                '${r['hour']}',
                reportValue(r['net_billed']),
                reportValue(r['refunded_invoice_value']),
                reportValue(r['completed_service_visits']),
              ],
          ],
          cellStyle: pw.TextStyle(
            font: latin,
            fontFallback: [arabic],
            fontSize: 9,
          ),
          headerStyle: pw.TextStyle(
            font: latin,
            fontSize: 9,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xff174b83),
          ),
        ),
        if (report['period_comparison'] is Map) ...[
          pw.SizedBox(height: 14),
          ar('مقارنة الفترة السابقة'),
          en('Equal-length previous period comparison'),
          en(
            'Previous period: ${(report['period_comparison'] as Map)['from_local']} to ${(report['period_comparison'] as Map)['to_local']}',
          ),
          pw.TableHelper.fromTextArray(
            headers: ['Metric', 'Current', 'Previous', 'Change'],
            data: [
              for (final row
                  in (report['period_comparison'] as Map)['metrics'] as List)
                [
                  switch (row['key']) {
                    'net_billed' => 'Net billed / صافي الفواتير',
                    'discounts' => 'Discounts / الخصومات',
                    'refunded_invoice_value' => 'Refunded / المرتجعات',
                    'expenses' => 'Expenses / المصروفات',
                    _ => 'Actual profit / الربح الفعلي',
                  },
                  reportValue(row['current']),
                  reportValue(row['previous']),
                  reportValue(row['change']),
                ],
            ],
            cellStyle: pw.TextStyle(
              font: latin,
              fontFallback: [arabic],
              fontSize: 8,
            ),
            headerStyle: pw.TextStyle(
              font: latin,
              fontSize: 8,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xff174b83),
            ),
          ),
          ar('المقارنة وصفية؛ البيانات غير المتاحة لا تُعامل كصفر.'),
          en(
            'Comparison is descriptive; unavailable values are not treated as zero.',
          ),
        ],
        if (report['filters'] != null)
          en('Filters: ${jsonEncode(report['filters'])}'),
        for (final spec in const [
          (
            'invoices',
            'Invoice history',
            ['invoice_id', 'service_name', 'status', 'total', 'discount'],
          ),
          (
            'payment_events',
            'Payment events (collection time)',
            ['invoice_id', 'method', 'event_type', 'amount', 'created_at'],
          ),
          (
            'shifts',
            'Cashier settlements',
            [
              'shift_id',
              'status',
              'expected_cash',
              'actual_cash',
              'difference',
            ],
          ),
          (
            'bookings',
            'Bookings',
            ['service_name', 'booking_date', 'booking_time', 'status'],
          ),
        ])
          if ((report[spec.$1] as List? ?? []).isNotEmpty) ...[
            pw.SizedBox(height: 18),
            en(spec.$2),
            pw.TableHelper.fromTextArray(
              headers: spec.$3,
              data: [
                for (final row in report[spec.$1] as List)
                  [
                    for (final field in spec.$3)
                      reportValue(
                        field == 'invoice_id'
                            ? row['invoice_number'] ?? row[field]
                            : row[field],
                      ),
                  ],
              ],
              cellStyle: pw.TextStyle(
                font: latin,
                fontFallback: [arabic],
                fontSize: 8,
              ),
              headerStyle: pw.TextStyle(
                font: latin,
                fontSize: 8,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xff1952a0),
              ),
            ),
          ],
      ],
    ),
  );
  return document.save();
}

/// Standard OOXML, using inline strings so untrusted labels can never become formulas.
Uint8List buildSalesReportWorkbook(
  Map<String, dynamic> report, {
  bool rtl = false,
}) {
  final archive = Archive();
  void add(String path, String value) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  String xml(Object? value) =>
      const HtmlEscape(HtmlEscapeMode.element)
          .convert('${value ?? ''}')
          .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
  const ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  final summaries = <List<Object?>>[
    ['English', 'القيمة / Value', 'العربية'],
    ['From (inclusive)', report['from_local'], 'من (مشمول)'],
    ['To (exclusive)', report['to_local'], 'إلى (غير مشمول)'],
    ['Time zone', 'Africa/Cairo', 'التوقيت'],
    ['Currency', 'EGP', 'العملة'],
    ['Branch', report['branch_id'] ?? 'All branches', 'الفرع'],
    ['As of', report['as_of'], 'وقت الاستخراج'],
    for (final m in reportMetrics(report))
      [m.$3, report[m.$1] ?? 'Not recorded / incomplete', m.$2],
    [
      'Basis',
      'Invoice issue time; current status',
      'وقت الإصدار والحالة الحالية',
    ],
    [
      'Equation',
      salesReportEquation(report),
      salesReportEquation(report, arabic: true),
    ],
    [
      'Profit',
      'Unavailable until costs and payroll are complete',
      'غير متاح قبل اكتمال التكاليف والرواتب',
    ],
    [
      'Cash event basis',
      'Payment event time; may concern invoices outside issue window',
      'حسب وقت حركة الدفع',
    ],
    [
      'Completed visit basis',
      'Verified physical service completion time only',
      'وقت انتهاء الخدمة الموثق فقط',
    ],
    [
      'Recorded collections',
      (report['cash_activity'] as Map?)?['collections'] ?? 'Not recorded',
      'التحصيل المسجل',
    ],
    [
      'Recorded refunds',
      (report['cash_activity'] as Map?)?['refunds'] ?? 'Not recorded',
      'الاسترداد المسجل',
    ],
  ];
  final sheets = [
    summaries,
    <List<Object?>>[
      [
        'Hour (Cairo)',
        'Active invoices EGP',
        'Refunded invoices EGP',
        'Verified completed visits',
      ],
      for (final row in report['hourly'] as List? ?? [])
        [
          row['hour'],
          row['net_billed'],
          row['refunded_invoice_value'],
          row['completed_service_visits'],
        ],
    ],
  ];
  final sheetNames = ['Summary', 'Hourly sales'];
  if (report['period_comparison'] is Map) {
    final comparison = report['period_comparison'] as Map;
    summaries.add([
      'Previous period',
      '${comparison['from_local']} — ${comparison['to_local']}',
      'الفترة السابقة',
    ]);
    final rows = comparison['metrics'] as List? ?? const [];
    sheets.add(<List<Object?>>[
      [
        'Metric',
        'Current',
        'Previous',
        'Change',
        'Change %',
        'المؤشر',
        'الحالي',
        'السابق',
        'التغير',
        'نسبة التغير',
      ],
      for (final row in rows)
        [
          switch (row['key']) {
            'net_billed' => 'Net billed',
            'discounts' => 'Discounts',
            'refunded_invoice_value' => 'Refunded invoice value',
            'expenses' => 'Recorded expenses',
            _ => 'Actual profit',
          },
          row['current'] ?? 'Not recorded / incomplete',
          row['previous'] ?? 'Not recorded / incomplete',
          row['change'] ?? 'Not recorded / incomplete',
          row['change_percent'] ?? 'Not available',
          switch (row['key']) {
            'net_billed' => 'صافي الفواتير',
            'discounts' => 'الخصومات',
            'refunded_invoice_value' => 'قيمة الفواتير المستردة',
            'expenses' => 'المصروفات المسجلة',
            _ => 'الربح الفعلي',
          },
          row['current'] ?? 'غير مسجل / غير مكتمل',
          row['previous'] ?? 'غير مسجل / غير مكتمل',
          row['change'] ?? 'غير مسجل / غير مكتمل',
          row['change_percent'] ?? 'غير متاح',
        ],
    ]);
    sheetNames.add('Period comparison');
  }
  for (final spec in const [
    (
      'invoices',
      'Invoices',
      [
        'invoice_id',
        'service_name',
        'issued_at',
        'status',
        'total',
        'discount',
      ],
    ),
    (
      'payment_events',
      'Payment events',
      ['invoice_id', 'method', 'event_type', 'amount', 'created_at'],
    ),
    (
      'shifts',
      'Cashier settlements',
      ['shift_id', 'status', 'expected_cash', 'actual_cash', 'difference'],
    ),
    (
      'bookings',
      'Bookings',
      ['service_name', 'booking_date', 'booking_time', 'status'],
    ),
  ]) {
    if (report.containsKey(spec.$1)) {
      sheetNames.add(spec.$2);
      sheets.add(<List<Object?>>[
        spec.$3,
        for (final row in report[spec.$1] as List? ?? [])
          [
            for (final f in spec.$3)
              (f == 'invoice_id' ? row['invoice_number'] ?? row[f] : row[f]) ??
                  'Not recorded',
          ],
      ]);
    }
  }
  if (report['filters'] != null) {
    summaries.add(['Filters', jsonEncode(report['filters']), 'التصفية']);
  }
  add(
    '[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${[for (var i = 1; i <= sheets.length; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}</Types>',
  );
  add(
    '_rels/.rels',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
  );
  add(
    'xl/workbook.xml',
    '<workbook xmlns="$ns" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${[for (var i = 0; i < sheetNames.length; i++) '<sheet name="${sheetNames[i]}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${[for (var i = 1; i <= sheets.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
  );
  add(
    'xl/styles.xml',
    '<styleSheet xmlns="$ns"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF174B83"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment wrapText="1" vertical="top"/></xf><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1" applyFont="1"><alignment wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
  );
  for (var sheet = 0; sheet < sheets.length; sheet++) {
    final rows = sheets[sheet];
    final data = StringBuffer();
    for (var r = 0; r < rows.length; r++) {
      data.write('<row r="${r + 1}" ht="32" customHeight="1">');
      for (var c = 0; c < rows[r].length; c++) {
        final value = rows[r][c];
        final ref = '${String.fromCharCode(65 + c)}${r + 1}';
        if (value is num && value.isFinite) {
          data.write('<c r="$ref" s="${r == 0 ? 2 : 1}"><v>$value</v></c>');
        } else {
          data.write(
            '<c r="$ref" t="inlineStr" s="${r == 0 ? 2 : 0}"><is><t xml:space="preserve">${xml(value)}</t></is></c>',
          );
        }
      }
      data.write('</row>');
    }
    add(
      'xl/worksheets/sheet${sheet + 1}.xml',
      '<worksheet xmlns="$ns"><sheetViews><sheetView workbookViewId="0" rightToLeft="${rtl ? 1 : 0}"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="52" customWidth="1"/><col min="2" max="2" width="60" customWidth="1"/><col min="3" max="3" width="55" customWidth="1"/></cols><sheetData>$data</sheetData></worksheet>',
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
