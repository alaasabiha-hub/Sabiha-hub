import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offer_management.dart';

void main() {
  Future<void> open(
    WidgetTester t, {
    bool denied = false,
    String locale = 'ar',
    List<Map<String, dynamic>> services = const [],
    List<Map<String, dynamic>> offers = const [],
    void Function(Map<String, dynamic>)? save,
  }) async {
    late SupabaseClient client;
    await t.runAsync(() async {
      client = SupabaseClient(
        'http://localhost:54321',
        'test',
        accessToken: () async => 'test',
        httpClient: MockClient((r) async {
          if (r.url.path.endsWith('/get_owner_promotions')) {
            return http.Response(
              jsonEncode(
                denied
                    ? {'message': 'Denied', 'code': '42501'}
                    : {
                        'branch_id': 'default-test',
                        'services': services,
                        'offers': offers,
                      },
              ),
              denied ? 403 : 200,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }
          expect(r.url.path, endsWith('/save_service_promotion'));
          save?.call(Map<String, dynamic>.from(jsonDecode(r.body)));
          return http.Response(
            '{"service_id":"created-test-service","offer_id":null}',
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
      );
    });
    addTearDown(client.dispose);
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OfferManagementScreen(client: client),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pumpAndSettle();
  }

  testWidgets('Denied owner context exposes no service/price editor', (
    t,
  ) async {
    await open(t, denied: true);
    expect(find.text('إضافة خدمة'), findsNothing);
    expect(find.textContaining('صلاحية المالك'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('linked service dropdown stays valid when RPC repeats a service', (
    t,
  ) async {
    final repeated = {
      'item_id': '033654d2-a2e2-48fb-8d62-a08206fd692f',
      'name': 'Wash',
      'name_en': 'Wash',
      'price': 100,
      'duration_minutes': 30,
      'is_active': true,
      'is_public': true,
    };
    await open(t, locale: 'en', services: [repeated, {...repeated}]);
    await t.tap(find.text('Add linked offer'));
    await t.pumpAndSettle();
    final dropdown = find.byType(DropdownButtonFormField<String>).first;
    final menu = t.widget<DropdownButton<String>>(
      find.descendant(of: dropdown, matching: find.byType(DropdownButton<String>)),
    );
    expect(
      menu.items!.where((item) => item.value == repeated['item_id']),
      hasLength(1),
    );
    await t.tap(dropdown);
    await t.pumpAndSettle();
    expect(find.text('Wash'), findsWidgets);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'New actual service sends entered Arabic price and stable request, no demo default',
    (t) async {
      final writes = <Map<String, dynamic>>[];
      await open(t, save: writes.add);
      await t.tap(find.text('إضافة خدمة'));
      await t.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await t.enterText(field('اسم الخدمة بالعربية'), 'خدمة اختبار معزولة');
      await t.enterText(field('سعر الخدمة الفعلي EGP'), '١٢٣٫٤٥');
      await t.ensureVisible(find.text('حفظ'));
      await t.tap(find.text('حفظ'));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(writes.single['p_service']['price'], 123.45);
      expect(writes.single['p_service']['duration_minutes'], 60);
      expect(writes.single['p_offer'], isNull);
      expect(writes.single['p_request'], isNotEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  for (final scenario in [(390.0, 'ar'), (1440.0, 'en')]) {
    testWidgets(
      'Owner publishes linked package with actual price ${scenario.$2} ${scenario.$1}',
      (t) async {
        t.view.physicalSize = Size(scenario.$1, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final ar = scenario.$2 == 'ar';
        final writes = <Map<String, dynamic>>[];
        await open(
          t,
          locale: scenario.$2,
          save: writes.add,
          services: [
            {
              'item_id': 'isolated-service',
              'name': 'خدمة اختبار معزولة',
              'price': 137.45,
              'duration_minutes': 45,
              'resource_key': 'wash',
              'is_active': true,
              'is_public': true,
              'updated_at': '2026-11-14T00:00:00Z',
            },
          ],
          offers: [
            {
              'offer_id': 'isolated-offer',
              'catalog_item_id': 'isolated-service',
              'name': 'باقة اختبار معزولة',
              'presentation_category': 'package',
              'compare_price': 160,
              'is_active': false,
              'is_public': false,
              'updated_at': '2026-11-14T00:00:00Z',
            },
          ],
        );
        await t.ensureVisible(
          find.byTooltip(ar ? 'تعديل العرض' : 'Edit offer'),
        );
        await t.tap(find.byTooltip(ar ? 'تعديل العرض' : 'Edit offer'));
        await t.pumpAndSettle();
        for (final label in [
          ar ? 'تفعيل العرض' : 'Offer active',
          ar ? 'نشر العرض للعملاء' : 'Publish offer to customers',
        ]) {
          final toggle = find.widgetWithText(SwitchListTile, label);
          await t.ensureVisible(toggle);
          await t.pumpAndSettle();
          await t.tap(toggle);
          await t.pumpAndSettle();
        }
        await t.tap(find.text(ar ? 'حفظ' : 'Save'));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pumpAndSettle();
        expect(writes, hasLength(1));
        expect(writes.single['p_service']['item_id'], 'isolated-service');
        expect(writes.single['p_service']['price'], 137.45);
        expect(writes.single['p_service']['duration_minutes'], 45);
        expect(writes.single['p_offer']['offer_id'], 'isolated-offer');
        expect(writes.single['p_offer']['is_active'], isTrue);
        expect(writes.single['p_offer']['is_public'], isTrue);
        expect(t.takeException(), isNull);
      },
    );
  }
}
