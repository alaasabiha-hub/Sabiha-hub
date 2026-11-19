// Local QA host only; no secrets embedded and never an application entry point.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';
import 'package:sabiha_hub/cashier_points_verbal.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if(Uri.base.host!='127.0.0.1'||Uri.base.port!=8172) throw StateError('Local QA only');
  final response=await http.get(Uri.base.resolve('/qa-session'));
  if(response.statusCode!=200) throw StateError('Local fixture unavailable');
  final payload=jsonDecode(response.body)as Map<String,dynamic>;
  final session=payload['session']as Map<String,dynamic>;
  final client=SupabaseClient('http://127.0.0.1:54391',session['access_token']as String,
    authOptions:const AuthClientOptions(autoRefreshToken:false));
  await client.auth.recoverSession(jsonEncode(session));
  final lang=Uri.base.queryParameters['lang']=='en'?'en':'ar';
  runApp(MaterialApp(locale:Locale(lang),supportedLocales:const[Locale('ar'),Locale('en')],
    localizationsDelegates:GlobalMaterialLocalizations.delegates,
    theme:ThemeData(fontFamily:'NotoNaskhArabic',colorSchemeSeed:const Color(0xff174b83)),
    home:Scaffold(appBar:AppBar(backgroundColor:const Color(0xff071a36),foregroundColor:Colors.white,
      title:Text(lang=='ar'?'الكاشير — موافقة الولاء الشفهية':'Cashier — verbal loyalty approval')),
      body:SingleChildScrollView(child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:860),
        child:CashierPointsVerbalPanel(gateway:SupabaseCashierCartGateway(client),branch:payload['branch']as String,
          draft:payload['draft']as String,onApproval:(_){},onBusy:(_){},onSelectionPending:(_){})))))));
}
