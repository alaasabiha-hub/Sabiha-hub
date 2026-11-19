// Loopback-only QA target. Existing customer booking UI, no booking issued.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/delivery_support.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.host != '127.0.0.1' || Uri.base.port != 8112) {
    throw StateError('Local QA only');
  }
  final session = await http.get(Uri.base.resolve('/qa-session'));
  final scope = jsonDecode(
    (await http.get(
      Uri.base.resolve(
        '/qa-scope?lang=${Uri.base.queryParameters['lang'] ?? 'ar'}',
      ),
    )).body,
  ) as Map<String, dynamic>;
  await Supabase.initialize(
    url: 'http://127.0.0.1:54391',
    publishableKey: scope['anon'],
    authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
  );
  await Supabase.instance.client.auth.recoverSession(session.body);
  runApp(
    MaterialApp(
      locale: Locale(Uri.base.queryParameters['lang'] == 'en' ? 'en' : 'ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Banner(
        message: 'ISOLATED QA',
        location: BannerLocation.topEnd,
        child: Uri.base.queryParameters['mode'] == 'shop'
            ? FulfillmentShopScreen(
                client: Supabase.instance.client,
                catalogRefreshInterval: const Duration(seconds: 2),
              )
            : Uri.base.queryParameters['mode'] == 'services'
            ? const app.PublicServicesScreen(
                catalogRefreshInterval: Duration(seconds: 2),
              )
            : app.CreateBookingScreen(
                initialServiceId: scope['item'],
                catalogRefreshInterval: const Duration(seconds: 2),
              ),
      ),
    ),
  );
}
