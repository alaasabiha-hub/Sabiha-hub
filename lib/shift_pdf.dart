import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> buildShiftPdf(
  Map<String, dynamic> t,
  String branch,
  Uint8List fontBytes,
  Uint8List logoBytes,
) async {
  final document = pw.Document(
    title: 'Sabiha Hub - Cashier shift',
    author: 'Sabiha Hub',
  );
  final arabic = pw.Font.ttf(fontBytes.buffer.asByteData());
  final latin = pw.Font.helvetica();
  pw.Text ar(String value, {double size = 12}) => pw.Text(
    value,
    textDirection: pw.TextDirection.rtl,
    style: pw.TextStyle(font: arabic, fontSize: size),
  );
  pw.Text en(String value, {double size = 11}) => pw.Text(
    value,
    textDirection: pw.TextDirection.ltr,
    style: pw.TextStyle(font: latin, fontSize: size),
  );
  pw.Widget value(String value) =>
      RegExp(r'[\u0600-\u06ff]').hasMatch(value) ? ar(value) : en(value);
  final rows = [
    ['نقدية افتتاحية', 'Opening cash', '${t['opening_cash']} EGP'],
    ['صافي النقدي', 'Cash payments net', '${t['cash_payments_net']} EGP'],
    [
      'صافي الإلكتروني',
      'Electronic payments net',
      '${t['electronic_payments_net']} EGP',
    ],
    ['حركات نقدية', 'Cash movements net', '${t['cash_movements_net']} EGP'],
    ['نقدية متوقعة', 'Expected cash', '${t['expected_cash']} EGP'],
    ['نقدية فعلية', 'Actual cash', '${t['actual_cash'] ?? '-'} EGP'],
    ['فرق النقدية', 'Difference', '${t['difference'] ?? '-'} EGP'],
  ];
  final status = switch (t['status']) {
    'open' => ('مفتوحة', 'Open'),
    'awaiting_approval' => ('بانتظار اعتماد المالك', 'Awaiting owner approval'),
    'closed' => ('مغلقة ومعتمدة', 'Closed and approved'),
    _ => ('حالة غير معروفة', 'Unknown status'),
  };
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      textDirection: pw.TextDirection.ltr,
      build: (c) => [
        pw.Center(
          child: pw.Image(pw.MemoryImage(logoBytes), width: 200, height: 150),
        ),
        pw.SizedBox(height: 12),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: ar('تقرير وردية الكاشير', size: 20),
        ),
        en('Cashier shift report', size: 18),
        pw.Divider(),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [en('Branch'), value(branch)],
        ),
        ar('الحالة: ${status.$1}'),
        en('Status: ${status.$2}'),
        en('Shift: ${t['shift_id']}', size: 10),
        pw.SizedBox(height: 16),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(),
          },
          children: rows
              .map(
                (row) => pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(9),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [ar(row[0]), en(row[1])],
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(12),
                      child: en(row[2]),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
        pw.SizedBox(height: 18),
        pw.Align(alignment: pw.Alignment.centerRight, child: ar('سبب الفرق')),
        en('Difference reason'),
        value('${t['difference_reason'] ?? '-'}'),
        pw.SizedBox(height: 14),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: ar('نسخة محلية للاختبار', size: 10),
        ),
        en('Local test only', size: 10),
      ],
    ),
  );
  return document.save();
}
