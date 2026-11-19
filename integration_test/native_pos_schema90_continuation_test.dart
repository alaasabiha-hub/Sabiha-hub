// Local QA only: real owner login and POS navigation, without saving a draft.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/app_config.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/cashier_invoice_draft.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const owner = String.fromEnvironment('TEST_OWNER_ID');
  const email = String.fromEnvironment('TEST_OWNER_EMAIL');
  const password = String.fromEnvironment('TEST_OWNER_PASSWORD');

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return;
    }
    final pos = find.byType(CashierInvoiceDraftScreen);
    if (pos.evaluate().isNotEmpty) {
      final w = tester.widget<CashierInvoiceDraftScreen>(pos);
      for (final element
          in find
              .descendant(of: pos, matching: find.byType(Scrollable))
              .evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        debugPrint(
          'NATIVE_POS_SCROLL axis=${state.axisDirection} offset=${state.position.pixels} max=${state.position.maxScrollExtent}',
        );
      }
      debugPrint(
        'NATIVE_POS_PROGRESS count=${find.descendant(of: pos, matching: find.byType(LinearProgressIndicator)).evaluate().length} buttons=${find.descendant(of: pos, matching: find.byType(FilledButton)).evaluate().length}',
      );
      debugPrint(
        'NATIVE_POS_DIAGNOSTIC locale=${Localizations.localeOf(tester.element(pos)).languageCode} gateway_current=${w.gateway.current} save_ar=${find.text('حفظ المسودة وحساب السعر من الخادم').evaluate().length} save_en=${find.text('Save draft and calculate on server').evaluate().length} signin_ar=${find.text('أعد تسجيل الدخول لعرض المسودة.').evaluate().length} signin_en=${find.text('Sign in again to view the draft.').evaluate().length}',
      );
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

    await app.main();
    await pause(tester);
    if (app.supabase.auth.currentUser == null) {
      await app.supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
    }
    expect(app.supabase.auth.currentUser?.id, owner);
    final profile = await app.supabase
        .from('staff_profiles')
        .select('role,permissions,full_name')
        .eq('user_id', owner)
        .single();
    expect(profile['role'], 'owner');
    app.appNavigatorKey.currentState!.pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => app.StaffDashboardScreen(
          role: profile['role'],
          permissions: Map<String, dynamic>.from(profile['permissions'] ?? {}),
          fullName: profile['full_name'],
        ),
      ),
      (_) => false,
    );
    await waitFor(tester, find.byType(app.StaffDashboardScreen));
    debugPrint('NATIVE_POS_VERIFIED_EXISTING_QA_OWNER_SESSION');
    for (final lang in ['ar', 'en']) {
      final ar = lang == 'ar';
      if (Localizations.localeOf(
            tester.element(find.byType(app.StaffDashboardScreen)),
          ).languageCode !=
          lang) {
        final language = find.text(ar ? 'العربية' : 'English').first;
        await tester.ensureVisible(language);
        await pause(tester);
        await tester.tap(language);
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
      // A live catalogue load can move lazy children after an early scroll.
      // Wait for its progress bar to finish before locating the draft actions.
      for (var i = 0; i < 160; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find
            .descendant(
              of: find.byType(CashierInvoiceDraftScreen),
              matching: find.byType(LinearProgressIndicator),
            )
            .evaluate()
            .isEmpty) {
          await pause(tester);
          break;
        }
      }
      await tester.scrollUntilVisible(
        find.text(
          ar
              ? 'حفظ المسودة وحساب السعر من الخادم'
              : 'Save draft and calculate on server',
        ),
        500,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
        maxScrolls: 60,
        duration: const Duration(milliseconds: 250),
      );
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
