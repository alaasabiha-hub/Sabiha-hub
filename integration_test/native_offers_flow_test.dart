
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/offers_catalog.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native public packages show server data and open linked booking login',
    (t) async {
      const expectedService = String.fromEnvironment('TEST_EXPECTED_SERVICE');
      const expectedOffer = String.fromEnvironment('TEST_EXPECTED_OFFER');
      expect(expectedService, isNotEmpty);
      expect(expectedOffer, isNotEmpty);
      Future<void> wait(Finder f) async {
        for (var i = 0; i < 150; i++) {
          await t.pump(const Duration(milliseconds: 200));
          if (f.evaluate().isNotEmpty) return;
        }
        throw TestFailure('Native offers control not reached');
      }

      await app.main();
      await wait(find.byKey(const ValueKey('welcome_offers')));
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('welcome_offers')),
        250,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await t.tap(find.byKey(const ValueKey('welcome_offers')));
      await wait(find.byType(OffersCatalogPage));
      final card = find.byKey(const ValueKey('promotion-$expectedOffer'));
      await t.scrollUntilVisible(
        card,
        250,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await t.pump(const Duration(seconds: 1));
      expect(
        t.takeException(),
        isNull,
        reason: 'Native offer cards must not overflow',
      );
      debugPrint('NATIVE_OFFERS_SCREEN_READY');
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 10)));
      final book = find.descendant(of: card, matching: find.text('احجز الآن'));
      await t.ensureVisible(book);
      await t.tap(book);
      await wait(find.byType(app.CustomerLoginScreen));
      final login = t.widget<app.CustomerLoginScreen>(
        find.byType(app.CustomerLoginScreen),
      );
      expect(login.openBookingAfterLogin, isTrue);
      expect(login.bookingServiceId, expectedService);
      expect(t.takeException(), isNull);
      debugPrint('NATIVE_OFFERS_LINKED_BOOKING_PASSED');
    },
  );
}
