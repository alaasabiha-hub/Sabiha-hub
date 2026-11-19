import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/admin_console.dart';
import 'package:sabiha_hub/customer_visuals.dart';

import 'admin_console_test.dart' show start;

Widget bell() => IconButton(
  key: const Key('new_header_inbox'),
  onPressed: () {},
  icon: const Icon(Icons.notifications_none),
);
void main() {
  for (final config in [('ar', 320.0), ('en', 660.0)]) {
    testWidgets(
      'owner header retains complete single-line brand with inbox ${config.$1} ${config.$2}',
      (tester) async {
        final client = await start(tester, width: config.$2, lang: config.$1);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(config.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: AdminConsole(
              client: client,
              onLogout: () {},
              fullName: 'Isolated layout fixture',
              notificationAction: bell(),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('new_header_inbox')), findsOneWidget);
        final brand = tester.widget<Text>(
          find.byKey(const ValueKey('admin-brand-name')),
        );
        expect(brand.data, 'Sabiha Hub');
        expect(brand.maxLines, 1);
        expect(brand.softWrap, false);
        final logo = tester.widget<Image>(
          find.descendant(
            of: find.byKey(const ValueKey('admin-full-original-logo')),
            matching: find.byType(Image),
          ),
        );
        expect(logo.fit, BoxFit.contain);
        final viewport = Rect.fromLTWH(
          0,
          0,
          config.$2,
          tester.view.physicalSize.height,
        );
        expect(
          viewport.contains(
            tester.getRect(find.byKey(const Key('new_header_inbox'))).center,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
      },
    );
  }
  testWidgets(
    'customer header keeps existing bell position and complete brand at 320 RTL',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: CustomerHero(
              title: 'الرئيسية',
              subtitle: '',
              onMenu: () {},
              notificationAction: bell(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sabiha Hub'), findsOneWidget);
      final rect = tester.getRect(find.byKey(const Key('new_header_inbox')));
      expect(rect.left, greaterThan(200));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}
