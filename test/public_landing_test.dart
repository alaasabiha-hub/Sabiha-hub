import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/public_landing.dart';
import 'package:sabiha_hub/welcome_ui.dart' show approvedBrandAsset;

void main() {
  for (final locale in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 1024.0, 1440.0]) {
      testWidgets('Published-only empty public landing $locale $width', (
        t,
      ) async {
        t.view.physicalSize = Size(width, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        var reads = 0, services = 0;
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1100),
                textScaler: const TextScaler.linear(1.3),
              ),
              child: PublicLandingScreen(
                loadOffers: () async {
                  reads++;
                  return {'offers': []};
                },
                onServices: () => services++,
                onBooking: () {},
                onAccount: () {},
                onStaff: () {},
                onLanguage: () {},
                onBookOffer: (_) {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(reads, 1);
        final logo = t.widget<Image>(
          find.byKey(const ValueKey('public-original-logo')),
        );
        expect(logo.fit, BoxFit.contain);
        expect((logo.image as AssetImage).assetName, approvedBrandAsset);
        expect(find.textContaining('EGP'), findsNothing);
        expect(find.textContaining('SH20'), findsNothing);
        final empty = find.text(
          locale == 'ar'
              ? 'لا توجد باقات منشورة حاليًا'
              : 'No published packages right now',
        );
        await t.scrollUntilVisible(
          empty,
          200,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        final service = find.byKey(const ValueKey('public-services'));
        await Scrollable.ensureVisible(t.element(service), alignment: .4);
        await t.pumpAndSettle();
        await t.tap(service);
        expect(services, 1);
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final pair in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'Careers banner is last before the employee footer ${pair.$1}',
      (t) async {
        t.view.physicalSize = Size(pair.$2, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        var careers = 0, staff = 0;
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(pair.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: PublicLandingScreen(
              loadOffers: () async => {'offers': []},
              onServices: () {},
              onBooking: () {},
              onAccount: () {},
              onStaff: () => staff++,
              onCareers: () => careers++,
              onLanguage: () {},
              onBookOffer: (_) {},
            ),
          ),
        );
        await t.pumpAndSettle();
        final careersSection = find.byKey(
          const ValueKey('public-careers-section'),
        );
        final cta = find.byKey(const ValueKey('public-careers-cta'));
        if (pair.$2 < 700) {
          await t.tap(find.byTooltip(pair.$1 == 'ar' ? 'القائمة' : 'Menu'));
          await t.pumpAndSettle();
          final sidebar = find.byKey(const ValueKey('public-careers-sidebar'));
          expect(sidebar, findsOneWidget);
          await t.tap(sidebar);
        } else {
          final navigation = find.byKey(
            const ValueKey('public-careers-navigation'),
          );
          expect(navigation, findsOneWidget);
          await t.tap(navigation);
        }
        expect(careers, 1);
        await t.scrollUntilVisible(
          cta,
          220,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              )
              .first,
        );
        await t.ensureVisible(cta);
        await t.pumpAndSettle();
        expect(careersSection, findsOneWidget);
        expect(
          find.text(
            pair.$1 == 'ar'
                ? 'انضم لفريق Sabiha Hub'
                : 'Join the Sabiha Hub Team',
          ),
          findsOneWidget,
        );
        await t.tap(cta);
        expect(careers, 2);

        expect(
          find.byKey(const ValueKey('public-careers-footer')),
          findsNothing,
        );
        final employee = find.byKey(const ValueKey('public-staff-footer'));
        expect(employee, findsOneWidget);
        expect(
          t.getTopLeft(careersSection).dy,
          lessThan(t.getTopLeft(employee).dy),
        );
        expect(staff, 0);
        await Scrollable.ensureVisible(t.element(employee), alignment: .4);
        await t.pumpAndSettle();
        await t.tap(employee);
        expect(staff, 1);
        expect(careers, 2);
        expect(t.takeException(), isNull);
      },
    );
  }

  for (final locale in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 768.0, 1024.0, 1440.0]) {
      testWidgets('Brand stays centered $locale $width', (t) async {
        t.view.physicalSize = Size(width, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: PublicLandingScreen(
              loadOffers: () async => {'offers': []},
              onServices: () {},
              onBooking: () {},
              onAccount: () {},
              onStaff: () {},
              onCareers: () {},
              onLanguage: () {},
              onBookOffer: (_) {},
            ),
          ),
        );
        await t.pumpAndSettle();
        final center = t.getCenter(
          find.byKey(const ValueKey('public-header-brand')),
        );
        expect(center.dx, closeTo(width / 2, 1));
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'Unpriced published reward opens account details without an invented amount',
    (t) async {
      var accounts = 0;
      await t.pumpWidget(
        MaterialApp(
          home: PublicLandingScreen(
            loadOffers: () async => {
              'offers': [
                {
                  'offer_id': 'isolated-reward',
                  'name': 'Isolated reward',
                  'description': 'Test-only reward',
                  'category': 'reward',
                  'price': null,
                  'service_id': null,
                  'visits_required': 3,
                },
              ],
            },
            onServices: () {},
            onBooking: () {},
            onAccount: () => accounts++,
            onStaff: () {},
            onLanguage: () {},
            onBookOffer: (_) {
              throw StateError('Unlinked reward cannot create a booking');
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(
        find.byKey(const ValueKey('public-category-reward')),
      );
      await t.tap(find.byKey(const ValueKey('public-category-reward')));
      await t.pumpAndSettle();
      final details = find.text('View details');
      await t.scrollUntilVisible(
        details,
        200,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await t.ensureVisible(details);
      await t.pumpAndSettle();
      await t.tap(details);
      expect(accounts, 1);
      expect(find.textContaining('EGP'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('Failed read exposes retry, never example offers or prices', (
    t,
  ) async {
    var reads = 0;
    await t.pumpWidget(
      MaterialApp(
        home: PublicLandingScreen(
          loadOffers: () async {
            reads++;
            if (reads == 1) throw StateError('offline');
            return {'offers': []};
          },
          onServices: () {},
          onBooking: () {},
          onAccount: () {},
          onStaff: () {},
          onLanguage: () {},
          onBookOffer: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    final retry = find.text('Retry');
    await t.scrollUntilVisible(
      retry,
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await t.ensureVisible(retry);
    await t.pumpAndSettle();
    await t.tap(retry);
    await t.pumpAndSettle();
    expect(reads, 2);
    expect(find.textContaining('EGP'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
