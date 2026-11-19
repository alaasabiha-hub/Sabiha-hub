import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/invoice_presentation.dart';

void main() {
  final input = Platform.environment['SABIHA_ZERO_VISIT_DOCUMENT'];
  final output = Platform.environment['SABIHA_ZERO_VISIT_PDF_OUTPUT'];
  if (input == null || output == null) {
    test(
      'isolated zero visit fixture required',
      () {},
      skip: 'Supply actual isolated server document paths',
    );
    return;
  }
  final doc = Map<String, dynamic>.from(
    jsonDecode(File(input).readAsStringSync()) as Map,
  );
  final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync();
  final logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
  test('zero reward document has coverage authority and no cash sale', () {
    expect(invoiceHasRewardCoverage(doc), true);
    expect(doc['payment_status'], 'covered_by_reward');
    expect(doc['payment_method'], 'reward_coverage');
    expect(doc['net_collected'], 0);
    expect(doc['snapshot']['total'], 0);
    final unproven = Map<String, dynamic>.from(doc)..remove('reward_coverage');
    expect(invoiceHasRewardCoverage(unproven), false);
  });
  for (final ar in [true, false]) {
    for (final paper in ['A4', '58', '80']) {
      test('zero covered invoice ${ar ? 'ar' : 'en'} $paper', () async {
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
        await File('$output/zero-${ar ? 'ar' : 'en'}-$paper.pdf')
            .writeAsBytes(bytes);
      });
    }
  }
}
