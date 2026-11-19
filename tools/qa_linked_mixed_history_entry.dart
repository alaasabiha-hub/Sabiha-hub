// Isolated local acceptance host. Never imported by lib/main.dart.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_history.dart';
import 'package:sabiha_hub/payment_finance.dart';
Future<void> main() async {
 WidgetsFlutterBinding.ensureInitialized();
 if(Uri.base.host!='127.0.0.1'||Uri.base.port!=8170){throw StateError('Local QA only');}
 final role=Uri.base.queryParameters['role']=='owner'?'owner':'customer';
 final response=await http.get(Uri.base.resolve('/qa-session?role=$role'));
 if(response.statusCode!=200){throw StateError('QA session unavailable');}
 final session=jsonDecode(response.body)as Map<String,dynamic>;
 final client=SupabaseClient('http://127.0.0.1:54391',session['access_token'] as String,authOptions:const AuthClientOptions(autoRefreshToken:false));
 await client.auth.recoverSession(response.body);
 final language=Uri.base.queryParameters['lang']=='en'?'en':'ar';
 runApp(MaterialApp(locale:Locale(language),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:GlobalMaterialLocalizations.delegates,
  theme:ThemeData(colorSchemeSeed:const Color(0xff174b83)),
  home:role=='owner'?AiPaymentAnalyticsScreen(client:client):OfflineHistoryScreen(client:client)));
}
