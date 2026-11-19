import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Route<dynamic>? publicTestRoute(RouteSettings settings) {
    final Widget page = switch (settings.name) {
      '/account' || '/login' => const CustomerLoginScreen(),
      '/booking' => const CustomerLoginScreen(openBookingAfterLogin: true),
      '/shop' => const Scaffold(body: Text('Product shop')),
      '/services' => const Scaffold(body: Text('Services')),
      '/staff-login' => const Scaffold(body: Text('Staff sign in')),
      '/careers' => const Scaffold(body: Text('Careers')),
      _ => const Scaffold(body: Text('Public route')),
    };
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }

  Future<void> pumpPublicHome(
    WidgetTester tester, {
    String language = 'ar',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        onGenerateRoute: publicTestRoute,
        home: HomeScreen(
          locale: Locale(language),
          onLanguageChanged: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('guest can return from customer login to the same public home', (
    tester,
  ) async {
    await pumpPublicHome(tester);

    expect(
      find.byKey(const ValueKey('public-reference-header')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('public-premium-hero')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('public-client-login')));
    await tester.pumpAndSettle();
    expect(find.text('دخول العميل'), findsOneWidget);

    Navigator.of(tester.element(find.byType(CustomerLoginScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('public-premium-hero')), findsOneWidget);
    expect(find.text('لأن سيارتك تستحق الأفضل'), findsOneWidget);
  });

  testWidgets('English mobile public home retains the public layout', (
    tester,
  ) async {
    await pumpPublicHome(tester, language: 'en');

    expect(
      find.byKey(const ValueKey('public-reference-header')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('public-premium-hero')), findsOneWidget);
    expect(find.text('Because Your Car Deserves the Best'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop header exposes the shop and keeps staff entry out of it',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          onGenerateRoute: publicTestRoute,
          home: HomeScreen(
            locale: const Locale('en'),
            onLanguageChanged: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Shop'), findsOneWidget);
      expect(find.byKey(const ValueKey('public-client-login')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('public-reference-header')),
          matching: find.text('Staff sign in'),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('public-staff-footer')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Shop'));
      await tester.pumpAndSettle();
      expect(find.text('Product shop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
