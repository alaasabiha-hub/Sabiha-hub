// Read-only business smoke on the local iOS simulator. QA credentials are supplied
// from an excluded local define file; never use this target for distribution.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/app_config.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/offers_catalog.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const email = String.fromEnvironment('TEST_CUSTOMER_EMAIL');
  const password = String.fromEnvironment('TEST_PASSWORD');
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Expected local iOS screen did not appear');
  }

  Future<void> pause(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets(
    'iOS real app launch Arabic English login and owned invoice navigation',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(AppConfig.supabaseUrl, 'http://127.0.0.1:54321');
      expect(email, isNotEmpty);
      expect(password, isNotEmpty);
      await app.main();
      final account = find.byKey(const ValueKey('public-client-login'));
      final language = find.byKey(const ValueKey('public-language'));
      await waitFor(tester, account);
      expect(
        Directionality.of(tester.element(find.byType(OffersCatalogPage))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      debugPrint('IOS_ARABIC_PUBLIC_LAUNCH_OK');
      await tester.tap(language);
      await pause(tester);
      expect(
        Directionality.of(tester.element(find.byType(OffersCatalogPage))),
        TextDirection.ltr,
      );
      expect(find.byTooltip('Sign in'), findsOneWidget);
      debugPrint('IOS_ENGLISH_PUBLIC_LAYOUT_OK');
      await tester.tap(language);
      await pause(tester);
      await tester.tap(account);
      await waitFor(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField).at(0), email);
      await tester.enterText(find.byType(TextField).at(1), password);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.ensureVisible(find.text('تسجيل الدخول').last);
      await tester.tap(find.text('تسجيل الدخول').last);
      await waitFor(tester, find.byType(app.CustomerDashboardScreen));
      expect(app.supabase.auth.currentUser?.email, email);
      await pause(tester);
      expect(tester.takeException(), isNull);
      debugPrint('IOS_ACTUAL_QA_CUSTOMER_LOGIN_OK');
      unawaited(
        app.appNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => InvoiceDocumentsScreen(client: app.supabase),
          ),
        ),
      );
      await waitFor(tester, find.byType(InvoiceDocumentsScreen));
      await pause(tester);
      expect(tester.takeException(), isNull);
      debugPrint('IOS_OWNED_INVOICE_NAVIGATION_OK_NO_FINANCIAL_WRITES');
      app.appNavigatorKey.currentState!.pop();
      await pause(tester);
      expect(find.byType(app.CustomerDashboardScreen), findsOneWidget);
    },
  );
}
