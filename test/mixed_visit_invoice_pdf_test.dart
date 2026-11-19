import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  final input = Platform.environment['SABIHA_VISIT_DOCUMENT'];
  final output = Platform.environment['SABIHA_VISIT_PDF_OUTPUT'];
  if (input == null || output == null) {
    test(
      'isolated visit invoice fixture required',
      () {},
      skip: 'Supply isolated server document and private PDF output paths',
    );
    return;
  }
  final doc = Map<String, dynamic>.from(
    jsonDecode(File(input).readAsStringSync()) as Map,
  );
  final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync();
  final logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
  for (final ar in [true, false]) {
    for (final paper in ['A4', '58', '80']) {
      test('actual visit reward invoice ${ar ? 'ar' : 'en'} $paper', () async {
        expect(
          (doc['snapshot'] as Map)['visit_loyalty']['unit'],
          'service_visits',
        );
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
        await File('$output/visit-${ar ? 'ar' : 'en'}-$paper.pdf')
            .writeAsBytes(bytes);
      });
    }
  }
}
