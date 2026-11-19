// Local acceptance host only; never imported by main.dart.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/service_quality.dart';
Future<void> main() async {
 WidgetsFlutterBinding.ensureInitialized();
 if(Uri.base.host!='127.0.0.1'||Uri.base.port!=8093)throw StateError('Local QA host only');
 final response=await http.get(Uri.base.resolve('/qa-session'));
 final scopeResponse=await http.get(Uri.base.resolve('/qa-scope'));
 if(response.statusCode!=200||scopeResponse.statusCode!=200)throw StateError('QA scope unavailable');
 final session=jsonDecode(response.body)as Map<String,dynamic>;
 final scope=jsonDecode(scopeResponse.body)as Map<String,dynamic>;
 final client=SupabaseClient('http://127.0.0.1:54391',session['access_token']);
 await client.auth.recoverSession(response.body);
 final gateway=SupabaseServiceQualityGateway(client);
 final lang=Uri.base.queryParameters['lang']=='en'?'en':'ar';
 runApp(MaterialApp(locale:Locale(lang),supportedLocales:const[Locale('ar'),Locale('en')],
 localizationsDelegates:GlobalMaterialLocalizations.delegates,
 theme:ThemeData(colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xff174b83),primary:const Color(0xff174b83),secondary:const Color(0xffc5cbd5)),scaffoldBackgroundColor:Colors.white),
 home:Uri.base.queryParameters['mode']=='policy'
 ?ServiceQualityPolicyScreen(branch:scope['branch'],gateway:gateway)
 :ServiceQualityScreen(order:scope['order'],gateway:gateway)));
}
