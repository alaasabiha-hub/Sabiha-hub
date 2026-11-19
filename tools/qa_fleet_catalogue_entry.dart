// Local acceptance host only. Not imported by the production entry point.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/companies_fleets_catalogue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8092) {
    throw StateError('Local QA host only');
  }
  final response = await http.get(Uri.base.resolve('/qa-session'));
  if (response.statusCode != 200) throw StateError('QA session unavailable');
  final session = jsonDecode(response.body) as Map<String, dynamic>;
  final client = SupabaseClient('http://127.0.0.1:54391', session['access_token']);
  await client.auth.recoverSession(response.body);
  final language = Uri.base.queryParameters['lang'] == 'ar' ? 'ar' : 'en';
  runApp(MaterialApp(
    locale: Locale(language),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorSchemeSeed: const Color(0xff174b83)),
    home: CompaniesFleetsCatalogueScreen(client: client),
  ));
}
