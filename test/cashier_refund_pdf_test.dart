import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/invoice_presentation.dart';

void main() {
  final input = Platform.environment['SABIHA_REFUND_DOCUMENTS'];
  final output = Platform.environment['SABIHA_REFUND_PDF_OUTPUT'];
  if (input == null || output == null) {
    test(
      'isolated refund document fixtures required',
      () {},
      skip: 'Supply isolated SQL fixture and output paths',
    );
    return;
  }
  final docs = Map<String, dynamic>.from(
    jsonDecode(File(input).readAsStringSync()) as Map,
  );
  final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync();
  final logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
  for (final kind in ['partial_receipt', 'final_receipt']) {
    final ar = kind == 'partial_receipt';
    for (final paper in ['A4', '58', '80']) {
      test('actual SQL refund document $kind $paper', () async {
        final doc = Map<String, dynamic>.from(docs[kind] as Map);
        final before = jsonEncode(doc);
        final bytes = await buildInvoicePdf(
          doc,
          font,
          logo,
          paper: paper,
          arabic: ar,
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(jsonEncode(doc), before);
        await Directory(output).create(recursive: true);
        await File('$output/$kind-$paper.pdf').writeAsBytes(bytes);
      });
    }
  }
  for (final lang in ['ar', 'en']) {
    test('actual mixed original invoice with refund summary $lang', () async {
      final doc = Map<String, dynamic>.from(docs['partial_receipt'] as Map)
        ..remove('refund_receipt');
      final bytes = await buildInvoicePdf(
        doc,
        font,
        logo,
        paper: lang == 'ar' ? 'A4' : '58',
        arabic: lang == 'ar',
      );
      await Directory(output).create(recursive: true);
      await File('$output/mixed-original-$lang.pdf').writeAsBytes(bytes);
    });
  }
  test('partial status translated in both languages', () {
    expect(invoiceState('partially_refunded', true), 'مسترد جزئيًا');
    expect(invoiceState('partially_refunded', false), 'Partially refunded');
  });
  test(
    'malformed receipt cannot silently print zero or inconsistent totals',
    () async {
      for (final missing in ['amount', 'tax_amount_exact', 'discount_exact']) {
        final doc = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(docs['partial_receipt'])) as Map,
        );
        final receipt = doc['refund_receipt'] as Map;
        if (missing == 'amount') {
          receipt['amount'] = 46;
        } else {
          (receipt['lines'] as List).first.remove(missing);
        }
        await expectLater(
          buildInvoicePdf(doc, font, logo),
          throwsFormatException,
        );
      }
    },
  );
}
