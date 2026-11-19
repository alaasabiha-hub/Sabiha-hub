import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  final source = Platform.environment['SABIHA_ZERO_REFUND_DOCUMENT'];
  final output = Platform.environment['SABIHA_ZERO_REFUND_OUTPUT'];
  for (final lang in ['ar', 'en']) {
    test(
      'actual zero-value returned goods receipt $lang',
      () async {
        final document = Map<String, dynamic>.from(
          jsonDecode(File(source!).readAsStringSync()) as Map,
        );
        expect(document['refund_receipt']['amount'], 0);
        expect(document['refund_receipt']['payment_event_recorded'], false);
        final before = jsonEncode(document);
        final bytes = await buildInvoicePdf(
          document,
          File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(),
          File('assets/sabiha_brand_approved.png').readAsBytesSync(),
          paper: '58',
          arabic: lang == 'ar',
        );
        expect(jsonEncode(document), before);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        await Directory(output!).create(recursive: true);
        await File('$output/zero-return-$lang.pdf').writeAsBytes(bytes);
      },
      skip: source == null || output == null
          ? 'Supply isolated zero-value return document and output'
          : false,
    );
  }
}
