// Local QA entry point; uses the actual customer shop without checkout substitutes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/delivery_support.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8095) {
    throw StateError('Local QA only');
  }
  final response = await http.get(Uri.base.resolve('/qa-session'));
  if (response.statusCode != 200) throw StateError('QA session unavailable');
  final session = jsonDecode(response.body) as Map<String, dynamic>;
  final client = SupabaseClient(
    'http://127.0.0.1:54391',
    session['access_token'] as String,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.recoverSession(response.body);
  final language = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar';
  runApp(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Banner(
        message: 'LOCAL QA',
        location: BannerLocation.topEnd,
        child: FulfillmentShopScreen(client: client),
      ),
    ),
  );
}
