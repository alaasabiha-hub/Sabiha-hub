import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Builds a read-only owner finance export from the server snapshot.
/// Unknown costs and payout states remain explicitly unavailable.
Future<Uint8List> buildOwnerFinancePdf({
  required Map<String, dynamic> report,
  required Map<String, dynamic>? expenseContext,
  required String branch,
  required DateTime from,
  required DateTime to,
  required Uint8List fontBytes,
  required Uint8List logoBytes,
  required bool arabic,
}) async {
  final doc = pw.Document(
    title: 'Sabiha Hub Owner Finance Report',
    author: 'Sabiha Hub',
  );
  final arFont = pw.Font.ttf(fontBytes.buffer.asByteData());
  final enFont = pw.Font.helvetica();
  final sales = Map<String, dynamic>.from(report['sales'] as Map? ?? {});
  final collections = Map<String, dynamic>.from(
    report['collections'] as Map? ?? {},
  );
  final operations = Map<String, dynamic>.from(
    report['operations'] as Map? ?? {},
  );
  final expenses = Map<String, dynamic>.from(report['expenses'] as Map? ?? {});
  final pnl = Map<String, dynamic>.from(report['pnl'] as Map? ?? {});
  final payroll = Map<String, dynamic>.from(report['payroll'] as Map? ?? {});
  List<Map<String, dynamic>> rows(dynamic value) => (value as List? ?? [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  String fmt(dynamic value) {
    if (value is! num || !value.isFinite) {
      return arabic ? 'غير متاح' : 'Unavailable';
    }
    return '${value.toStringAsFixed(2)} EGP';
  }

  String date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  pw.Widget label(String ar, String en) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Text(
        ar,
        textDirection: pw.TextDirection.rtl,
        style: pw.TextStyle(font: arFont, fontFallback: [enFont], fontSize: 9),
      ),
      pw.Text(
        en,
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(font: enFont, fontFallback: [arFont], fontSize: 8),
      ),
    ],
  );
  pw.Widget value(dynamic v) {
    final text = fmt(v);
    final isArabicValue = v is! num && arabic;
    return pw.Text(
      text,
      textDirection: isArabicValue
          ? pw.TextDirection.rtl
          : pw.TextDirection.ltr,
      style: pw.TextStyle(
        font: isArabicValue ? arFont : enFont,
        fontFallback: [arFont, enFont],
        fontSize: 9,
      ),
    );
  }

  final arabicChars = RegExp(r'[\u0600-\u06ff]');
  pw.Widget tableCell(String text, {bool header = false}) {
    final hasArabic = arabicChars.hasMatch(text);
    return pw.Container(
      alignment: hasArabic ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      child: pw.Text(
        text,
        textDirection: hasArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        style: pw.TextStyle(
          font: hasArabic ? arFont : enFont,
          fontFallback: [arFont, enFont],
          fontSize: 8,
          color: header ? PdfColors.white : PdfColors.black,
        ),
      ),
    );
  }

  pw.Widget tableHeader(String ar, String en) => pw.Container(
    alignment: pw.Alignment.center,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          ar,
          textAlign: pw.TextAlign.center,
          textDirection: pw.TextDirection.rtl,
          style: pw.TextStyle(
            font: arFont,
            fontSize: 8,
            color: PdfColors.white,
          ),
        ),
        pw.Text(
          en,
          textAlign: pw.TextAlign.center,
          textDirection: pw.TextDirection.ltr,
          style: pw.TextStyle(
            font: enFont,
            fontSize: 7,
            color: PdfColors.white,
          ),
        ),
      ],
    ),
  );
  pw.Widget detailTable(
    List<(String, String)> headers,
    List<List<String>> data,
  ) => pw.Table(
    border: pw.TableBorder.all(color: PdfColors.grey400),
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff174b83)),
        children: [for (final h in headers) tableHeader(h.$1, h.$2)],
      ),
      for (final row in data)
        pw.TableRow(children: [for (final cell in row) tableCell(cell)]),
    ],
  );
  final tableRows = <pw.TableRow>[];
  void add(String ar, String en, dynamic v) => tableRows.add(
    pw.TableRow(
      children: [
        pw.Padding(padding: const pw.EdgeInsets.all(6), child: label(ar, en)),
        pw.Padding(padding: const pw.EdgeInsets.all(6), child: value(v)),
      ],
    ),
  );
  add(
    'صافي قيمة الفواتير بعد المرتجعات',
    'Billed net after refunds',
    sales['billed_net_after_refunds'],
  );
  add('الخصومات', 'Discounts', sales['discounts']);
  add('المرتجعات', 'Refunds', sales['refunds']);
  add(
    'الإيراد دون ضريبة القيمة المضافة',
    'Revenue excluding VAT',
    sales['revenue_ex_vat'],
  );
  add(
    'التحصيل الفعلي المسجل',
    'Actual recorded collections',
    collections['paid_net'],
  );
  add(
    'الرصيد المعلق',
    'Pending balance',
    collections['pending_invoice_balance'],
  );
  add('متوسط الفاتورة', 'Average invoice', sales['average_invoice']);
  add(
    'السيارات ذات الخدمة المكتملة الموثقة',
    'Verified completed cars',
    operations['verified_cars_serviced'],
  );
  add(
    'المصروفات المسجلة للفترة',
    'Recorded expenses for period',
    expenses['incurred_total'],
  );
  add('الربح الصافي', 'Net profit', pnl['net_profit']);

  final commissions = rows(report['commissions']);
  final expenseRows = rows(expenseContext?['expenses']);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      build: (_) => [
        pw.Center(
          child: pw.Image(pw.MemoryImage(logoBytes), width: 118, height: 94),
        ),
        pw.SizedBox(height: 8),
        label(
          'التقرير المالي والتشغيلي للمالك',
          'Owner finance & operations report',
        ),
        pw.Text(
          'Sabiha Hub | EGP | ${report['time_zone'] ?? 'Africa/Cairo'}',
          style: pw.TextStyle(
            font: enFont,
            fontFallback: [arFont],
            fontSize: 9,
          ),
        ),
        label(
          branch.isEmpty
              ? 'يشمل التقرير جميع الفروع المصرح بها.'
              : 'يشمل التقرير الفرع المحدد.',
          'Period: ${date(from)} - ${date(to)} | Branch: $branch',
        ),
        pw.Text(
          'Snapshot: ${report['as_of'] ?? 'server snapshot'}',
          style: pw.TextStyle(
            font: enFont,
            fontFallback: [arFont],
            fontSize: 8,
          ),
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(),
          },
          children: tableRows,
        ),
        pw.SizedBox(height: 12),
        label(
          'عمولات الخدمات المكتملة حسب الموظف',
          'Completed-service commissions by employee',
        ),
        if (commissions.isEmpty)
          label(
            'لا توجد عمولات مكتملة مسجلة',
            'No recorded completed-service commissions',
          )
        else
          detailTable(
            [
              ('الموظف', 'Employee'),
              ('السيارات', 'Cars'),
              ('الخدمات', 'Services'),
              ('العمولة المستحقة', 'Earned EGP'),
              ('المدفوع والمتبقي', 'Paid and remaining'),
            ],
            [
              for (final row in commissions)
                [
                  '${row['full_name'] ?? 'Staff'}',
                  '${row['cars_serviced'] ?? 0}',
                  '${row['completed_services'] ?? 0}',
                  fmt(row['commission_earned']),
                  '${fmt(row['commission_paid'])} · ${fmt(row['commission_remaining'])}',
                ],
            ],
          ),
        pw.SizedBox(height: 10),
        label(
          'الرواتب المعتمدة - عناصر منفصلة',
          'Approved payroll - separate components',
        ),
        for (final pair in [
          ('الأجر الأساسي', 'Base pay', 'base_earned'),
          (
            'العمولة داخل المسير',
            'Commission in snapshot',
            'commission_earned',
          ),
          ('المكافآت', 'Bonuses', 'bonuses'),
          ('السلف', 'Advances', 'advances'),
          ('الخصومات', 'Deductions', 'deductions'),
          ('صافي المسير', 'Payroll net snapshot', 'net_snapshot'),
        ])
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(child: label(pair.$1, pair.$2)),
                pw.SizedBox(width: 12),
                value(payroll[pair.$3]),
              ],
            ),
          ),
        pw.SizedBox(height: 10),
        label('تفاصيل المصروفات الجديدة', 'Managed expense details'),
        if (expenseRows.isEmpty)
          label('لا توجد مصروفات مسجلة', 'No expense rows')
        else
          detailTable(
            [
              ('التاريخ', 'Date'),
              ('التصنيف', 'Category'),
              ('المبلغ جنيه', 'Amount EGP'),
              ('الحالة', 'Status'),
              ('الاستحقاق', 'Due'),
            ],
            [
              for (final row in expenseRows)
                [
                  '${row['expense_date'] ?? ''}',
                  '${row['custom_category'] ?? row['category'] ?? ''}',
                  fmt(row['amount']),
                  '${row['status'] ?? 'unknown'}',
                  '${row['due_date'] ?? ''}',
                ],
            ],
          ),
        pw.SizedBox(height: 12),
        label('قائمة الأرباح والخسائر', 'Profit & loss statement'),
        for (final pair in [
          ('إجمالي الربح', 'Gross profit', 'gross_profit'),
          (
            'تكلفة المخزون والخدمات',
            'Inventory and service costs',
            'inventory_cogs',
          ),
          ('تكلفة الرواتب', 'Payroll cost', 'payroll_cost'),
          ('المصروفات التشغيلية', 'Operating expenses', 'operating_expenses'),
        ])
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(child: label(pair.$1, pair.$2)),
                pw.SizedBox(width: 12),
                value(pnl[pair.$3]),
              ],
            ),
          ),
        label(
          'لا يُعرض صافي ربح عند نقص تكاليف المخزون أو الخدمات أو توزيع المصروفات على الفترة. التحصيل النقدي منفصل عن الاستحقاق المحاسبي.',
          'Net profit is withheld when inventory/service costs or period allocations are incomplete. Cash collection is distinct from accrual accounting.',
        ),
        if (arabic)
          pw.Text(
            'هذا التقرير قراءة فقط من بيانات QA؛ لم تُنشأ أي معاملة مالية.',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              font: arFont,
              fontFallback: [enFont],
              fontSize: 8,
            ),
          ),
        if (!arabic)
          pw.Text(
            'Read-only QA snapshot. No financial transaction was created.',
            style: pw.TextStyle(
              font: enFont,
              fontFallback: [arFont],
              fontSize: 8,
            ),
          ),
      ],
    ),
  );
  return doc.save();
}
