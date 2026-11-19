// Device printing only. Invoice authority, leases and money remain on the server.
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

enum PrinterConnection { system, usb, bluetooth, wifi, lan }

enum PrintSubmission { submitted, cancelled, unavailable, unknown }

class PrintDispatchResult {
  const PrintDispatchResult(this.status, this.code, {required this.usedDialog});
  final PrintSubmission status;
  final String code;
  final bool usedDialog;
  // OS acceptance never proves that paper exited, a cutter worked, or a model is supported.
  bool get physicalOutputVerified => false;
}

class InvoicePrintTarget {
  InvoicePrintTarget({
    required this.profileId,
    required this.branchId,
    required this.name,
    required this.paper,
    required this.connection,
    required this.deviceIdentifier,
    this.adapter = 'system',
  }) {
    if (!const ['A4', '58', '80'].contains(paper) ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(profileId) ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(branchId) ||
        name.trim().isEmpty ||
        deviceIdentifier.length > 300 ||
        RegExp(r'[\r\n\x00]').hasMatch(deviceIdentifier)) {
      throw const FormatException('Invalid printer profile');
    }
  }
  factory InvoicePrintTarget.fromProfile(Map<String, dynamic> row) =>
      InvoicePrintTarget(
        profileId: row['printer_id'] as String,
        branchId: row['branch_id'] as String,
        name: row['name'] as String,
        paper: row['paper'] as String,
        connection: switch (row['transport']) {
          'system' => PrinterConnection.system,
          'usb' => PrinterConnection.usb,
          'bluetooth' => PrinterConnection.bluetooth,
          'wifi' => PrinterConnection.wifi,
          'network' => PrinterConnection.lan,
          _ => throw const FormatException('Unknown printer transport'),
        },
        deviceIdentifier: row['device_identifier'] as String? ?? '',
      );
  final String profileId, branchId, name, paper, deviceIdentifier, adapter;
  final PrinterConnection connection;
  String get transport =>
      connection == PrinterConnection.lan ? 'network' : connection.name;
  PdfPageFormat get format => paper == 'A4'
      ? PdfPageFormat.a4
      : PdfPageFormat(
          double.parse(paper) * PdfPageFormat.mm,
          240 * PdfPageFormat.mm,
          marginAll: 4 * PdfPageFormat.mm,
        );
  InvoicePrintTarget withClaim(Map<String, dynamic> claim) =>
      InvoicePrintTarget.fromProfile({
        'printer_id': profileId,
        'branch_id': branchId,
        'name': name,
        'paper': claim['paper'],
        'transport': claim['transport'],
        'device_identifier': claim['device_identifier'],
      });
}

abstract class InvoicePrinterAdapter {
  String get id;
  Future<PrintDispatchResult> submit(
    Uint8List pdf,
    InvoicePrintTarget target, {
    required String documentName,
    required bool preferDirect,
  });
}

abstract class SystemPrintDriver {
  Future<PrintingInfo> capabilities();
  Future<List<Printer>> printers();
  Future<bool> dialog(Uint8List pdf, InvoicePrintTarget target, String name);
  Future<bool> direct(
    Uint8List pdf,
    InvoicePrintTarget target,
    Printer printer,
    String name,
  );
}

class PluginSystemPrintDriver implements SystemPrintDriver {
  @override
  Future<PrintingInfo> capabilities() => Printing.info();
  @override
  Future<List<Printer>> printers() => Printing.listPrinters();
  @override
  Future<bool> dialog(Uint8List pdf, InvoicePrintTarget target, String name) =>
      Printing.layoutPdf(
        name: name,
        format: target.format,
        dynamicLayout: false,
        onLayout: (_) async => pdf,
      );
  @override
  Future<bool> direct(
    Uint8List pdf,
    InvoicePrintTarget target,
    Printer printer,
    String name,
  ) async => await Printing.directPrintPdf(
    printer: printer,
    name: name,
    format: target.format,
    dynamicLayout: false,
    onLayout: (_) async => pdf,
  );
}

/// USB/Bluetooth/Wi-Fi/LAN are physical connection metadata, not raw byte protocols.
/// This adapter uses installed OS drivers only; it never opens a socket or Bluetooth device.
class SystemInvoicePrinterAdapter implements InvoicePrinterAdapter {
  SystemInvoicePrinterAdapter({SystemPrintDriver? driver})
    : driver = driver ?? PluginSystemPrintDriver();
  final SystemPrintDriver driver;
  @override
  String get id => 'system';
  @override
  Future<PrintDispatchResult> submit(
    Uint8List pdf,
    InvoicePrintTarget target, {
    required String documentName,
    required bool preferDirect,
  }) async {
    PrintingInfo info;
    try {
      info = await driver.capabilities();
    } catch (_) {
      return const PrintDispatchResult(
        PrintSubmission.unavailable,
        'print_capabilities_unavailable',
        usedDialog: false,
      );
    }
    if (!info.canPrint) {
      return const PrintDispatchResult(
        PrintSubmission.unavailable,
        'system_print_unavailable',
        usedDialog: false,
      );
    }
    Printer? selected;
    if (preferDirect) {
      // No silent downgrade to another printer or a dialog after a direct request.
      if (!info.directPrint ||
          !info.canListPrinters ||
          target.deviceIdentifier.trim().isEmpty) {
        return const PrintDispatchResult(
          PrintSubmission.unavailable,
          'direct_target_not_supported',
          usedDialog: false,
        );
      }
      List<Printer> available;
      try {
        available = (await driver.printers())
            .where((p) => p.isAvailable)
            .toList();
      } catch (_) {
        return const PrintDispatchResult(
          PrintSubmission.unavailable,
          'printer_discovery_unavailable',
          usedDialog: false,
        );
      }
      final byUrl = available
          .where((p) => p.url == target.deviceIdentifier)
          .toList();
      final matches = byUrl.isNotEmpty
          ? byUrl
          : available.where((p) => p.name == target.deviceIdentifier).toList();
      if (matches.length != 1) {
        return const PrintDispatchResult(
          PrintSubmission.unavailable,
          'printer_target_not_unique_or_available',
          usedDialog: false,
        );
      }
      selected = matches.single;
    }
    try {
      final accepted = selected == null
          ? await driver.dialog(pdf, target, documentName)
          : await driver.direct(pdf, target, selected, documentName);
      return PrintDispatchResult(
        accepted ? PrintSubmission.submitted : PrintSubmission.cancelled,
        accepted ? 'os_submission_only' : 'print_dialog_cancelled',
        usedDialog: selected == null,
      );
    } catch (_) {
      // Submission may already have reached the spooler. Never auto-fallback or resend.
      return PrintDispatchResult(
        PrintSubmission.unknown,
        'device_submission_unknown',
        usedDialog: selected == null,
      );
    }
  }
}

class InvoicePrintingService {
  InvoicePrintingService({List<InvoicePrinterAdapter>? adapters})
    : adapters = {
        for (final a in adapters ?? [SystemInvoicePrinterAdapter()]) a.id: a,
      };
  final Map<String, InvoicePrinterAdapter> adapters;
  Future<PrintDispatchResult> submit(
    Uint8List pdf,
    InvoicePrintTarget target, {
    required String documentName,
    bool preferDirect = false,
  }) async {
    if (pdf.length < 5 ||
        pdf.length > 10 * 1024 * 1024 ||
        String.fromCharCodes(pdf.take(5)) != '%PDF-') {
      return const PrintDispatchResult(
        PrintSubmission.unavailable,
        'invalid_pdf',
        usedDialog: false,
      );
    }
    final adapter = adapters[target.adapter];
    if (adapter == null) {
      return const PrintDispatchResult(
        PrintSubmission.unavailable,
        'printer_adapter_not_installed',
        usedDialog: false,
      );
    }
    return adapter.submit(
      pdf,
      target,
      documentName: documentName,
      preferDirect: preferDirect,
    );
  }
}
