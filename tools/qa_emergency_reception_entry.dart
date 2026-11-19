// Isolated local acceptance target. No production endpoint or financial adapter.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/wash_reception.dart';
import 'package:sabiha_hub/branch_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8098) {
    throw StateError('Local QA only');
  }
  final sessionResponse = await http.get(Uri.base.resolve('/qa-session'));
  final scopeResponse = await http.get(Uri.base.resolve('/qa-scope'));
  if (sessionResponse.statusCode != 200 || scopeResponse.statusCode != 200) {
    throw StateError('Isolated source unavailable');
  }
  final session = jsonDecode(sessionResponse.body) as Map<String, dynamic>,
      scope = jsonDecode(scopeResponse.body) as Map<String, dynamic>;
  final client = SupabaseClient(
    'http://127.0.0.1:54391',
    session['access_token'] as String,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.recoverSession(sessionResponse.body);
  BranchSelection.current = scope['branch'] as String;
  final lang = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar';
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
        message: 'ISOLATED QA',
        location: BannerLocation.topEnd,
        child: WashReceptionScreen(client: client, role: 'owner'),
      ),
    ),
  );
}
