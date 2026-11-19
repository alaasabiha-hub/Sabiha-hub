import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:sabiha_hub/invoice_printing.dart';

const profile = '11111111-1111-4111-8111-111111111111';
const branch = '22222222-2222-4222-8222-222222222222';
InvoicePrintTarget target({
  String paper = '80',
  String identifier = 'printer://front',
  PrinterConnection connection = PrinterConnection.system,
  String adapter = 'system',
}) => InvoicePrintTarget(
  profileId: profile,
  branchId: branch,
  name: 'Front printer',
  paper: paper,
  connection: connection,
  deviceIdentifier: identifier,
  adapter: adapter,
);

class Driver implements SystemPrintDriver {
  PrintingInfo info = const PrintingInfo(
    canPrint: true,
    directPrint: true,
    canListPrinters: true,
  );
  List<Printer> found = [
    Printer(url: 'printer://front', name: 'Front', isAvailable: true),
  ];
  int directCalls = 0, dialogs = 0, discoveries = 0, capabilityCalls = 0;
  bool reject = false, ambiguous = false;
  Printer? received;
  Uint8List? bytes;
  String? paper;
  @override
  Future<PrintingInfo> capabilities() async {
    capabilityCalls++;
    return info;
  }

  @override
  Future<List<Printer>> printers() async {
    discoveries++;
    return found;
  }

  @override
  Future<bool> dialog(
    Uint8List pdf,
    InvoicePrintTarget target,
    String name,
  ) async {
    dialogs++;
    bytes = pdf;
    paper = target.paper;
    return !reject;
  }

  @override
  Future<bool> direct(
    Uint8List pdf,
    InvoicePrintTarget target,
    Printer printer,
    String name,
  ) async {
    directCalls++;
    received = printer;
    bytes = pdf;
    paper = target.paper;
    if (ambiguous) throw StateError('spool acknowledgement lost');
    return !reject;
  }
}

void main() {
  final bytes = Uint8List.fromList('%PDF-1.7\nQA routing only'.codeUnits);
  for (final connection in PrinterConnection.values) {
    test(
      'driver-backed ${connection.name} routes exact available OS printer without raw I/O',
      () async {
        final d = Driver();
        final service = InvoicePrintingService(
          adapters: [SystemInvoicePrinterAdapter(driver: d)],
        );
        final result = await service.submit(
          bytes,
          target(connection: connection),
          documentName: 'QA routing test',
          preferDirect: true,
        );
        expect(result.status, PrintSubmission.submitted);
        expect(result.physicalOutputVerified, false);
        expect(d.directCalls, 1);
        expect(d.dialogs, 0);
        expect(d.received, same(d.found.single));
        expect(d.bytes, same(bytes));
      },
    );
  }
  test('browser uses explicit system dialog and never enumerates or claims silent USB support', () async {
    final d = Driver()..info = const PrintingInfo(canPrint: true);
    final result =
        await InvoicePrintingService(
          adapters: [SystemInvoicePrinterAdapter(driver: d)],
        ).submit(
          bytes,
          target(connection: PrinterConnection.usb),
          documentName: 'QA',
        );
    expect(result.usedDialog, true);
    expect(result.physicalOutputVerified, false);
    expect(d.dialogs, 1);
    expect(d.discoveries, 0);
    expect(d.directCalls, 0);
  });
  test('unsupported direct request does not silently switch printer or open a dialog', () async {
    final d = Driver()..info = const PrintingInfo(canPrint: true);
    final result = await InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: d)],
    ).submit(bytes, target(), documentName: 'QA', preferDirect: true);
    expect(result.status, PrintSubmission.unavailable);
    expect(d.directCalls + d.dialogs, 0);
  });
  test('duplicate names and unavailable printers fail closed', () async {
    final d = Driver()
      ..found = [
        Printer(url: 'os:a', name: 'Same'),
        Printer(url: 'os:b', name: 'Same'),
        Printer(url: 'os:c', name: 'Offline', isAvailable: false),
      ];
    final s = InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: d)],
    );
    for (final name in ['Same', 'Offline', 'not-listed']) {
      final r = await s.submit(
        bytes,
        target(identifier: name),
        documentName: 'QA',
        preferDirect: true,
      );
      expect(r.status, PrintSubmission.unavailable);
    }
    expect(d.directCalls + d.dialogs, 0);
  });
  test('exact OS URL safely disambiguates same display names', () async {
    final d = Driver()
      ..found = [
        Printer(url: 'os:a', name: 'Same'),
        Printer(url: 'os:b', name: 'Same'),
      ];
    final r =
        await InvoicePrintingService(
          adapters: [SystemInvoicePrinterAdapter(driver: d)],
        ).submit(
          bytes,
          target(identifier: 'os:b'),
          documentName: 'QA',
          preferDirect: true,
        );
    expect(r.status, PrintSubmission.submitted);
    expect(d.received, same(d.found[1]));
  });
  test('lost spool acknowledgement never falls back or resends', () async {
    final d = Driver()..ambiguous = true;
    final r = await InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: d)],
    ).submit(bytes, target(), documentName: 'QA', preferDirect: true);
    expect(r.status, PrintSubmission.unknown);
    expect(r.code, 'device_submission_unknown');
    expect(d.directCalls, 1);
    expect(d.dialogs, 0);
  });
  test('cancellation is distinct from OS acceptance', () async {
    final d = Driver()..reject = true;
    final r = await InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: d)],
    ).submit(bytes, target(), documentName: 'QA');
    expect(r.status, PrintSubmission.cancelled);
    expect(r.physicalOutputVerified, false);
  });
  test(
    'invalid document and missing adapter do not reach OS or network',
    () async {
      final d = Driver();
      final s = InvoicePrintingService(
        adapters: [SystemInvoicePrinterAdapter(driver: d)],
      );
      expect(
        (await s.submit(Uint8List(1), target(), documentName: 'QA')).status,
        PrintSubmission.unavailable,
      );
      expect(
        (await s.submit(
          bytes,
          target(adapter: 'uninstalled-vendor-sdk'),
          documentName: 'QA',
        )).code,
        'printer_adapter_not_installed',
      );
      expect(d.capabilityCalls + d.directCalls + d.dialogs, 0);
    },
  );
  test('server claim controls actual paper and connection without rewriting PDF bytes', () async {
    final t = target(paper: 'A4').withClaim({
      'paper': '58',
      'transport': 'network',
      'device_identifier': 'printer://front',
    });
    expect(t.paper, '58');
    expect(t.connection, PrinterConnection.lan);
    expect(t.profileId, profile);
    expect(t.format.width, closeTo(58 * PdfPageFormat.mm, .001));
    final d = Driver();
    await InvoicePrintingService(
      adapters: [SystemInvoicePrinterAdapter(driver: d)],
    ).submit(bytes, t, documentName: 'QA');
    expect(d.bytes, same(bytes));
    expect(d.paper, '58');
  });
  test('only supported paper sizes and transports are accepted', () {
    for (final paper in ['A4', '58', '80']) {
      expect(target(paper: paper).format.width, greaterThan(0));
    }
    expect(() => target(paper: '100'), throwsFormatException);
    expect(
      () => InvoicePrintTarget.fromProfile({
        'printer_id': profile,
        'branch_id': branch,
        'name': 'QA',
        'paper': '80',
        'transport': 'raw-anything',
      }),
      throwsFormatException,
    );
  });
}
