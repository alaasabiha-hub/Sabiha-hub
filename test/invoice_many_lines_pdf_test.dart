import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';

Map<String, dynamic> manyLineDocument() => {
  'invoice_id': 'QA-MULTILINE-ONLY',
  'display_number': 'SH-INV-900001',
  'document_token': '00000000-0000-4000-8000-000000009001',
  'portal_origin': 'http://127.0.0.1:8098',
  'issued_at': '2026-11-15T12:00:00Z',
  'payment_status': 'unpaid',
  'payment_method': 'cash_on_receipt',
  'service_status': 'received',
  'snapshot': {
    'branch': {'name_ar': 'اختبار معزول فقط', 'name_en': 'ISOLATED QA ONLY'},
    'lines': List.generate(500, (i) => {
      'name': 'ITEM-${(i+1).toString().padLeft(4, '0')} ${i.isEven ? 'خدمة اختبار' : 'منتج اختبار'}',
      'quantity': 3,
      'unit_price': '100.01',
      'subtotal': '300.03',
    }),
    'discount': '1500.15',
    'tax_amount': '7425.74',
    'total': '155940.59',
  },
};
void main() {
  for (final language in ['ar', 'en']) {
    for (final paper in ['A4', '58', '80']) {
      test('500 invoice lines $language $paper preserve complete printable document', () async {
        final doc = manyLineDocument();
        final bytes = await buildInvoicePdf(doc, File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(), File('assets/sabiha_brand_approved.png').readAsBytesSync(), paper: paper, arabic: language == 'ar');
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        final output = Platform.environment['SABIHA_MULTILINE_PDF_DIR'];
        if (output != null) {
          await Directory(output).create(recursive: true);
          await File('$output/invoice-500-$language-$paper.pdf').writeAsBytes(bytes);
        }
        expect(doc['snapshot']['lines'].length, 500);
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  }
}
