import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/owner_reports.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const email = String.fromEnvironment('TEST_CUSTOMER_EMAIL');
  const password = String.fromEnvironment('TEST_PASSWORD');
  const ownerEmail = String.fromEnvironment('TEST_OWNER_EMAIL');
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets('local native customer signs in and owner opens real report', (
    tester,
  ) async {
    expect(
      email,
      isNotEmpty,
      reason: 'Provide synthetic local test credentials only',
    );
    await app.main();
    await settle(tester);
    debugPrint('LOCAL E2E home rendered');
    await tester.tap(find.text('دخول العميل'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), email);
    await tester.enterText(find.byType(TextField).at(1), password);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.text('تسجيل الدخول'));
    await tester.tap(find.text('تسجيل الدخول'));
    await settle(tester);
    debugPrint('LOCAL E2E customer login completed');
    expect(app.supabase.auth.currentUser?.email, email);
    expect(find.text('تسجيل الدخول'), findsNothing);
    await app.supabase.auth.signOut();
    await app.supabase.auth.signInWithPassword(
      email: ownerEmail,
      password: password,
    );
    await tester.pumpWidget(
      MaterialApp(home: OwnerReportsScreen(client: app.supabase)),
    );
    await settle(tester);
    debugPrint('LOCAL E2E owner report rendered');
    expect(find.text('Owner reports'), findsOneWidget);
    expect(find.text('Active sales'), findsOneWidget);
    expect(
      find.text('Could not load report. Check connection and owner access.'),
      findsNothing,
    );
    await app.supabase.auth.signOut();
  });
}
