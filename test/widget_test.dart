import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app opens on the Arabic home screen by default', (tester) async {
    await tester.pumpWidget(const SabihaHubApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('public-premium-hero')), findsOneWidget);
    expect(find.text('لأن سيارتك تستحق الأفضل'), findsOneWidget);
    expect(find.byKey(const ValueKey('public-client-login')), findsOneWidget);
    expect(find.byKey(const ValueKey('public-staff-footer')), findsOneWidget);
  });
}
