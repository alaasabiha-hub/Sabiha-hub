// Local QA target only; no embedded account credentials or production endpoint.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/cashier_checkout.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8105) {
    throw StateError('Isolated local acceptance only');
  }
  final sessionResponse = await http.get(Uri.base.resolve('/qa-session'));
  final scopeResponse = await http.get(Uri.base.resolve('/qa-scope'));
  if (sessionResponse.statusCode != 200 || scopeResponse.statusCode != 200) {
    throw StateError('Isolated source unavailable');
  }
  final session = jsonDecode(sessionResponse.body) as Map<String, dynamic>;
  final scope = jsonDecode(scopeResponse.body) as Map<String, dynamic>;
  final client = SupabaseClient('http://127.0.0.1:54391', session['access_token'] as String,
    authOptions: const AuthClientOptions(autoRefreshToken: false));
  await client.auth.recoverSession(sessionResponse.body);
  final ar = Uri.base.queryParameters['lang'] != 'en';
  runApp(MaterialApp(locale: Locale(ar ? 'ar' : 'en'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff174b83),primary: const Color(0xff174b83)),scaffoldBackgroundColor: Colors.white),
    home: Banner(message: 'ISOLATED QA',location: BannerLocation.topEnd,
      child: Scaffold(appBar: AppBar(title: Text(ar ? 'اختبار إيقاف الخدمة المعزول' : 'Isolated service stop acceptance')),
        body: SingleChildScrollView(padding: const EdgeInsets.all(16),child: CashierCheckoutPanel(
          gateway: SupabaseCashierCartGateway(client),branch: scope['branch'] as String,
          draft: scope['draft'] as String,version: 1,hasServices: true,
          onMutationBusy: (_) {},onIssued: () {},
        ))))));
}
