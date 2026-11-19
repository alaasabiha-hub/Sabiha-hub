import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'invoice_printing_test.dart' as routing;
import 'printer_device_settings_test.dart' as settings;

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets(
      'explicit diagnostic confirmation uses unified injected driver $lang',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = settings.Gateway('cashier-qa'),
            store = settings.Store(),
            driver = routing.Driver();
        final bytes = Uint8List.fromList(
          '%PDF-1.7\nQA dispatch only'.codeUnits,
        );
        await settings.host(
          tester,
          gateway,
          store,
          driver,
          lang,
          diagnosticBuilder: (target) async {
            expect(target.profileId, settings.first);
            return bytes;
          },
        );
        await settings.click(
          tester,
          find.text(lang == 'ar' ? 'اختبار الطباعة' : 'Test printing'),
        );
        expect(driver.dialogs, 0);
        await settings.click(
          tester,
          find.text(lang == 'ar' ? 'طباعة الاختبار' : 'Print test'),
        );
        expect(driver.dialogs, 1);
        expect(driver.directCalls, 0);
        expect(driver.bytes, same(bytes));
        expect(gateway.reads, 2);
        expect(store.writes, 0);
        expect(
          find.text(
            lang == 'ar'
                ? 'أُرسلت الصفحة إلى خدمة النظام؛ لم يُتحقق من خروج الورق.'
                : 'Page submitted to OS service; physical output is not verified.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'cashier permission is checked again after test confirmation before any dispatch',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = settings.Gateway('cashier-qa'),
          store = settings.Store(),
          driver = routing.Driver();
      var builds = 0;
      await settings.host(
        tester,
        gateway,
        store,
        driver,
        'en',
        diagnosticBuilder: (target) async {
          builds++;
          return Uint8List.fromList('%PDF-QA'.codeUnits);
        },
      );
      await settings.click(tester, find.text('Test printing'));
      gateway.denied = true;
      await settings.click(tester, find.text('Print test'));
      expect(builds, 0);
      expect(driver.dialogs + driver.directCalls, 0);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
