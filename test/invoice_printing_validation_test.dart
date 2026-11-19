import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/invoice_printing.dart';

import 'invoice_printing_test.dart' as routing;

void main() {
  test('malformed UUID-shaped profile is rejected before any dispatch', () {
    expect(
      () => InvoicePrintTarget(
        profileId: List.filled(36, '-').join(),
        branchId: routing.branch,
        name: 'QA',
        paper: '80',
        connection: PrinterConnection.system,
        deviceIdentifier: '',
      ),
      throwsFormatException,
    );
  });
  test('oversized PDF never reaches capabilities or spooler', () async {
    final bytes = Uint8List(10 * 1024 * 1024 + 1);
    bytes.setRange(0, 5, '%PDF-'.codeUnits);
    final driver = routing.Driver();
    final result = await InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: driver)],
    ).submit(bytes, routing.target(), documentName: 'QA');
    expect(result.code, 'invalid_pdf');
    expect(driver.capabilityCalls + driver.dialogs + driver.directCalls, 0);
  });
}
