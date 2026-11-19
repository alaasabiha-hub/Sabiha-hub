// Local read-only acceptance host. Not part of the application entry point.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_visit_cashier_grants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8187) {
    throw StateError('Local QA only');
  }
  final response = await http.get(Uri.base.resolve('/qa-session'));
  if (response.statusCode != 200) {
    throw StateError('QA fixture session unavailable');
  }
  final session = jsonDecode(response.body) as Map<String, dynamic>;
  final client = SupabaseClient(
    'http://127.0.0.1:54391',
    session['access_token'] as String,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.recoverSession(response.body);
  final scope = jsonDecode(
    (await http.get(
      Uri.base.resolve(
        "/qa-scope?lang=${Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar'}",
      ),
    )).body,
  ) as Map<String, dynamic>;
  final lang = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar';
  runApp(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(colorSchemeSeed: const Color(0xff174b83)),
      home: Scaffold(
        body: SingleChildScrollView(
          child: OwnerVisitCashierGrantsPanel(
            client: client,
            branch: scope['branch'] as String,
            rules: scope['rules'] as String,
          ),
        ),
      ),
    ),
  );
}
