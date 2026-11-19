import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/printer_device_settings.dart';

import 'invoice_printing_test.dart' as routing;

void main() {
  const output = String.fromEnvironment('SABIHA_DIAGNOSTIC_OUTPUT');
  for (final paper in ['A4', '58', '80']) {
    test(
      'new diagnostic page $paper uses approved assets and is not an invoice',
      () async {
        final bytes = await buildPrinterDiagnosticPage(
          routing.target(paper: paper),
          loadAsset: (path) async =>
              ByteData.sublistView(await File(path).readAsBytes()),
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1000));
        if (output.isNotEmpty) {
          await Directory(output).create(recursive: true);
          await File('$output/printer-test-$paper.pdf')
              .writeAsBytes(bytes, flush: true);
        }
      },
    );
  }
}
