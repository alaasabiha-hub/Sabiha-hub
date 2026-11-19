import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/invoice_printing.dart';
import 'package:sabiha_hub/printer_device_settings.dart';

import 'invoice_printing_test.dart' as routing;

const first = '11111111-1111-4111-8111-111111111111';
const second = '33333333-3333-4333-8333-333333333333';
const branch = '22222222-2222-4222-8222-222222222222';
List<Map<String, dynamic>> records() => [
  {
    'printer_id': first,
    'branch_id': branch,
    'name': 'Office A4',
    'paper': 'A4',
    'transport': 'system',
    'device_identifier': 'printer://front',
    'is_default': true,
    'is_active': true,
  },
  {
    'printer_id': second,
    'branch_id': branch,
    'name': 'Receipt 80',
    'paper': '80',
    'transport': 'wifi',
    'device_identifier': 'printer://receipt',
    'is_default': false,
    'is_active': true,
  },
];

class Gateway implements DevicePrinterGateway {
  Gateway(this.actor);
  @override
  final String actor;
  int reads = 0;
  bool denied = false;
  Completer<List<Map<String, dynamic>>>? deferred;
  @override
  Future<String> branch() async => branchId;
  String get branchId => '22222222-2222-4222-8222-222222222222';
  @override
  Future<List<Map<String, dynamic>>> profiles(String branch) async {
    reads++;
    if (denied) throw StateError('Denied');
    if (deferred != null) return deferred!.future;
    return records();
  }
}

class Store extends PrinterDeviceStore {
  final values = <String, PrinterDevicePreference>{};
  int writes = 0;
  @override
  Future<PrinterDevicePreference?> read(String actor, String branch) async =>
      values['$actor:$branch'];
  @override
  Future<void> save(
    String actor,
    InvoicePrintTarget target,
    bool direct,
  ) async {
    writes++;
    values['$actor:${target.branchId}'] = PrinterDevicePreference(
      target.profileId,
      direct,
    );
  }
}

Future<void> host(
  WidgetTester tester,
  DevicePrinterGateway gateway,
  Store store,
  routing.Driver driver,
  String lang, {
  bool settle = true,
  Key? key,
  Future<Uint8List> Function(InvoicePrintTarget)? diagnosticBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: DevicePrinterSettingsScreen(
        key: key,
        gateway: gateway,
        store: store,
        driver: driver,
        diagnosticBuilder: diagnosticBuilder,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
}

Future<void> click(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder field(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byType(DropdownButtonFormField<String>),
    )
    .first;
void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'device printer choice isolated and no automatic printing $language $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final g = Gateway('cashier-qa'),
              store = Store(),
              driver = routing.Driver();
          await host(tester, g, store, driver, language);
          expect(driver.directCalls + driver.dialogs, 0);
          await click(
            tester,
            field(
              language == 'ar' ? 'مقاس الورق المتاح' : 'Available paper size',
            ),
          );
          await click(tester, find.text('80 mm').last);
          await click(
            tester,
            field(
              language == 'ar'
                  ? 'طريقة الاتصال المتاحة'
                  : 'Available connection',
            ),
          );
          await click(
            tester,
            find
                .text(
                  language == 'ar'
                      ? 'Wi-Fi عبر خدمة النظام'
                      : 'Wi-Fi through OS service',
                )
                .last,
          );
          await click(
            tester,
            field(
              language == 'ar'
                  ? 'الطابعة الافتراضية لهذا الجهاز'
                  : 'Default printer for this device',
            ),
          );
          await click(tester, find.text('Receipt 80').last);
          await click(
            tester,
            find.text(
              language == 'ar' ? 'حفظ اختيار هذا الجهاز' : 'Save device choice',
            ),
          );
          expect(store.writes, 1);
          expect(store.values['cashier-qa:$branch']!.profileId, second);
          expect(store.values['cashier-qa:$branch']!.direct, false);
          expect(driver.directCalls + driver.dialogs, 0);
          expect(g.reads, 2);
          await host(tester, g, store, driver, language, key: UniqueKey());
          expect(find.text('Receipt 80'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final language in ['ar', 'en']) {
    testWidgets(
      'printer test requires explicit confirmation and cancellation sends nothing $language',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = Gateway('cashier-qa'),
            store = Store(),
            driver = routing.Driver();
        await host(tester, g, store, driver, language);
        await click(
          tester,
          find.text(language == 'ar' ? 'اختبار الطباعة' : 'Test printing'),
        );
        expect(
          find.text(
            language == 'ar' ? 'تأكيد اختبار الطابعة' : 'Confirm printer test',
          ),
          findsOneWidget,
        );
        expect(driver.directCalls + driver.dialogs, 0);
        await click(tester, find.text(language == 'ar' ? 'إلغاء' : 'Cancel'));
        expect(driver.directCalls + driver.dialogs, 0);
        expect(store.writes, 0);
      },
    );
  }
  testWidgets(
    'late printer save after account scope changes cannot persist under either actor',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final old = Gateway('old-cashier'),
          store = Store(),
          driver = routing.Driver();
      await host(tester, old, store, driver, 'en');
      old.deferred = Completer<List<Map<String, dynamic>>>();
      final save = find.text('Save device choice');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      await host(tester, Gateway('new-cashier'), store, driver, 'en');
      old.deferred!.complete(records());
      await tester.pumpAndSettle();
      expect(store.writes, 0);
      expect(driver.directCalls + driver.dialogs, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('denied profiles expose no print or save controls', (
    tester,
  ) async {
    final g = Gateway('no-cashier-permission')..denied = true,
        store = Store(),
        driver = routing.Driver();
    await host(tester, g, store, driver, 'ar');
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('اختبار الطباعة'), findsNothing);
    expect(store.writes, 0);
    expect(driver.dialogs + driver.directCalls, 0);
  });
  test('device default is one atomic value containing only profile UUID and direct mode', () async {
    SharedPreferences.setMockInitialValues({});
    final store = PrinterDeviceStore();
    final target = InvoicePrintTarget.fromProfile(records().first);
    await store.save('cashier-a', target, true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().length, 1);
    final raw = prefs.getString(store.key('cashier-a', branch))!;
    expect(jsonDecode(raw), {
      'version': 1,
      'profile_id': first,
      'direct': true,
    });
    expect(raw, isNot(contains('Office')));
    expect(raw, isNot(contains('printer://')));
    expect((await store.read('cashier-a', branch))!.direct, true);
    expect(await store.read('cashier-b', branch), isNull);
    await prefs.setString(store.key('cashier-a', branch), 'corrupt');
    expect(await store.read('cashier-a', branch), isNull);
  });
}
