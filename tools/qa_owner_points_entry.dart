// Loopback-only QA of the actual owner loyalty route. No financial activation.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/loyalty_policy.dart';

class ScopedPolicyGateway extends SupabaseLoyaltyPolicyGateway {
  ScopedPolicyGateway(super.client, this.branch);
  final String branch;
  @override
  Future<Map<String, dynamic>> read(String? selected) =>
      super.read(selected ?? branch);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8150) {
    throw StateError('Isolated loopback QA only');
  }
  final lang = Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar';
  final session = await http.get(Uri.base.resolve('/qa-owner'));
  final scope = jsonDecode(
    (await http.get(Uri.base.resolve('/qa-scope?lang=$lang'))).body,
  ) as Map<String, dynamic>;
  await Supabase.initialize(
    url: 'http://127.0.0.1:54391',
    publishableKey: scope['anon'],
    authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
  );
  await Supabase.instance.client.auth.recoverSession(session.body);
  final client = Supabase.instance.client;
  runApp(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          primary: Color(0xff071a36),
          secondary: Color(0xff174b83),
          surface: Colors.white,
          onSurface: Color(0xff101820),
        ),
        scaffoldBackgroundColor: const Color(0xfff5f7fa),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff071a36),
          foregroundColor: Colors.white,
        ),
      ),
      home: Banner(
        message: 'ISOLATED QA',
        location: BannerLocation.topEnd,
        child: LoyaltyPolicyScreen(
          client: client,
          gateway: ScopedPolicyGateway(client, scope['branch']),
        ),
      ),
    ),
  );
}
