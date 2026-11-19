import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/companies_fleets_catalogue.dart';

import 'companies_fleets_catalogue_test.dart' as fixture;
import 'visit_recovery_request_test.dart' as auth;

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('company record passes exact contract scope $language', (
      tester,
    ) async {
      tester.view.physicalSize = Size(language == 'ar' ? 390 : 1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = await auth.client(tester),
          api = fixture.Api()..listedParty = true;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: CompaniesFleetsCatalogueScreen(
            client: client,
            gateway: api,
            store: fixture.Store(),
            contractBuilder: (context, id) {
              expect(id, fixture.partyId);
              return const Scaffold(body: Text('QA contract route'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actual fleet'));
      await tester.pumpAndSettle();
      final route = find.text(
        language == 'ar' ? 'مسودات عقود الشركة' : 'Company contract drafts',
      );
      await tester.ensureVisible(route);
      await tester.pumpAndSettle();
      await tester.tap(route);
      await tester.pumpAndSettle();
      expect(find.text('QA contract route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
