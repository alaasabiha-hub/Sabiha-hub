import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_financial_consent_route.dart';
import 'package:sabiha_hub/offline_reward_financial_consent.dart';
import 'offline_reward_financial_consent_test.dart' as fixture;
import 'visit_recovery_request_test.dart' as auth;

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('profile consent navigation $language $width', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final client = await auth.client(tester);
        final store = fixture.Store();
        final gateway = fixture.Gateway(store);
        gateway.currentView = {'state': 'unavailable', 'issuer_enabled': false};
        await tester.pumpWidget(MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(body: CustomerFinancialConsentLink(
            client: client, gateway: gateway, store: store,
          )),
        ));
        await tester.tap(find.byKey(const ValueKey('customer-financial-consent-link')));
        await tester.pumpAndSettle();
        expect(find.byType(OfflineRewardFinancialConsentPanel), findsOneWidget);
        expect(Directionality.of(tester.element(find.byType(OfflineRewardFinancialConsentPanel))),
          language == 'ar' ? TextDirection.rtl : TextDirection.ltr);
        expect(gateway.calls.where((c) => c['name'] == 'proposal').single['id'], isNull);
        expect(gateway.calls.where((c) => c['name'] == 'accept'), isEmpty);
        expect(store.value, isNull);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(OfflineRewardFinancialConsentPanel), findsNothing);
        expect(find.byKey(const ValueKey('customer-financial-consent-link')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
