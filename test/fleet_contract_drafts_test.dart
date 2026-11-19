import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/fleet_contract_drafts.dart';

import 'visit_recovery_request_test.dart' as auth;

const party = '11111111-1111-4111-8111-111111111111';
const branch = '22222222-2222-4222-8222-222222222222';
const service = '33333333-3333-4333-8333-333333333333';
const contract = '44444444-4444-4444-8444-444444444444';

class Store implements FleetContractStore {
  FleetContractReference? value;
  @override
  Future<FleetContractReference?> read() async => value;
  @override
  Future<void> save(FleetContractReference ref) async {
    if (value != null && value!.encode() != ref.encode()) {
      throw StateError('Pending');
    }
    value = ref;
  }

  @override
  Future<void> clear(FleetContractReference ref) async {
    expect(value?.encode(), ref.encode());
    value = null;
  }
}

class Gateway implements FleetContractGateway {
  @override
  bool current = true;
  bool enabled = false;
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic>? entity;
  final receipts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    calls.add({'name': name, 'parameters': jsonDecode(jsonEncode(parameters))});
    if (name == 'get_fleet_contract_draft_context') {
      return {
        'module': 'fleet_contract_drafts_v1',
        'party_id': party,
        'company_name': 'QA company',
        'company_active': true,
        'can_manage_drafts': true,
        'draft_only': true,
        'pricing_active': enabled,
        'billing_enabled': false,
        'eta_submission_enabled': false,
        'contract_activation_available': false,
        'currency': 'EGP',
        'branch': {
          'branch_id': branch,
          'name_ar': 'مركز QA',
          'name_en': 'QA centre',
        },
        'services': [
          {
            'service_id': service,
            'name_ar': 'خدمة QA',
            'name_en': 'QA service',
            'catalogue_price_egp': 137.45,
          },
        ],
      };
    }
    if (name == 'list_fleet_contracts') {
      return {
        'items': [if (entity != null) entity],
        'draft_only': true,
        'pricing_active': false,
        'billing_enabled': false,
        'eta_submission_enabled': false,
      };
    }
    if (name == 'save_fleet_contract_draft') {
      final ref = parameters['p_request'] as String;
      if (receipts.containsKey(ref)) return receipts[ref]!;
      final prior = entity;
      final terms = parameters['p_archive'] == true
          ? prior!['terms']
          : {
              ...parameters['p_terms'] as Map,
              'currency': 'EGP',
              'tax_configuration': 'unconfigured',
              'pricing_active': false,
              'services': [
                for (final rate in parameters['p_terms']['services'] as List)
                  {
                    ...rate as Map,
                    'name_ar': 'خدمة QA',
                    'name_en': 'QA service',
                  },
              ],
            };
      entity = {
        'contract_id': contract,
        'party_id': party,
        'branch_id': branch,
        'version': (prior?['version'] as int? ?? 0) + 1,
        'state': parameters['p_archive'] == true ? 'archived' : 'draft',
        'terms': terms,
        'created_at': '2026-11-15T06:00:00Z',
        'last_request': ref,
      };
      return receipts[ref] = {
        'request_id': ref,
        'state': 'succeeded',
        'entity': entity,
        'draft_only': true,
        'pricing_active': false,
        'billing_enabled': false,
      };
    }
    if (name == 'get_fleet_contract_command') {
      return receipts[parameters['p_request']] ??
          {
            'request_id': parameters['p_request'],
            'state': 'absent',
            'definitive_failure': false,
          };
    }
    if (name == 'close_fleet_contract_command') {
      return receipts.putIfAbsent(
        parameters['p_request'] as String,
        () => {
          'request_id': parameters['p_request'],
          'state': 'closed',
          'definitive_failure': true,
          'draft_only': true,
        },
      );
    }
    if (name == 'get_fleet_contract_draft_history') {
      return {
        'contract_id': contract,
        'draft_only': true,
        'items': [
          {
            'version': entity!['version'],
            'request_id': entity!['last_request'],
            'actor_id': party,
            'reason': 'Isolated owner draft test',
            'created_at': '2026-11-15T06:00:00Z',
            'before': null,
            'after': entity,
          },
        ],
      };
    }
    throw StateError('Unexpected endpoint');
  }
}

Future<void> host(
  WidgetTester tester,
  Gateway gateway,
  Store store,
  String language,
) async {
  final client = await auth.client(tester);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: FleetContractDraftsScreen(
        client: client,
        partyId: party,
        gateway: gateway,
        store: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> click(WidgetTester tester, String text) async {
  final node = find.text(text);
  await tester.ensureVisible(node);
  await tester.tap(node);
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester, String label, String value) async {
  final node = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  await tester.ensureVisible(node);
  await tester.enterText(node, value);
  await tester.pump();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'company draft create preview history archive $language $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final gateway = Gateway(), store = Store();
          final ar = language == 'ar';
          String t(String a, String e) => ar ? a : e;
          await host(tester, gateway, store, language);
          expect(
            Directionality.of(
              tester.element(find.byType(FleetContractDraftsScreen)),
            ),
            ar ? TextDirection.rtl : TextDirection.ltr,
          );
          await click(tester, t('إضافة مسودة عقد', 'Add contract draft'));
          await fill(
            tester,
            t('اسم العقد بالعربية', 'Contract name in Arabic'),
            'عقد QA',
          );
          await fill(
            tester,
            t('اسم العقد بالإنجليزية', 'Contract name in English'),
            'QA contract',
          );
          final dropdown = find.byType(DropdownButtonFormField<String>).last;
          await tester.ensureVisible(dropdown);
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(find.text(t('خدمة QA', 'QA service')).last);
          await tester.pumpAndSettle();
          await fill(
            tester,
            t('سعر الخدمة المتفق عليه EGP', 'Agreed service price (EGP)'),
            ar ? '١١٠٫٢٥' : '110.25',
          );
          await fill(
            tester,
            t(
              'سبب الإجراء (١٠ أحرف على الأقل)',
              'Action reason (at least 10 characters)',
            ),
            'Isolated owner draft test',
          );
          await click(tester, t('معاينة المسودة', 'Preview draft'));
          expect(
            gateway.calls.where(
              (c) => c['name'] == 'save_fleet_contract_draft',
            ),
            isEmpty,
          );
          await click(tester, t('حفظ المسودة فقط', 'Save draft only'));
          final saved =
              gateway.calls.singleWhere(
                    (c) => c['name'] == 'save_fleet_contract_draft',
                  )['parameters']
                  as Map;
          expect(saved['p_terms']['services'][0]['price_egp'], 110.25);
          expect(store.value!.request, saved['p_request']);
          expect(saved['p_terms'].containsKey('tax_rate'), isFalse);
          await click(
            tester,
            t('راجعت النتيجة النهائية', 'I reviewed the definitive outcome'),
          );
          expect(store.value, isNull);
          await click(tester, t('سجل التعديلات', 'Revision history'));
          expect(
            gateway.calls.last['name'],
            'get_fleet_contract_draft_history',
          );
          await click(tester, t('العودة للمسودات', 'Back to drafts'));
          await click(tester, t('أرشفة المسودة', 'Archive draft'));
          await fill(
            tester,
            t(
              'سبب الإجراء (١٠ أحرف على الأقل)',
              'Action reason (at least 10 characters)',
            ),
            'Archive only isolated draft',
          );
          await click(tester, t('معاينة المسودة', 'Preview draft'));
          await click(tester, t('حفظ المسودة فقط', 'Save draft only'));
          expect(gateway.entity!['state'], 'archived');
          expect(gateway.entity!['version'], 2);
          await click(
            tester,
            t('راجعت النتيجة النهائية', 'I reviewed the definitive outcome'),
          );
          expect(
            gateway.calls
                .where((c) => c['name'] == 'save_fleet_contract_draft')
                .length,
            2,
          );
          expect(
            gateway.calls.every(
              (c) => !c['name'].toString().contains('invoice'),
            ),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('unknown persisted command must be fenced before a fresh draft', (
    tester,
  ) async {
    final gateway = Gateway(),
        store = Store()
          ..value = FleetContractReference(
            '55555555-5555-4555-8555-555555555555',
            List.filled(64, 'a').join(),
          );
    await host(tester, gateway, store, 'en');
    expect(find.text('Add contract draft'), findsNothing);
    expect(store.value, isNotNull);
    await click(tester, 'Safely close unresolved request');
    expect(store.value, isNotNull);
    await click(tester, 'I reviewed the definitive outcome');
    expect(store.value, isNull);
    expect(find.text('Add contract draft'), findsOneWidget);
    expect(
      gateway.calls.where((c) => c['name'] == 'save_fleet_contract_draft'),
      isEmpty,
    );
  });
  testWidgets('unexpected active pricing fails closed', (tester) async {
    final gateway = Gateway()..enabled = true;
    await host(tester, gateway, Store(), 'ar');
    expect(find.text('إضافة مسودة عقد'), findsNothing);
    expect(gateway.calls.length, 1);
  });
  testWidgets(
    'reference storage retains only UUID and hash and rejects overwrite',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = await auth.client(tester);
      await tester.runAsync(() async {
        final store = SharedFleetContractStore(client, party),
            ref = FleetContractReference(
              '66666666-6666-4666-8666-666666666666',
              List.filled(64, 'b').join(),
            );
        await store.save(ref);
        expect((await store.read())!.encode(), ref.encode());
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs.getKeys().where(
          (k) => k.startsWith('fleet_contract_reference/'),
        );
        expect(keys.length, 1);
        expect(jsonDecode(prefs.getString(keys.single)!), [
          ref.request,
          ref.fingerprint,
        ]);
        final other = FleetContractReference(
          '77777777-7777-4777-8777-777777777777',
          List.filled(64, 'c').join(),
        );
        await expectLater(store.save(other), throwsStateError);
        await expectLater(store.clear(other), throwsStateError);
        await store.clear(ref);
        expect(await store.read(), isNull);
      });
    },
  );
}
