// LOCAL QA only. Device acknowledgement below is explicitly simulated, never a real printer.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/invoice_printing.dart';
import 'package:sabiha_hub/printer_device_settings.dart';

class SimulatedQaPrinter implements InvoicePrinterAdapter {
  @override
  String get id => 'system';
  @override
  Future<PrintDispatchResult> submit(
    Uint8List pdf,
    InvoicePrintTarget target, {
    required String documentName,
    required bool preferDirect,
  }) async {
    if (String.fromCharCodes(pdf.take(5)) != '%PDF-' || pdf.length < 1000) {
      throw StateError('Actual generated PDF required');
    }
    debugPrint('QA_DRIVER_SIMULATED_NO_HARDWARE');
    return const PrintDispatchResult(
      PrintSubmission.submitted,
      'qa_simulated_acknowledgement',
      usedDialog: false,
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8094) {
    throw StateError('Local QA host only');
  }
  final role = Uri.base.queryParameters['role'] == 'cashier'
      ? 'cashier'
      : 'owner';
  final response = await http.get(Uri.base.resolve('/qa-session?role=$role'));
  final scopeResponse = await http.get(Uri.base.resolve('/qa-scope'));
  if (response.statusCode != 200 || scopeResponse.statusCode != 200) {
    throw StateError('QA scope unavailable');
  }
  final session = jsonDecode(response.body) as Map<String, dynamic>,
      scope = jsonDecode(scopeResponse.body) as Map<String, dynamic>;
  final client = SupabaseClient(
    'http://127.0.0.1:54391',
    session['access_token'],
  );
  await client.auth.recoverSession(response.body);
  final lang = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar',
      mode = Uri.base.queryParameters['mode'];
  final Widget screen = mode == 'invoice'
      ? InvoiceDocumentsScreen(
          client: client,
          initialToken: scope['token'],
          role: 'owner',
          printingService: InvoicePrintingService(
            adapters: [SimulatedQaPrinter()],
          ),
        )
      : mode == 'profiles'
      ? PrinterSettingsScreen(client: client)
      : DevicePrinterSettingsScreen(
          gateway: SupabaseDevicePrinterGateway(client),
        );
  runApp(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff174b83),
          primary: const Color(0xff174b83),
        ),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: Banner(
        message: 'QA: NO HARDWARE',
        location: BannerLocation.topEnd,
        child: screen,
      ),
    ),
  );
}
