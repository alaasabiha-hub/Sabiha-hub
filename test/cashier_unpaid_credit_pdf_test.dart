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
  for (final ar in [true, false]) {
    for (final paper in ['A4', '58', '80']) {
      test('unpaid credit annex ${ar ? 'ar' : 'en'} $paper', () async {
        final doc = Map<String, dynamic>.from(docs['unpaid_invoice'] as Map);
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
        await File('$output/credit-${ar ? 'ar' : 'en'}-$paper.pdf')
            .writeAsBytes(bytes);
      });
    }
  }
  test('credit annex rejects inconsistent amounts and missing tax', () async {
    for (final key in [
      'unpaid_credit_amount',
      'unpaid_credit_tax_amount_exact',
      'adjusted_invoice_total',
      'amount_outstanding',
    ]) {
      final doc = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(docs['unpaid_invoice'])) as Map,
      )..remove(key);
      await expectLater(
        buildInvoicePdf(doc, font, logo),
        throwsFormatException,
      );
    }
  });
  test('credit settlement states translated', () {
    expect(invoiceState('settled_by_credit', true), contains('تسويات'));
    expect(
      invoiceState('credit_settlement', false),
      'Credit settlement without collection',
    );
  });
}
