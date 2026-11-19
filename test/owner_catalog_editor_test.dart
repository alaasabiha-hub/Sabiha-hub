import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sabiha_hub/owner_catalog_editor.dart';
import 'package:sabiha_hub/owner_tax_invoice_settings.dart';

class Gateway implements OwnerTaxGateway {
  bool live = true;
  bool duplicateItems = false;
  final events = StreamController<void>.broadcast();
  final saves = <Map<String, dynamic>>[];
  @override
  bool get current => live;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_owner_catalog_items') {
      return {
        'branch': 'branch',
        'has_more': false,
        'vehicle_classes': [
          {
            'class_code': 'sedan',
            'name_ar': 'سيدان',
            'name_en': 'Sedan',
            'is_active': true,
          },
          {
            'class_code': 'suv',
            'name_ar': 'دفع رباعي',
            'name_en': 'SUV / 4WD',
            'is_active': true,
          },
        ],
        'items': [
          {
            'item_id': 'product',
            'item_type': 'product',
            'name': 'منتج',
            'name_en': 'QA product',
            'price': 50,
            'duration_minutes': 60,
            'is_active': true,
            'is_public': false,
            'category': null,
            'image_url': null,
            'revision': 'one',
          },
          if (duplicateItems)
            {
              'item_id': 'product',
              'item_type': 'product',
              'name': 'منتج مكرر',
              'name_en': 'Duplicate QA product',
              'price': 50,
              'duration_minutes': 60,
              'is_active': true,
              'is_public': false,
              'revision': 'one',
            },
        ],
      };
    }
    if (name == 'save_owner_catalog_item_with_vehicle_prices') {
      saves.add(params);
      return {'item_id': 'product', 'revision': 'two'};
    }
    throw StateError('Unexpected action');
  }
}

void main() {
  testWidgets('duplicate catalogue IDs do not crash the item dropdown', (
    tester,
  ) async {
    final gateway = Gateway()..duplicateItems = true;
    addTearDown(gateway.events.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerCatalogEditor(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Add service or product'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('QA product'), findsOneWidget);
  });

  for (final ar in [true, false]) {
    testWidgets(
      'Owner catalogue price edit ${ar ? 'ar mobile' : 'en desktop'}',
      (tester) async {
        tester.view.physicalSize = Size(ar ? 390 : 1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = Gateway();
        addTearDown(g.events.close);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(ar ? 'ar' : 'en'),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: OwnerCatalogEditor(gateway: g),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(ar ? 'إضافة خدمة أو منتج' : 'Add service or product'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(ar ? 'منتج' : 'QA product').last);
        await tester.pumpAndSettle();
        final price = find.byKey(const ValueKey('owner_catalog_price'));
        await tester.ensureVisible(price);
        await tester.enterText(price, ar ? '٧٠' : '70');
        final reason = find.byKey(const ValueKey('owner_catalog_reason'));
        await tester.ensureVisible(reason);
        await tester.enterText(reason, 'QA owner price change');
        final save = find.widgetWithText(
          FilledButton,
          ar ? 'حفظ الكتالوج' : 'Save catalogue',
        );
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(g.saves.single['p_item'], 'product');
        expect(g.saves.single['p_expected_revision'], 'one');
        expect((g.saves.single['p_spec'] as Map)['price'], 70);
        expect(g.saves.single['p_vehicle_prices'], isEmpty);
        expect(
          (g.saves.single['p_spec'] as Map).containsKey('stock_quantity'),
          false,
        );
        g.live = false;
        g.events.add(null);
        await tester.pumpAndSettle();
        expect(
          find.text(ar ? 'أعد تسجيل الدخول.' : 'Sign in again.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('new service requires independent Sedan and SUV prices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final g = Gateway();
    addTearDown(g.events.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerCatalogEditor(gateway: g),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('owner_catalog_name')),
      'غسيل تجريبي',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_catalog_name_en')),
      'QA wash',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_catalog_price')),
      '100',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_catalog_duration_minutes')),
      '60',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_catalog_reason')),
      'QA class pricing setup',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_vehicle_price_sedan')),
      '125',
    );
    await tester.enterText(
      find.byKey(const ValueKey('owner_vehicle_price_suv')),
      '175',
    );
    final save = find.byKey(const ValueKey('owner_catalog_save'));
    await tester.scrollUntilVisible(
      save,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(g.saves, hasLength(1));
    expect(g.saves.single['p_vehicle_prices'], [
      {'class_code': 'sedan', 'price': 125},
      {'class_code': 'suv', 'price': 175},
    ]);
    expect(tester.takeException(), isNull);
  });
}
