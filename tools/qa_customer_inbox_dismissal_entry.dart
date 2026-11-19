// Local read-only acceptance host. Not part of the application entry point.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/app_inbox.dart';
import 'package:sabiha_hub/app_inbox_live.dart';
Future<void> main()async{
 WidgetsFlutterBinding.ensureInitialized();
 if(Uri.base.host!='127.0.0.1'||Uri.base.port!=8175){throw StateError('Local QA only');}
 final response=await http.get(Uri.base.resolve('/qa-session'));
 if(response.statusCode!=200){throw StateError('QA fixture session unavailable');}
 final session=jsonDecode(response.body)as Map<String,dynamic>;
 final client=SupabaseClient('http://127.0.0.1:54391',session['access_token']as String,authOptions:const AuthClientOptions(autoRefreshToken:false));
 await client.auth.recoverSession(response.body);
 final lang=Uri.base.queryParameters['lang']=='en'?'en':'ar';
 runApp(MaterialApp(locale:Locale(lang),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:GlobalMaterialLocalizations.delegates,theme:ThemeData(colorSchemeSeed:const Color(0xff174b83)),home:AppInboxScreen(client:client,liveTransport:ReadOnlyInboxTransport(client))));
}

// HTTP UI acceptance only; the existing realtime transport has independent acceptance.
class ReadOnlyInboxTransport implements AppInboxLiveTransport {
 ReadOnlyInboxTransport(this.client);final SupabaseClient client;
 @override Future<int> readUnread()async {final x=await client.rpc('list_my_app_inbox');return (x as Map)['unread_count'] as int;}
 @override Future<void> subscribe({required VoidCallback onHint,required VoidCallback onReconnect})async{}
 @override Future<void> unsubscribe()async{}
 @override Future<void> reauthenticate()async{}
}
