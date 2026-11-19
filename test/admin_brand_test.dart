import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/admin_console.dart';
import 'package:sabiha_hub/welcome_ui.dart' show approvedBrandAsset;

import 'admin_console_test.dart' show start;

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 768.0, 1440.0]) {
      testWidgets(
        'Complete single-line brand and horizontally reachable sections $lang $width',
        (tester) async {
          final client = await start(tester, width: width, lang: lang);
          tester.view.physicalSize = Size(width, width < 600 ? 700 : 1000);
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(lang),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: AdminConsole(client: client, onLogout: () {}),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)),
          );
          await tester.pumpAndSettle();
          final logo = find.byKey(const ValueKey('admin-full-original-logo'));
          final image = tester.widget<Image>(
            find.descendant(of: logo, matching: find.byType(Image)),
          );
          expect((image.image as AssetImage).assetName, approvedBrandAsset);
          expect(image.fit, BoxFit.contain);
          expect(
            find.descendant(of: logo, matching: find.byType(ClipRect)),
            findsNothing,
          );
          expect(
            find.descendant(of: logo, matching: find.byType(ClipPath)),
            findsNothing,
          );
          final name = tester.widget<Text>(
            find.byKey(const ValueKey('admin-brand-name')),
          );
          expect(name.data, 'Sabiha Hub');
          expect(name.maxLines, 1);
          expect(name.softWrap, false);
          expect(
            tester
                .widget<FittedBox>(
                  find.byKey(const ValueKey('admin-brand-name-fit')),
                )
                .fit,
            BoxFit.scaleDown,
          );
          final viewport = Rect.fromLTWH(0, 0, width, width < 600 ? 700 : 1000);
          expect(
            tester
                .getRect(find.byKey(const ValueKey('admin-nav-overview')))
                .overlaps(viewport),
            isTrue,
          );
          if (width < 1100) {
            await tester.drag(
              find.byKey(const ValueKey('admin-section-scroll')),
              const Offset(-1800, 0),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('admin-nav-settings')))
                  .overlaps(viewport),
              isTrue,
            );
          }
          expect(adminSections.map((s) => s.$1).toList(), [
            'overview',
            'reports',
            'products',
            'inventory',
            'employees',
            'schedules',
            'crm',
            'establishment',
            'security',
            'settings',
          ]);
          expect(tester.takeException(), isNull);
          await tester.runAsync(client.dispose);
        },
      );
    }
  }
}
