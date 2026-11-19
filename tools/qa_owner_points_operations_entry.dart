// Local owner QA host. No credentials in the compiled application.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_points_policy.dart';
import 'package:sabiha_hub/owner_points_operations.dart';
Future<void> main() async {
 WidgetsFlutterBinding.ensureInitialized();
 if(Uri.base.host!='127.0.0.1'||Uri.base.port!=8173) throw StateError('Local QA only');
 final response=await http.get(Uri.base.resolve('/qa-session'));
 if(response.statusCode!=200)throw StateError('Fixture unavailable');
 final payload=jsonDecode(response.body)as Map<String,dynamic>;
 final session=payload['session']as Map<String,dynamic>;
 final client=SupabaseClient('http://127.0.0.1:54391',session['access_token']as String,authOptions:const AuthClientOptions(autoRefreshToken:false));
 await client.auth.recoverSession(jsonEncode(session));
 final lang=Uri.base.queryParameters['lang']=='en'?'en':'ar';
 runApp(MaterialApp(locale:Locale(lang),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:GlobalMaterialLocalizations.delegates,
 theme:ThemeData(fontFamily:'NotoNaskhArabic',colorSchemeSeed:const Color(0xff174b83)),
 home:Scaffold(appBar:AppBar(title:Text(lang=='ar'?'المالك — سياسات الولاء':'Owner — loyalty controls'),backgroundColor:const Color(0xff071a36),foregroundColor:Colors.white),
 body:SingleChildScrollView(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:900),child:OwnerPointsOperationsPanel(gateway:SupabaseOwnerPointsGateway(client),branch:payload['branch']as String)))))));
}
