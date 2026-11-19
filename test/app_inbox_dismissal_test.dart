import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_inbox.dart';
import 'app_inbox_test.dart' show Gateway;
import 'app_inbox_live_content_test.dart' show Transport;
import 'visit_recovery_request_test.dart' as auth;

Map<String,dynamic> noticePage()=>{'items':[{'event_id':'notice-a','can_dismiss':true,'read':false,'title_ar':'إشعار خاص','title_en':'Private notice','body_ar':'سجل محفوظ','body_en':'Retained record','created_at':'2026-11-16T00:00:00Z'}],'unread_count':1,'next_cursor':null};
Map<String,dynamic> receipt(String id)=>{'event_id':id,'dismissed':true,'administrative_record_preserved':true};
void main(){
 test('Unknown acknowledgement retries exact personal dismissal nonce',()async{
  final g=Gateway();var first=true;final nonces=<String>[];
  g.handle=(name,p)async{if(name=='list_my_app_inbox')return noticePage();nonces.add(p['p_request'] as String);if(first){first=false;throw StateError('ACK lost');}return receipt(p['p_event'] as String);};
  final f=AppInboxController(gateway:g,actorId:()=> 'a');await f.refresh();await f.dismiss('notice-a');expect(f.failed,true);expect(f.items,isEmpty);await f.refresh();await f.dismiss('notice-a');expect(nonces.length,2);expect(nonces.first,nonces.last);expect(f.unread,0);expect(f.items,isEmpty);f.dispose();
 });
 test('Late dismissal reply cannot mutate another account',()async{
  var actor='a';final pending=Completer<dynamic>();final g=Gateway();g.handle=(name,p)async=>name=='list_my_app_inbox'?noticePage():pending.future;
  final f=AppInboxController(gateway:g,actorId:()=>actor);await f.refresh();final task=f.dismiss('notice-a');actor='b';f.clearOnAccountChange();pending.complete(receipt('notice-a'));await task;expect(f.items,isEmpty);expect(f.unread,0);expect(f.current,false);f.dispose();
 });
 for(final lang in ['ar','en']){for(final width in [390.0,1024.0,1440.0]){
  testWidgets('Personal list hide $lang $width',(t)async{
   t.view.physicalSize=Size(width,1000);t.view.devicePixelRatio=1;addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);
   final client=await auth.client(t);final g=Gateway();g.handle=(name,p)async=>name=='list_my_app_inbox'?noticePage():receipt(p['p_event'] as String);final f=AppInboxController(gateway:g,actorId:()=>client.auth.currentUser?.id);
   await t.pumpWidget(MaterialApp(locale:Locale(lang),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:GlobalMaterialLocalizations.delegates,home:AppInboxScreen(client:client,controller:f,liveTransport:Transport())));await t.pump(const Duration(milliseconds:151));await t.pumpAndSettle();
   final label=lang=='ar'?'إزالة من قائمتي':'Remove from my list';expect(find.text(label),findsOneWidget);await t.ensureVisible(find.text(label));await t.tap(find.text(label));await t.pumpAndSettle();expect(find.text(label),findsNothing);expect(f.unread,0);expect(g.calls.where((x)=>x['name']=='dismiss_my_app_inbox_event').length,1);expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());f.dispose();await t.runAsync(()=>client.dispose());
  });
 }}
}
