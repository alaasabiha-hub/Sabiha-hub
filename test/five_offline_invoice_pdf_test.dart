import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  final input = Platform.environment['SABIHA_FIVE_DOCUMENTS'];
  final output = Platform.environment['SABIHA_FIVE_PDFS'];
  if (input == null || output == null) {
    test('QA documents required', () {}, skip: true);
    return;
  }
  final docs = jsonDecode(File(input).readAsStringSync()) as List;
  final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync();
  final logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
  for (var i = 0; i < docs.length; i++) {
    for (final ar in [true, false]) {
      for (final paper in ['A4', '58', '80']) {
        test('customer $i ${ar ? 'ar' : 'en'} $paper', () async {
          final doc = Map<String, dynamic>.from(docs[i] as Map);
          final before = jsonEncode(doc);
          final bytes = await buildInvoicePdf(
            doc,
            font,
            logo,
            paper: paper,
            arabic: ar,
          );
          expect(bytes.length, greaterThan(10000));
          expect(jsonEncode(doc), before);
          await Directory(output).create(recursive: true);
          await File('$output/customer-$i-${ar ? 'ar' : 'en'}-$paper.pdf')
              .writeAsBytes(bytes);
        });
      }
    }
  }
}
