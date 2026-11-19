import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/inventory_purchasing.dart';

Map<String, dynamic> fixture() => {
  'branch_id': 'branch-a',
  'branches': [
    {
      'branch_id': 'branch-a',
      'name_ar': 'فرع اختبار',
      'name_en': 'Test branch',
    },
    {
      'branch_id': 'branch-a',
      'name_ar': 'فرع اختبار مكرر',
      'name_en': 'Duplicate test branch',
    },
  ],
  'products': [
    {
      'item_id': 'product-a',
      'name': 'Counted product',
      'stock_quantity': 5,
      'is_active': true,
    },
    {
      'item_id': 'product-a',
      'name': 'Duplicate counted product',
      'stock_quantity': 5,
      'is_active': true,
    },
    {
      'item_id': 'product-b',
      'name': 'Uncounted product',
      'stock_quantity': null,
      'is_active': true,
    },
  ],
  'suppliers': [
    {
      'supplier_id': 'supplier-a',
      'name': 'Test supplier',
      'phone': 'LOCAL',
      'tax_reference': '',
      'is_active': true,
    },
    {
      'supplier_id': 'supplier-a',
      'name': 'Duplicate test supplier',
      'phone': 'LOCAL',
      'tax_reference': '',
      'is_active': true,
    },
  ],
  'purchases': [
    {
      'purchase_id': 'purchase-a',
      'supplier_name': 'Test supplier',
      'invoice_reference': 'INV-A',
      'status': 'draft',
      'total_cost': 37.5,
      'lines': [
        {'name': 'Counted product', 'quantity': 3, 'unit_cost': 12.5},
      ],
    },
  ],
  'movements': [],
};
Future<SupabaseClient> start(
  WidgetTester t, {
  String language = 'en',
  double width = 390,
  bool denied = false,
  required Future<http.Response> Function(http.Request) write,
  VoidCallback? changed,
}) async {
  late SupabaseClient client;
  await t.runAsync(() async {
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      accessToken: () async => 'test',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('get_inventory_context')) {
          return http.Response(
            jsonEncode(
              denied ? {'code': '42501', 'message': 'denied'} : fixture(),
            ),
            denied ? 403 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: r,
          );
        }
        return write(r);
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: InventoryPurchasingPanel(
              client: client,
              branchId: 'branch-a',
              onStockChanged: changed ?? () {},
              onBranchSelected: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await t.pumpAndSettle();
  return client;
}

http.Response ok(http.Request r) => http.Response(
  '"saved-id"',
  200,
  headers: {'content-type': 'application/json'},
  request: r,
);
Future<void> settled(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('duplicate purchase option IDs keep the dialog usable', (
    t,
  ) async {
    final c = await start(t, write: (r) async => ok(r));
    await t.tap(find.text('New purchase order'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    await t.runAsync(c.dispose);
  });

  testWidgets('Denied inventory context exposes no purchasing controls', (
    t,
  ) async {
    final c = await start(t, denied: true, write: (r) async => ok(r));
    expect(find.text('New purchase order'), findsNothing);
    expect(find.textContaining('not authorized'), findsOneWidget);
    await t.runAsync(c.dispose);
  });
  testWidgets(
    'Purchase form retains request ID across a failed retry and sends entered cost',
    (t) async {
      final requests = <Map>[];
      final c = await start(
        t,
        width: 320,
        write: (r) async {
          expect(r.url.path, endsWith('/create_inventory_purchase'));
          requests.add(jsonDecode(r.body) as Map);
          return requests.length == 1
              ? http.Response(
                  '{"message":"retry","code":"P0001"}',
                  503,
                  headers: {'content-type': 'application/json'},
                  request: r,
                )
              : ok(r);
        },
      );
      await t.tap(find.text('New purchase order'));
      await t.pumpAndSettle();
      final dropdown = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<String>,
        ),
      );
      await t.tap(dropdown.at(0));
      await t.pumpAndSettle();
      await t.tap(find.text('Test supplier').last);
      await t.pumpAndSettle();
      await t.tap(dropdown.at(1));
      await t.pumpAndSettle();
      await t.tap(find.text('Counted product').last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextFormField).at(0), 'INV-UI');
      await t.enterText(find.byType(TextFormField).at(1), '3');
      await t.enterText(find.byType(TextFormField).at(2), '12.50');
      await t.ensureVisible(find.text('Save purchase order'));
      await t.tap(find.text('Save purchase order'));
      await settled(t);
      await t.tap(find.text('Save purchase order'));
      await settled(t);
      expect(requests.length, 2);
      expect(requests[0]['p_request'], requests[1]['p_request']);
      expect(requests.last['p_branch'], 'branch-a');
      expect(requests.last['p_lines'], [
        {'item_id': 'product-a', 'quantity': 3, 'unit_cost': 12.5},
      ]);
      expect(requests.last.containsKey('p_actor'), isFalse);
      expect(t.takeException(), isNull);
      await t.runAsync(c.dispose);
    },
  );
  testWidgets(
    'Arabic opening count requires explicit quantity and reason before server mutation',
    (t) async {
      var writes = 0, changes = 0;
      Map? payload;
      final c = await start(
        t,
        language: 'ar',
        width: 320,
        changed: () => changes++,
        write: (r) async {
          writes++;
          payload = jsonDecode(r.body) as Map;
          return ok(r);
        },
      );
      await t.ensureVisible(find.text('تسجيل الجرد').last);
      await t.tap(find.text('تسجيل الجرد').last);
      await t.pumpAndSettle();
      await t.tap(find.text('تأكيد الجرد'));
      await t.pumpAndSettle();
      expect(writes, 0);
      await t.enterText(find.byType(TextFormField).at(0), '٧');
      await t.enterText(find.byType(TextFormField).at(1), 'جرد فعلي معزول');
      await t.tap(find.text('تأكيد الجرد'));
      await settled(t);
      expect(payload!['p_count'], 7);
      expect(payload!['p_item'], 'product-b');
      expect(changes, 1);
      expect(t.takeException(), isNull);
      await t.runAsync(c.dispose);
    },
  );
  testWidgets(
    'Receipt requires explicit confirmation and reloads stock after success',
    (t) async {
      var changes = 0;
      Map? payload;
      final c = await start(
        t,
        changed: () => changes++,
        write: (r) async {
          expect(r.url.path, endsWith('/receive_inventory_purchase'));
          payload = jsonDecode(r.body) as Map;
          return ok(r);
        },
      );
      await t.ensureVisible(find.text('Receive purchase'));
      await t.tap(find.text('Receive purchase'));
      await t.pumpAndSettle();
      expect(payload, isNull);
      await t.tap(find.text('Confirm receipt'));
      await settled(t);
      expect(payload!['p_purchase'], 'purchase-a');
      expect(changes, 1);
      expect(t.takeException(), isNull);
      await t.runAsync(c.dispose);
    },
  );
  testWidgets('Cancelling a draft requires a reason and never calls receipt', (
    t,
  ) async {
    Map? payload;
    final c = await start(
      t,
      write: (r) async {
        expect(r.url.path, endsWith('/cancel_inventory_purchase'));
        payload = jsonDecode(r.body) as Map;
        return ok(r);
      },
    );
    await t.ensureVisible(find.text('Cancel purchase order'));
    await t.tap(find.text('Cancel purchase order'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm cancellation'));
    await t.pumpAndSettle();
    expect(payload, isNull);
    await t.enterText(find.byType(TextFormField), 'Correcting supplier draft');
    await t.tap(find.text('Confirm cancellation'));
    await settled(t);
    expect(payload!['p_purchase'], 'purchase-a');
    expect(payload!['p_reason'], 'Correcting supplier draft');
    expect(find.text('Confirm cancellation'), findsNothing);
    expect(t.takeException(), isNull);
    await t.runAsync(c.dispose);
  });
}
