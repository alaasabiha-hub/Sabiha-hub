import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/companies_fleets_catalogue.dart';

import 'visit_recovery_request_test.dart' as auth;

const partyId = '22222222-2222-4222-8222-222222222222';
const vehicleId = '33333333-3333-4333-8333-333333333333';
const vehicle2 = '44444444-4444-4444-8444-444444444444';
const savedId = '55555555-5555-4555-8555-555555555555';
Map<String, dynamic> capabilities() => {
  'module': 'companies_fleets',
  'owner_only': true,
  'view_allowed': true,
  'manage_allowed': true,
  'verification_state': 'unverified',
  for (final key in [
    'company_auth_accounts',
    'billing_enabled',
    'contracts_enabled',
    'pricing_enabled',
    'bulk_work_enabled',
    'receivables_enabled',
    'eta_submission_enabled',
  ])
    key: false,
  'tax_rate': null,
  'actual_profit': null,
};
Map<String, dynamic> partyTerms() => {
  'legal_name': null,
  'trading_name': 'Actual fleet',
  'registration_country': null,
  'tax': null,
  'address': null,
  'contacts': [],
  'representative': null,
};
Map<String, dynamic> carTerms([String plate = 'QA123']) => {
  'plate_country': null,
  'plate_number': plate,
  'make': null,
  'model': null,
  'year': null,
  'color': null,
  'fleet_reference': null,
};
Map<String, dynamic> partySnapshot({bool archived = false}) => {
  'party_id': partyId,
  'version': 3,
  'terms': partyTerms(),
  'archived': archived,
  'verification_state': 'unverified',
  'effective_active': !archived,
  'possible_same_name_parties': [],
  'name_match_is_identity_proof': false,
  'vehicle_count': 2,
  'billing_enabled': false,
  'eta_submission_enabled': false,
};
Map<String, dynamic> carSnapshot({
  bool archived = false,
  bool parentArchived = false,
}) => {
  'vehicle_id': vehicleId,
  'party_id': partyId,
  'version': 2,
  'terms': carTerms(),
  'archived': archived,
  'party_archived': parentArchived,
  'effective_active': !archived && !parentArchived,
  'verification_state': 'unverified',
  'plate_is_ownership_proof': false,
};

class Store implements FleetCatalogueStore {
  String? value;
  bool fail = false;
  final trace = <String>[];
  @override
  Future<String?> read() async => value;
  @override
  Future<void> save(String id) async {
    trace.add('save');
    if (fail) throw StateError('Storage failed');
    if (value != null) expect(id, value);
    value = id;
  }

  @override
  Future<void> clear(String expected) async {
    expect(value, expected);
    trace.add('clear');
    value = null;
  }
}

class Api implements FleetCatalogueGateway {
  @override
  String? actor = auth.actorId;
  final calls = <(String, Map<String, dynamic>)>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handle;
  Map<String, dynamic>? prepared;
  bool applied = false, listedParty = false;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) async {
    calls.add((name, Map.of(p)));
    if (handle != null) return await handle!(name, p);
    if (name == 'get_fleet_catalogue_context') return capabilities();
    if (name == 'list_fleet_parties') {
      return {
        'items': listedParty
            ? [
                {
                  'party_id': partyId,
                  'version': 3,
                  'legal_name': null,
                  'trading_name': 'Actual fleet',
                  'archived': false,
                  'verification_state': 'unverified',
                },
              ]
            : [],
        'next_cursor': null,
        'verification_state': 'unverified',
      };
    }
    if (name == 'get_fleet_party') return partySnapshot();
    if (name == 'get_fleet_vehicle') return carSnapshot();
    if (name == 'list_fleet_vehicles') {
      return {
        'items': [],
        'next_cursor': null,
        'party_archived': false,
        'verification_state': 'unverified',
        'vehicle_capacity_limit': null,
      };
    }
    if (name == 'prepare_fleet_catalog_command') {
      prepared = {
        'kind': p['p_kind'],
        'entity_id': p['p_entity'],
        'party_id': p['p_party'],
        'expected_version': p['p_expected_version'],
        'data': p['p_data'],
        'reason': p['p_reason'],
      };
      return command(p['p_request'] as String);
    }
    if (name == 'apply_fleet_catalog_command') {
      applied = true;
      listedParty = true;
      return command(p['p_request'] as String, state: 'succeeded');
    }
    if (name == 'get_fleet_catalog_command') {
      return command(
        p['p_request'] as String,
        state: applied ? 'succeeded' : 'open',
      );
    }
    if (name == 'close_fleet_catalog_command') {
      return applied
          ? command(p['p_request'] as String, state: 'succeeded')
          : {
              'request_id': p['p_request'],
              'state': 'closed',
              'definitive_failure': true,
            };
    }
    throw StateError('Unexpected $name');
  }

  Map<String, dynamic> command(String id, {String state = 'open'}) {
    final payload = prepared!;
    final car = (payload['kind'] as String).startsWith('vehicle_');
    return {
      'request_id': id,
      'state': state,
      'payload': payload,
      if (state == 'succeeded')
        'result': {
          'entity_kind': car ? 'vehicle' : 'party',
          'entity': {
            'party_id': payload['party_id'],
            if (car) 'vehicle_id': payload['entity_id'],
            'version': 4,
            'terms': (payload['data'] as Map).isEmpty
                ? car
                      ? carTerms()
                      : partyTerms()
                : payload['data'],
            'archived': false,
            'verification_state': 'unverified',
          },
          'verification_state': 'unverified',
          'billing_enabled': false,
          'eta_submission_enabled': false,
        },
    };
  }
}

FleetCatalogueCommands commands(
  Api api,
  Store store, {
  Duration timeout = const Duration(seconds: 30),
}) => FleetCatalogueCommands(gateway: api, store: store, timeout: timeout);
Future<void> press(WidgetTester t, String key, {bool settle = true}) async {
  final target = find.byKey(ValueKey(key));
  await t.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
  }
}

Future<void> enter(WidgetTester t, String key, String value) async {
  final target = find.byKey(ValueKey(key));
  // Form fields may be above or below the current scroll viewport.
  if (target.evaluate().isEmpty) {
    await t.scrollUntilVisible(
      target,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await t.ensureVisible(target);
  await t.enterText(target, value);
  await t.pump();
}

Future<void> show(
  WidgetTester t,
  auth.TestClient client,
  Api api,
  Store store, {
  String language = 'en',
  double width = 1440,
}) async {
  t.view.physicalSize = Size(width, 1100);
  t.view.devicePixelRatio = 1;
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: CompaniesFleetsCatalogueScreen(
        client: client,
        gateway: api,
        store: store,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test('all eight catalogue operations persist UUID before preview, use exact version, apply only by saved UUID', () async {
    for (final kind in fleetCommandKinds) {
      final api = Api(), store = Store();
      final flow = commands(api, store);
      await flow.initialize();
      final car = kind.startsWith('vehicle_'),
          create = kind.endsWith('_create');
      final entity = car ? vehicleId : partyId;
      final data = kind.endsWith('_edit') || create
          ? car
                ? carTerms()
                : partyTerms()
          : <String, dynamic>{};
      await flow.prepare(
        kind: kind,
        entity: entity,
        party: partyId,
        expectedVersion: create ? null : 3,
        data: data,
        reason: 'Actual catalogue owner change',
      );
      expect(store.trace, ['save']);
      expect(store.value, flow.requestId);
      final prepared = api.calls.last;
      expect(prepared.$1, 'prepare_fleet_catalog_command');
      expect(prepared.$2, {
        'p_request': store.value,
        'p_kind': kind,
        'p_entity': entity,
        'p_party': partyId,
        'p_expected_version': create ? null : 3,
        'p_data': data,
        'p_reason': 'Actual catalogue owner change',
      });
      expect(
        api.calls.where((call) => call.$1 == 'apply_fleet_catalog_command'),
        isEmpty,
      );
      await flow.apply();
      expect(api.calls.last.$1, 'apply_fleet_catalog_command');
      expect(api.calls.last.$2, {'p_request': store.value});
      expect(flow.phase, 'succeeded');
      await flow.close();
      expect(flow.phase, 'succeeded');
      await flow.acknowledge();
      expect(store.value, isNull);
      expect(flow.canStart, true);
      flow.dispose();
    }
  });

  test('failed save prevents dispatch; unknown restart freezes absent nonce until explicit close and ACK', () async {
    final store = Store()..fail = true, api = Api();
    final c = commands(api, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare(
      kind: 'party_create',
      entity: partyId,
      party: partyId,
      expectedVersion: null,
      data: partyTerms(),
      reason: 'Actual owner new record',
    );
    expect(
      api.calls.where((call) => call.$1 == 'prepare_fleet_catalog_command'),
      isEmpty,
    );
    final request = c.requestId!;
    store.fail = false;
    await c.retryPrepare();
    expect(c.requestId, request);
    expect(c.phase, 'open');
    api.handle = (name, p) async {
      if (name == 'get_fleet_catalogue_context') return capabilities();
      if (name == 'get_fleet_catalog_command') {
        return {
          'request_id': p['p_request'],
          'state': 'absent',
          'definitive_failure': false,
        };
      }
      return {
        'request_id': p['p_request'],
        'state': 'closed',
        'definitive_failure': true,
      };
    };
    final restored = commands(api, store);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.canStart, false);
    expect(restored.canRetryPrepare, false);
    expect(restored.requestId, request);
    await restored.close();
    expect(store.value, request);
    await restored.acknowledge();
    expect(store.value, isNull);
  });

  test('stale apply never rotates nonce or reapplies; explicit close then terminal ACK required', () async {
    final store = Store(), api = Api();
    final c = commands(api, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare(
      kind: 'party_edit',
      entity: partyId,
      party: partyId,
      expectedVersion: 3,
      data: partyTerms(),
      reason: 'Actual owner versioned edit',
    );
    final request = store.value!;
    api.handle = (name, p) async {
      if (name == 'apply_fleet_catalog_command') {
        throw const PostgrestException(
          message: 'Version changed',
          code: '40001',
        );
      }
      if (name == 'get_fleet_catalog_command') return api.command(request);
      return {
        'request_id': request,
        'state': 'closed',
        'definitive_failure': true,
      };
    };
    await c.apply();
    expect(c.error, 'stale');
    expect(c.canApply, false);
    expect(c.requestId, request);
    await c.recover();
    expect(c.canApply, false);
    await c.apply();
    expect(
      api.calls.where((call) => call.$1 == 'apply_fleet_catalog_command'),
      hasLength(1),
    );
    await c.close();
    await c.acknowledge();
    expect(store.value, isNull);
  });

  test('30s boundary is bounded; late owner-invalidated prepare cannot restore private data or erase nonce', () async {
    final api = Api(),
        store = Store(),
        pending = Completer<Map<String, dynamic>>();
    api.handle = (name, p) async => name == 'get_fleet_catalogue_context'
        ? capabilities()
        : await pending.future;
    final c = commands(api, store, timeout: const Duration(milliseconds: 1));
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare(
      kind: 'party_create',
      entity: partyId,
      party: partyId,
      expectedVersion: null,
      data: partyTerms(),
      reason: 'Actual owner private record',
    );
    expect(c.busy, false);
    final request = store.value!;
    api.actor = null;
    c.invalidate();
    pending.complete({
      'request_id': request,
      'state': 'closed',
      'definitive_failure': true,
    });
    await Future<void>.delayed(Duration.zero);
    expect(c.receipt, isNull);
    expect(c.invalid, true);
    expect(store.value, request);
  });

  test('UUID-only new namespace refuses replacement; SDK gateway uses exact allowed RPCs and current session', () async {
    SharedPreferences.setMockInitialValues({});
    final fakeClient = auth.TestClient(auth.TestAuth());
    try {
      final store = SharedFleetCatalogueStore(fakeClient);
      await store.save(savedId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        'companies_fleets_catalogue_command_uuid/${auth.actorId}',
      });
      expect(prefs.getString(prefs.getKeys().single), savedId);
      await expectLater(store.save(vehicle2), throwsStateError);
      await store.clear(savedId);
      expect(await store.read(), isNull);
    } finally {
      await fakeClient.dispose();
      await fakeClient.testAuth.events.close();
      fakeClient.testAuth.dispose();
    }
    final requests = <(String, Map<String, dynamic>)>[];
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'mock-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        expect(r.headers['authorization'], 'Bearer fleet-session');
        requests.add((
          r.url.path.split('/').last,
          Map.from(jsonDecode(r.body) as Map),
        ));
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
    Future<void> session(String actor) => client.auth.setInitialSession(
      jsonEncode(
        Session(
          accessToken: 'fleet-session',
          tokenType: 'bearer',
          user: User(
            id: actor,
            appMetadata: const {},
            userMetadata: const {},
            aud: 'authenticated',
            createdAt: '2026-11-15T00:00:00Z',
          ),
        ).toJson(),
      ),
    );
    try {
      await session(auth.actorId);
      final gateway = SupabaseFleetCatalogueGateway(client);
      for (final name in fleetCatalogueRpcs) {
        await gateway.call(name, {'fixture': name});
      }
      expect(requests.map((call) => call.$1).toSet(), fleetCatalogueRpcs);
      await expectLater(
        gateway.call('unsupported_directory', {}),
        throwsStateError,
      );
      await session(vehicle2);
      await expectLater(
        gateway.call('get_fleet_catalogue_context', {}),
        throwsStateError,
      );
      expect(requests, hasLength(10));
    } finally {
      await client.dispose();
    }
  });

  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'fleet ${config.$1} ${config.$2} nullable company form explicit preview/apply/ACK has no legal or financial defaults',
      (t) async {
        final client = await auth.client(t), api = Api(), store = Store();
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await show(
          t,
          client,
          api,
          store,
          language: config.$1,
          width: config.$2,
        );
        await press(t, 'fleet-add-party');
        for (final group in ['tax', 'address', 'representative']) {
          expect(
            t
                .widget<CheckboxListTile>(
                  find.byKey(ValueKey('fleet-record-$group')),
                )
                .value,
            false,
          );
        }
        expect(
          t
              .widget<TextFormField>(
                find.byKey(const ValueKey('fleet-field-registration_country')),
              )
              .controller!
              .text,
          isEmpty,
        );
        await enter(t, 'fleet-field-trading_name', 'Actual new company');
        await enter(
          t,
          'fleet-change-reason',
          'Actual company catalogue creation',
        );
        await press(t, 'fleet-prepare');
        final sent = api.calls
            .firstWhere((call) => call.$1 == 'prepare_fleet_catalog_command')
            .$2;
        expect(sent['p_data'], {
          'legal_name': null,
          'trading_name': 'Actual new company',
          'registration_country': null,
          'tax': null,
          'address': null,
          'contacts': [],
          'representative': null,
        });
        expect(sent['p_entity'], sent['p_party']);
        expect(sent['p_expected_version'], isNull);
        expect(find.textContaining('14%'), findsNothing);
        expect(
          api.calls.where((call) => call.$1 == 'apply_fleet_catalog_command'),
          isEmpty,
        );
        await press(t, 'fleet-apply');
        expect(store.value, isNotNull);
        await press(t, 'fleet-acknowledge');
        expect(store.value, isNull);
        expect(
          find.byKey(const ValueKey('fleet-party-$partyId')),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'fleet vehicle keyset pages remain party-scoped; Arabic year explicit new car has no transfer or plate_key input',
    (t) async {
      final client = await auth.client(t),
          api = Api()..listedParty = true,
          store = Store();
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final fallback = Api()..listedParty = true;
      api.handle = (name, p) async {
        if (name == 'list_fleet_vehicles') {
          return {
            'items': [
              {
                'vehicle_id': p['p_before_id'] == null ? vehicleId : vehicle2,
                'party_id': partyId,
                'version': 2,
                'plate_number': p['p_before_id'] == null ? 'QA123' : 'QA456',
                'effective_active': true,
              },
            ],
            'next_cursor': p['p_before_id'] == null
                ? {'created_at': '2026-11-15T00:00:00Z', 'entity_id': vehicleId}
                : null,
            'party_archived': false,
            'verification_state': 'unverified',
            'vehicle_capacity_limit': null,
          };
        }
        return await fallback.call(name, p);
      };
      await show(t, client, api, store);
      await press(t, 'fleet-party-$partyId');
      await press(t, 'fleet-more-vehicles');
      final pages = api.calls
          .where((call) => call.$1 == 'list_fleet_vehicles')
          .toList();
      expect(pages.last.$2, {
        'p_party': partyId,
        'p_search': '',
        'p_include_archived': false,
        'p_before_created_at': '2026-11-15T00:00:00Z',
        'p_before_id': vehicleId,
        'p_limit': 25,
      });
      await press(t, 'fleet-add-vehicle');
      await enter(t, 'fleet-field-plate_number', 'أ ب ١٢٣');
      await enter(t, 'fleet-field-year', '٢٠٢٤');
      await enter(
        t,
        'fleet-change-reason',
        'Actual new recorded fleet vehicle',
      );
      await press(t, 'fleet-prepare');
      final body = api.calls
          .firstWhere((call) => call.$1 == 'prepare_fleet_catalog_command')
          .$2;
      expect(body['p_party'], partyId);
      expect(body['p_expected_version'], isNull);
      expect(body['p_data'], {
        'plate_country': null,
        'plate_number': 'أ ب ١٢٣',
        'make': null,
        'model': null,
        'color': null,
        'fleet_reference': null,
        'year': 2024,
      });
      expect((body['p_data'] as Map).containsKey('plate_key'), false);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'history shows immutable before/after version and archive flags with paired history cursor',
    (t) async {
      final client = await auth.client(t),
          api = Api()..listedParty = true,
          store = Store(),
          fallback = Api()..listedParty = true;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      api.handle = (name, p) async {
        if (name == 'list_fleet_catalogue_history') {
          return {
            'entity_kind': 'party',
            'entity_id': partyId,
            'items': [
              {
                'request_id': savedId,
                'version': 4,
                'operation': 'party_archive',
                'actor_role': 'owner',
                'reason': 'Actual archive reason',
                'created_at': '2026-11-15T00:00:00Z',
                'before': partySnapshot(),
                'after': {...partySnapshot(archived: true), 'version': 4},
              },
            ],
            'next_before_version': null,
          };
        }
        return await fallback.call(name, p);
      };
      await show(t, client, api, store);
      await press(t, 'fleet-party-$partyId');
      await press(t, 'fleet-party-history');
      expect(find.text('Archive state: Not archived'), findsOneWidget);
      expect(find.text('Archive state: Archived'), findsOneWidget);
      expect(find.text('Version: 3'), findsOneWidget);
      expect(find.text('Version: 4'), findsOneWidget);
      expect(api.calls.last.$1, 'list_fleet_catalogue_history');
      expect(api.calls.last.$2, {
        'p_entity_kind': 'party',
        'p_entity': partyId,
        'p_before_version': null,
        'p_limit': 25,
      });
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'owner session change clears form and late command while retaining durable nonce',
    (t) async {
      final client = await auth.client(t),
          api = Api(),
          store = Store(),
          pending = Completer<Map<String, dynamic>>();
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await show(t, client, api, store);
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      );
      await t.pump();
      await press(t, 'fleet-add-party');
      await enter(t, 'fleet-field-trading_name', 'Private draft company');
      await enter(t, 'fleet-change-reason', 'Private owner catalogue purpose');
      api.handle = (_, p) async => await pending.future;
      await press(t, 'fleet-prepare', settle: false);
      final id = store.value!;
      client.testAuth.user = null;
      api.actor = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await t.pump();
      pending.complete({
        'request_id': id,
        'state': 'closed',
        'definitive_failure': true,
      });
      await t.pumpAndSettle();
      expect(find.textContaining('Private draft company'), findsNothing);
      expect(
        find.textContaining('Private owner catalogue purpose'),
        findsNothing,
      );
      expect(store.value, id);
      expect(
        find.text(
          'Session changed. Reopen the catalogue with the authorized owner account.',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'denied owner context exposes no private parties, contacts or management controls',
    (t) async {
      final client = await auth.client(t), api = Api(), store = Store();
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      api.handle = (name, params) async {
        throw const PostgrestException(
          message: 'Owner required',
          code: '42501',
        );
      };
      await show(t, client, api, store);
      expect(find.byKey(const ValueKey('fleet-add-party')), findsNothing);
      expect(find.text('Actual fleet'), findsNothing);
      expect(find.textContaining('No records are available'), findsNothing);
      expect(api.calls.map((call) => call.$1), ['get_fleet_catalogue_context']);
      expect(
        find.text(
          'Current owner access could not be confirmed. Old private data is not displayed.',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
