import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/main.dart';
import 'package:sabiha_hub/welcome_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Public home keeps official slogans only and retains all destinations',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HubWelcomeScreen(
            arabic: true,
            onLanguage: (_) {},
            onLogin: () {},
            onBook: () {},
            onServices: () {},
            onStaff: () {},
            onOffers: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('مفهوم جديد للعناية المتكاملة'), findsOneWidget);
      expect(find.text('A New Concept in Total Care'), findsOneWidget);
      for (final phrase in [
        'غسيل احترافي',
        'تلميع',
        'خدمات متكاملة',
        'العناية المتكاملة لسيارتك',
        'Professional Wash',
        'Polishing',
        'Complete Care',
      ]) {
        expect(find.textContaining(phrase), findsNothing);
      }
      for (final key in [
        'welcome_book',
        'welcome_services',
        'welcome_login',
        'welcome_staff',
        'welcome_offers',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [
    const Size(320, 568),
    const Size(360, 640),
    const Size(390, 844),
    const Size(430, 932),
    const Size(844, 390),
  ]) {
    for (final ar in [true, false]) {
      testWidgets(
        'welcome fits $size ${ar ? 'Arabic' : 'English'} including enlarged text',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: Directionality(
                  textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                  child: HubWelcomeScreen(
                    arabic: ar,
                    onLanguage: (_) {},
                    onLogin: () {},
                    onBook: () {},
                    onServices: () {},
                    onStaff: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('welcome_book')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('welcome_services')),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('welcome_staff')),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('all public buttons invoke their actual destination handlers', (
    tester,
  ) async {
    var login = 0, book = 0, services = 0, staff = 0;
    String? language;
    await tester.pumpWidget(
      MaterialApp(
        home: HubWelcomeScreen(
          arabic: true,
          onLanguage: (v) => language = v,
          onLogin: () => login++,
          onBook: () => book++,
          onServices: () => services++,
          onStaff: () => staff++,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('welcome_login')));
    await tester.tap(find.byKey(const ValueKey('welcome_language_en')));
    await tester.ensureVisible(find.byKey(const ValueKey('welcome_book')));
    await tester.tap(find.byKey(const ValueKey('welcome_book')));
    await tester.tap(find.byKey(const ValueKey('welcome_services')));
    await tester.ensureVisible(find.byKey(const ValueKey('welcome_staff')));
    await tester.tap(find.byKey(const ValueKey('welcome_staff')));
    expect([login, book, services, staff], [1, 1, 1, 1]);
    expect(language, 'en');
  });
  testWidgets(
    'repeated root language changes persist and survive reopening safely',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const SabihaHubApp());
      await tester.pumpAndSettle();
      final language = find.byKey(const ValueKey('public-language'));
      for (final expected in ['en', 'ar', 'en']) {
        await tester.tap(language);
        await tester.pumpAndSettle();
        expect(
          Localizations.localeOf(tester.element(language)).languageCode,
          expected,
        );
        expect(tester.takeException(), isNull);
      }
      expect(find.byTooltip('Sign in'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('app_language'),
        'en',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const SabihaHubApp());
      await tester.pumpAndSettle();
      expect(find.byTooltip('Sign in'), findsOneWidget);
      expect(
        Localizations.localeOf(tester.element(find.byKey(const ValueKey('public-language')))).languageCode,
        'en',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'book button requires customer login and retains the booking destination',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const SabihaHubApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('القائمة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('الحجز').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CustomerLoginScreen>(find.byType(CustomerLoginScreen))
            .openBookingAfterLogin,
        isTrue,
      );
    },
  );
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'staff entry is footer-only and opens staff authentication $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(const SabihaHubApp());
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('public-staff-login')), findsNothing);
        expect(
          find.byKey(const ValueKey('public-client-login')),
          findsOneWidget,
        );
        if (width < 600) {
          await tester.tap(find.byTooltip('القائمة'));
          await tester.pumpAndSettle();
          final drawer = find.byType(Drawer);
          expect(
            find.descendant(of: drawer, matching: find.text('دخول الموظفين')),
            findsNothing,
          );
          expect(
            find.descendant(of: drawer, matching: find.text('تسجيل الدخول')),
            findsOneWidget,
          );
          Navigator.of(tester.element(drawer)).pop();
          await tester.pumpAndSettle();
        }
        expect(find.text('دخول الموظفين'), findsOneWidget);
        final footer = find.byKey(const ValueKey('public-staff-footer'));
        await tester.scrollUntilVisible(
          footer,
          250,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await tester.ensureVisible(footer);
        await tester.pumpAndSettle();
        await tester.tap(footer);
        await tester.pumpAndSettle();
        expect(find.byType(StaffLoginScreen), findsOneWidget);
        expect(find.byType(CustomerDashboardScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
