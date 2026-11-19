import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  testWidgets('staff login opens the shared secure recovery flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: StaffLoginScreen()),
    );
    await tester.pumpAndSettle();

    final recoveryLink = find.byKey(const ValueKey('staff-forgot-password'));
    expect(recoveryLink, findsOneWidget);
    await tester.tap(recoveryLink);
    await tester.pumpAndSettle();

    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
