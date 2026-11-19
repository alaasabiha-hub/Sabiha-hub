import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_visuals.dart';
import 'package:sabiha_hub/customer_booking_ui.dart';
void main(){
 for(final size in [const Size(320,568),const Size(390,844),const Size(430,932)]){
  for(final ar in [true,false]){
   testWidgets('real customer shell photo/cards/navigation fits $size ar=$ar',(tester)async{
    tester.view.physicalSize=size;tester.view.devicePixelRatio=1;addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    int? destination;
    await tester.pumpWidget(MaterialApp(locale:Locale(ar?'ar':'en'),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:const[GlobalMaterialLocalizations.delegate,GlobalWidgetsLocalizations.delegate,GlobalCupertinoLocalizations.delegate],home:CustomerShell(title:ar?'طلباتي ومواعيدي':'Orders & appointments',subtitle:ar?'تابع خدماتك السابقة والحالية':'Your previous and current services',selected:2,onNavigate:(i)=>destination=i,body:ListView(padding:const EdgeInsets.all(16),children:[CustomerBookingCard(booking:const{'id':'LOCAL-TEST','service_name':'غسيل كامل للسيارة · Complete car care','status':'confirmed','quoted_price':175,'booking_date':'2026-11-13','booking_time':'10:00'},arabic:ar,onInspection:(){},support:const SizedBox())]))));
    await tester.pumpAndSettle();expect(tester.takeException(),isNull);
    expect(find.byType(Image),findsWidgets);
    await tester.tap(find.text(ar?'الخدمات':'Services'));expect(destination,1);
   });
  }
 }
}
