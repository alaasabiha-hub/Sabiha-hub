// Local QA only: real owner login and POS navigation, without saving a draft.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/app_config.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/offers_catalog.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const email = String.fromEnvironment('TEST_OWNER_EMAIL');
  const password = String.fromEnvironment('TEST_OWNER_PASSWORD');
  const owner = String.fromEnvironment('TEST_OWNER_ID');
  const knownActors = String.fromEnvironment('TEST_ALLOWED_QA_IDS');
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Expected native point-of-sale screen did not appear');
  }

  Future<void> pause(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('native owner login and read-only POS Arabic English', (
    tester,
  ) async {
    expect(Platform.isAndroid || Platform.isIOS, isTrue);
    expect(
      AppConfig.supabaseUrl,
      Platform.isAndroid ? 'http://10.0.2.2:54321' : 'http://127.0.0.1:54321',
    );
    expect(email, isNotEmpty);
    expect(password, isNotEmpty);
    await app.main();
    await pause(tester);
    if (app.supabase.auth.currentUser != null) {
      expect(
        knownActors.split(','),
        contains(app.supabase.auth.currentUser!.id),
      );
      await app.supabase.auth.signOut();
      // Test setup clears only an existing known QA session, never device data.
      app.appNavigatorKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => app.HomeScreen(
            locale: const Locale('ar'),
            onLanguageChanged: (_) async {},
          ),
        ),
        (_) => false,
      );
    }
    await waitFor(tester, find.byType(OffersCatalogPage));
    final public = tester.element(find.byType(OffersCatalogPage));
    if (Localizations.localeOf(public).languageCode != 'ar') {
      await tester.tap(find.byKey(const ValueKey('public-language')));
      await pause(tester);
    }
    final staff = find.byKey(const ValueKey('public-staff-footer'));
    await tester.ensureVisible(staff);
    await pause(tester);
    await tester.tap(staff);
    await waitFor(tester, find.byType(app.StaffLoginScreen));
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), password);
    FocusManager.instance.primaryFocus?.unfocus();
    final signIn = find.text('تسجيل الدخول');
    await tester.ensureVisible(signIn.last);
    await pause(tester);
    await tester.tap(signIn.last);
    await waitFor(tester, find.byType(app.StaffDashboardScreen));
    expect(app.supabase.auth.currentUser?.id, owner);
    expect(
      tester
          .widget<app.StaffDashboardScreen>(
            find.byType(app.StaffDashboardScreen),
          )
          .role,
      'owner',
    );
    debugPrint('NATIVE_POS_ACTUAL_OWNER_LOGIN_OK');
    for (final lang in ['ar', 'en']) {
      final ar = lang == 'ar';
      if (!ar) {
        await tester.ensureVisible(find.text('English').first);
        await tester.tap(find.text('English').first);
        await pause(tester);
      }
      final reports = find.text(ar ? 'التقارير' : 'Reports').first;
      await tester.ensureVisible(reports);
      await tester.tap(reports);
      await pause(tester);
      final action = find.text(
        ar ? 'نقطة البيع متعددة البنود' : 'Multi-line point of sale',
      );
      await tester.ensureVisible(action);
      await pause(tester);
      await tester.tap(action);
      await waitFor(tester, find.byType(CashierInvoiceDraftScreen));
      await waitFor(
        tester,
        find.text(
          ar
              ? 'حفظ المسودة وحساب السعر من الخادم'
              : 'Save draft and calculate on server',
        ),
      );
      expect(
        Directionality.of(
          tester.element(find.byType(CashierInvoiceDraftScreen)),
        ),
        ar ? TextDirection.rtl : TextDirection.ltr,
      );
      expect(find.byKey(const ValueKey('checkout_issue')), findsNothing);
      expect(tester.takeException(), isNull);
      debugPrint(
        ar
            ? 'NATIVE_POS_ARABIC_READ_ONLY_OK'
            : 'NATIVE_POS_ENGLISH_READ_ONLY_OK',
      );
      app.appNavigatorKey.currentState!.pop();
      await pause(tester);
    }
    await tester.ensureVisible(find.text('العربية').first);
    await tester.tap(find.text('العربية').first);
    await pause(tester);
    await app.supabase.auth.signOut();
    debugPrint('NATIVE_POS_QA_SESSION_CLOSED_NO_FINANCIAL_WRITES');
  });
}
