import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

const fleetCatalogueRpcs = {
  'get_fleet_catalogue_context',
  'get_fleet_party',
  'get_fleet_vehicle',
  'list_fleet_parties',
  'list_fleet_vehicles',
  'list_fleet_catalogue_history',
  'prepare_fleet_catalog_command',
  'get_fleet_catalog_command',
  'apply_fleet_catalog_command',
  'close_fleet_catalog_command',
};
const fleetCommandKinds = {
  'party_create',
  'party_edit',
  'party_archive',
  'party_reenable',
  'vehicle_create',
  'vehicle_edit',
  'vehicle_archive',
  'vehicle_reenable',
};
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

abstract class FleetCatalogueGateway {
  String? get actor;
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

class SupabaseFleetCatalogueGateway implements FleetCatalogueGateway {
  SupabaseFleetCatalogueGateway(
    this.client, {
    this.timeout = const Duration(seconds: 30),
  }) : boundActor = client.auth.currentUser?.id,
       token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? boundActor, token;
  final Duration timeout;
  @override
  String? get actor => client.auth.currentUser?.id;
  bool get current =>
      actor != null &&
      actor == boundActor &&
      token != null &&
      client.auth.currentSession?.accessToken == token &&
      client.auth.currentSession?.user.id == actor;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current || !fleetCatalogueRpcs.contains(name)) {
      throw StateError('Unauthorized catalogue call');
    }
    final data = await client.rpc(name, params: params).timeout(timeout);
    if (!current) throw StateError('Session changed');
    return Map<String, dynamic>.from(data as Map);
  }
}

abstract class FleetCatalogueStore {
  Future<String?> read();
  Future<void> save(String id);
  Future<void> clear(String expected);
}

class SharedFleetCatalogueStore implements FleetCatalogueStore {
  SharedFleetCatalogueStore(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return 'companies_fleets_catalogue_command_uuid/$actor';
  }

  @override
  Future<String?> read() async {
    final k = key, prefs = await SharedPreferences.getInstance();
    if (key != k) throw StateError('Session changed');
    final value = prefs.getString(k);
    if (value != null && !_uuid.hasMatch(value)) {
      throw StateError('Unconfirmed saved reference');
    }
    return value;
  }

  @override
  Future<void> save(String id) async {
    if (!_uuid.hasMatch(id)) throw StateError('Invalid reference');
    final k = key, old = await read();
    if (old != null && old != id) throw StateError('Recover original command');
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.setString(k, id)) {
      throw StateError('Reference not saved');
    }
    if (key != k) throw StateError('Session changed');
  }

  @override
  Future<void> clear(String expected) async {
    final k = key, old = await read();
    if (old != expected) throw StateError('Saved reference changed');
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.remove(k)) {
      throw StateError('Reference not cleared');
    }
  }
}

class FleetCatalogueCommands extends ChangeNotifier {
  FleetCatalogueCommands({
    required this.gateway,
    required this.store,
    this.timeout = const Duration(seconds: 30),
  }) : actor = gateway.actor;
  final FleetCatalogueGateway gateway;
  final FleetCatalogueStore store;
  final Duration timeout;
  final String? actor;
  String? requestId;
  Map<String, dynamic>? receipt, _originalPrepare;
  bool ready = false,
      busy = false,
      invalid = false,
      disposed = false,
      stale = false;
  String phase = 'loading', error = '';
  int epoch = 0;
  bool get current =>
      !disposed && !invalid && actor != null && gateway.actor == actor;
  bool get canStart =>
      current && ready && !busy && requestId == null && phase == 'idle';
  bool get canApply => current && !busy && phase == 'open' && !stale;
  bool get canRetryPrepare =>
      current && !busy && phase == 'uncertain' && _originalPrepare != null;
  bool get canClose =>
      current &&
      !busy &&
      requestId != null &&
      !['succeeded', 'closed'].contains(phase);
  bool get canAcknowledge =>
      current &&
      !busy &&
      requestId != null &&
      ['succeeded', 'closed'].contains(phase);
  bool owns(int e) => current && e == epoch;
  void changed() {
    if (!disposed) notifyListeners();
  }

  void invalidate() {
    epoch++;
    invalid = true;
    ready = busy = false;
    requestId = null;
    receipt = _originalPrepare = null;
    phase = 'invalid';
    error = 'identity';
    changed();
  }

  Future<Map<String, dynamic>> read(
    String name,
    Map<String, dynamic> params,
  ) async {
    final e = epoch;
    if (!current) throw StateError('Session changed');
    final value = await gateway.call(name, params).timeout(timeout);
    if (!owns(e)) throw StateError('Session changed');
    return value;
  }

  Future<void> run(Future<void> Function(int) work) async {
    if (!current || busy) return;
    final e = epoch;
    busy = true;
    error = '';
    changed();
    try {
      await work(e);
    } on PostgrestException catch (failure) {
      if (owns(e)) {
        error = switch (failure.code) {
          '40001' => 'stale',
          '23505' => 'conflict',
          '42501' => 'denied',
          '22023' => 'invalid',
          '55000' => 'blocked',
          _ => 'unconfirmed',
        };
        if (failure.code == '40001') stale = true;
        if (failure.code == '42501') receipt = null;
      }
    } catch (_) {
      if (owns(e)) {
        receipt = null;
        error = 'unconfirmed';
      }
    } finally {
      if (owns(e)) {
        busy = false;
        changed();
      }
    }
  }

  void applyReceipt(Map<String, dynamic> value) {
    if (value['request_id'] != requestId ||
        !['open', 'succeeded', 'closed', 'absent'].contains(value['state'])) {
      throw StateError('Command mismatch');
    }
    if (value['state'] == 'absent') {
      if (value['definitive_failure'] != false) {
        throw StateError('Absence is not closure');
      }
      phase = 'uncertain';
      receipt = null;
      return;
    }
    final payload = value['payload'];
    if (value['state'] == 'open' &&
        (payload is! Map ||
            !fleetCommandKinds.contains(payload['kind']) ||
            !_uuid.hasMatch(payload['entity_id'] as String? ?? '') ||
            !_uuid.hasMatch(payload['party_id'] as String? ?? ''))) {
      throw StateError('Unverified preview');
    }
    if (value['state'] == 'succeeded') {
      final result = value['result'];
      if (result is! Map ||
          result['verification_state'] != 'unverified' ||
          result['billing_enabled'] != false ||
          result['eta_submission_enabled'] != false ||
          !['party', 'vehicle'].contains(result['entity_kind']) ||
          result['entity'] is! Map ||
          result['entity']['terms'] is! Map ||
          result['entity']['verification_state'] != 'unverified' ||
          result['entity']['version'] is! num ||
          result['entity']['version'] < 1) {
        throw StateError('Unverified result');
      }
      if (payload is Map &&
          (result['entity']['party_id'] != payload['party_id'] ||
              result['entity'][payload['kind'].toString().startsWith('vehicle_')
                      ? 'vehicle_id'
                      : 'party_id'] !=
                  payload['entity_id'])) {
        throw StateError('Entity mismatch');
      }
    }
    phase = value['state'] as String;
    receipt = value;
  }

  Future<void> initialize() => run((e) async {
    final caps = await read('get_fleet_catalogue_context', {});
    if (!owns(e)) return;
    if (caps['module'] != 'companies_fleets' ||
        caps['owner_only'] != true ||
        caps['view_allowed'] != true ||
        caps['manage_allowed'] != true ||
        caps['verification_state'] != 'unverified' ||
        [
          'company_auth_accounts',
          'billing_enabled',
          'contracts_enabled',
          'pricing_enabled',
          'bulk_work_enabled',
          'receivables_enabled',
          'eta_submission_enabled',
        ].any((key) => caps[key] != false) ||
        caps['tax_rate'] != null ||
        caps['actual_profit'] != null) {
      throw StateError('Unknown module capability');
    }
    ready = true;
    requestId = await store.read();
    if (!owns(e)) return;
    if (requestId != null) {
      phase = 'uncertain';
      final value = await read('get_fleet_catalog_command', {
        'p_request': requestId,
      });
      if (owns(e)) applyReceipt(value);
    } else {
      phase = 'idle';
    }
  });
  Future<void> prepare({
    required String kind,
    required String entity,
    required String party,
    required int? expectedVersion,
    required Map<String, dynamic> data,
    required String reason,
  }) async {
    if (!canStart ||
        !fleetCommandKinds.contains(kind) ||
        !_uuid.hasMatch(entity) ||
        !_uuid.hasMatch(party) ||
        reason.trim().length < 10 ||
        reason.trim().length > 500 ||
        (kind.startsWith('party_') && entity != party) ||
        (kind.endsWith('_create')
            ? expectedVersion != null
            : expectedVersion == null || expectedVersion < 1)) {
      return;
    }
    await run((e) async {
      requestId = newOrderRequestId();
      phase = 'uncertain';
      stale = false;
      _originalPrepare = Map<String, dynamic>.unmodifiable(
        jsonDecode(
          jsonEncode({
            'p_request': requestId,
            'p_kind': kind,
            'p_entity': entity,
            'p_party': party,
            'p_expected_version': expectedVersion,
            'p_data': data,
            'p_reason': reason.trim(),
          }),
        ) as Map<String, dynamic>,
      );
      await dispatchPrepare(e);
    });
  }

  Future<void> dispatchPrepare(int e) async {
    await store.save(requestId!);
    if (!owns(e)) return;
    final value = await read(
      'prepare_fleet_catalog_command',
      Map.of(_originalPrepare!),
    );
    if (owns(e)) applyReceipt(value);
  }

  Future<void> retryPrepare() async {
    if (canRetryPrepare) await run(dispatchPrepare);
  }

  Future<void> recover() async {
    if (requestId == null) return;
    await run((e) async {
      final value = await read('get_fleet_catalog_command', {
        'p_request': requestId,
      });
      if (owns(e)) applyReceipt(value);
    });
  }

  Future<void> apply() async {
    if (!canApply) return;
    await run((e) async {
      final value = await read('apply_fleet_catalog_command', {
        'p_request': requestId,
      });
      if (owns(e)) applyReceipt(value);
    });
  }

  Future<void> close() async {
    if (!canClose) return;
    await run((e) async {
      await store.save(requestId!);
      if (!owns(e)) return;
      final value = await read('close_fleet_catalog_command', {
        'p_request': requestId,
      });
      if (owns(e)) applyReceipt(value);
    });
  }

  Future<void> acknowledge() async {
    if (!canAcknowledge) return;
    await run((e) async {
      await store.clear(requestId!);
      if (!owns(e)) return;
      requestId = null;
      receipt = _originalPrepare = null;
      phase = 'idle';
      stale = false;
    });
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    receipt = _originalPrepare = null;
    super.dispose();
  }
}

class _Contact {
  _Contact([Map? source])
    : kind = source?['kind'] as String?,
      value = TextEditingController(text: source?['value'] as String? ?? ''),
      label = TextEditingController(text: source?['label'] as String? ?? '');
  String? kind;
  final TextEditingController value, label;
  void clear() {
    kind = null;
    value.clear();
    label.clear();
  }

  void dispose() {
    value.dispose();
    label.dispose();
  }
}

/// Owner-only master catalogue. It has no cashier entry, company Auth, invoice,
/// pricing, credit, payment, loyalty transfer, tax-rate or ETA action.
class CompaniesFleetsCatalogueScreen extends StatefulWidget {
  const CompaniesFleetsCatalogueScreen({
    super.key,
    required this.client,
    this.gateway,
    this.store,
    this.contractBuilder,
  });
  final SupabaseClient client;
  final FleetCatalogueGateway? gateway;
  final FleetCatalogueStore? store;
  final Widget Function(BuildContext, String)? contractBuilder;
  @override
  State<CompaniesFleetsCatalogueScreen> createState() =>
      _CompaniesFleetsCatalogueScreenState();
}

class _CompaniesFleetsCatalogueScreenState
    extends State<CompaniesFleetsCatalogueScreen> {
  late final FleetCatalogueCommands c;
  StreamSubscription<AuthState>? auth;
  final search = TextEditingController(), reason = TextEditingController();
  final fields = <String, TextEditingController>{};
  final contacts = <_Contact>[], retiredContacts = <_Contact>[];
  final formKey = GlobalKey<FormState>();
  String formReturn = 'parties';
  String view = 'parties',
      historyParent = 'party',
      formKind = '',
      entity = '',
      parent = '';
  int? expectedVersion;
  List<Map<String, dynamic>> rows = [], history = [];
  Map<String, dynamic>? cursor, party, vehicle;
  int? historyCursor;
  bool loaded = false;
  bool includeArchived = false,
      reading = false,
      tax = false,
      address = false,
      representative = false;
  String readError = '';
  int readEpoch = 0;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  String get title => switch (view) {
    'party' => t('ملف الشركة والأسطول', 'Company and fleet record'),
    'vehicle' => t('سجل سيارة الأسطول', 'Fleet vehicle record'),
    'form' => t('بيانات مقترحة للمراجعة', 'Proposed catalogue details'),
    'history' => t('سجل الإصدارات المحفوظ', 'Retained version history'),
    'command' => t('مراجعة إجراء الدليل', 'Review catalogue action'),
    _ => t('دليل الشركات والأساطيل', 'Companies and fleets catalogue'),
  };
  @override
  void initState() {
    super.initState();
    c = FleetCatalogueCommands(
      gateway: widget.gateway ?? SupabaseFleetCatalogueGateway(widget.client),
      store: widget.store ?? SharedFleetCatalogueStore(widget.client),
    );
    c.addListener(changed);
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      c.invalidate();
    });
    unawaited(boot());
  }

  Future<void> boot() async {
    await c.initialize();
    if (mounted && c.current && c.ready && c.requestId == null) {
      await loadParties();
    }
  }

  void wipeDraft() {
    for (final field in fields.values) {
      field.clear();
    }
    for (final contact in contacts) {
      contact.clear();
    }
    retiredContacts.addAll(contacts);
    contacts.clear();
    reason.clear();
    tax = address = representative = false;
  }

  void changed() {
    if (!mounted) return;
    if (c.invalid) {
      readEpoch++;
      wipeDraft();
      search.clear();
      rows = [];
      history = [];
      party = vehicle = cursor = null;
    }
    if (c.requestId != null && view != 'command') {
      readEpoch++;
      wipeDraft();
      view = 'command';
      rows = [];
      history = [];
      party = vehicle = cursor = null;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant CompaniesFleetsCatalogueScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.gateway != widget.gateway ||
        oldWidget.store != widget.store) {
      c.invalidate();
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    c.removeListener(changed);
    c.dispose();
    search.dispose();
    reason.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    for (final contact in [...contacts, ...retiredContacts]) {
      contact.dispose();
    }
    super.dispose();
  }

  TextEditingController field(String key) =>
      fields.putIfAbsent(key, TextEditingController.new);
  String? text(String key) {
    final value = field(key).text.trim();
    return value.isEmpty ? null : value;
  }

  bool get allowed => c.canStart && !reading;
  Future<void> readingWork(Future<void> Function(int) work) async {
    if (!c.current || !c.ready || c.requestId != null) return;
    final e = ++readEpoch;
    setState(() {
      reading = true;
      readError = '';
    });
    try {
      await work(e);
    } catch (_) {
      if (mounted && e == readEpoch && c.current) {
        setState(() {
          rows = [];
          history = [];
          party = vehicle = cursor = null;
          readError = 'unavailable';
        });
      }
    } finally {
      if (mounted && e == readEpoch && c.current) {
        setState(() => reading = false);
      }
    }
  }

  bool fresh(int e) =>
      mounted && c.current && e == readEpoch && c.requestId == null;
  Map<String, dynamic> pageParams(Map<String, dynamic>? at) => {
    'p_search': search.text.trim(),
    'p_include_archived': includeArchived,
    'p_before_created_at': at?['created_at'],
    'p_before_id': at?['entity_id'],
    'p_limit': 25,
  };
  Future<void> loadParties({bool more = false}) => readingWork((e) async {
    final at = more ? cursor : null;
    if (more && at == null) return;
    final data = await c.read('list_fleet_parties', pageParams(at));
    if (!fresh(e)) return;
    final list = (data['items'] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    if (list.length > 25 || data['verification_state'] != 'unverified') {
      throw StateError('Unbounded list');
    }
    setState(() {
      rows = more ? [...rows, ...list] : list;
      cursor = data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map);
      view = 'parties';
      party = vehicle = null;
      parent = '';
      loaded = true;
    });
  });
  Future<void> openParty(String id) => readingWork((e) async {
    final data = await c.read('get_fleet_party', {'p_party': id});
    if (!fresh(e)) return;
    if (data['party_id'] != id ||
        data['verification_state'] != 'unverified' ||
        data['billing_enabled'] != false ||
        data['eta_submission_enabled'] != false) {
      throw StateError('Unverified party');
    }
    setState(() {
      party = data;
      vehicle = null;
      parent = id;
      rows = [];
      cursor = null;
      search.clear();
      includeArchived = false;
      loaded = false;
      view = 'party';
    });
    await readVehicles(e, false);
  });
  Future<void> readVehicles(int e, bool more) async {
    final at = more ? cursor : null;
    if (more && at == null) return;
    final data = await c.read('list_fleet_vehicles', {
      'p_party': parent,
      ...pageParams(at),
    });
    if (!fresh(e)) return;
    final list = (data['items'] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    if (list.length > 25 ||
        list.any((row) => row['party_id'] != parent) ||
        data['verification_state'] != 'unverified' ||
        data['vehicle_capacity_limit'] != null) {
      throw StateError('Unverified fleet page');
    }
    setState(() {
      loaded = true;
      rows = more ? [...rows, ...list] : list;
      cursor = data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map);
    });
  }

  Future<void> loadVehicles({bool more = false}) =>
      readingWork((e) => readVehicles(e, more));
  Future<void> openVehicle(String id) => readingWork((e) async {
    final data = await c.read('get_fleet_vehicle', {
      'p_party': parent,
      'p_vehicle': id,
    });
    if (!fresh(e)) return;
    if (data['party_id'] != parent ||
        data['vehicle_id'] != id ||
        data['verification_state'] != 'unverified' ||
        data['plate_is_ownership_proof'] != false) {
      throw StateError('Unverified vehicle');
    }
    setState(() {
      vehicle = data;
      view = 'vehicle';
    });
  });
  Future<void> loadHistory({bool more = false}) => readingWork((e) async {
    final kind = historyParent == 'vehicle' ? 'vehicle' : 'party',
        id = kind == 'vehicle' ? vehicle!['vehicle_id'] : party!['party_id'];
    final data = await c.read('list_fleet_catalogue_history', {
      'p_entity_kind': kind,
      'p_entity': id,
      'p_before_version': more ? historyCursor : null,
      'p_limit': 25,
    });
    if (!fresh(e)) return;
    if (data['entity_id'] != id ||
        data['entity_kind'] != kind ||
        (data['items'] as List).length > 25) {
      throw StateError('Unverified history');
    }
    setState(() {
      history = [
        ...(more ? history : <Map<String, dynamic>>[]),
        ...(data['items'] as List).map(
          (row) => Map<String, dynamic>.from(row as Map),
        ),
      ];
      historyCursor = (data['next_before_version'] as num?)?.toInt();
      view = 'history';
    });
  });
  void startForm(String kind) {
    if (!allowed) return;
    formReturn = view;
    wipeDraft();
    formKind = kind;
    final vehicleKind = kind.startsWith('vehicle_'),
        create = kind.endsWith('_create');
    final target = vehicleKind ? vehicle : party;
    entity = create
        ? newOrderRequestId()
        : target![vehicleKind ? 'vehicle_id' : 'party_id'] as String;
    if (!vehicleKind) parent = entity;
    expectedVersion = create ? null : (target!['version'] as num).toInt();
    final values = !create
        ? Map<String, dynamic>.from(target!['terms'] as Map)
        : <String, dynamic>{};
    if (kind.endsWith('_edit') || create) {
      if (vehicleKind) {
        for (final key in [
          'plate_country',
          'plate_number',
          'make',
          'model',
          'year',
          'color',
          'fleet_reference',
        ]) {
          field(key).text = values[key]?.toString() ?? '';
        }
      } else {
        for (final key in [
          'legal_name',
          'trading_name',
          'registration_country',
        ]) {
          field(key).text = values[key] as String? ?? '';
        }
        tax = values['tax'] != null;
        address = values['address'] != null;
        representative = values['representative'] != null;
        for (final group in ['tax', 'address', 'representative']) {
          final map = values[group] as Map? ?? {};
          for (final key in groupKeys(group)) {
            field('$group.$key').text = map[key]?.toString() ?? '';
          }
        }
        for (final row in (values['contacts'] as List? ?? [])) {
          contacts.add(_Contact(row as Map));
        }
      }
    }
    setState(() {
      view = 'form';
      readError = '';
    });
  }

  List<String> groupKeys(String group) => switch (group) {
    'tax' => ['country', 'identifier_type', 'number'],
    'address' => [
      'country',
      'region',
      'city',
      'street',
      'building',
      'postal_code',
      'additional',
    ],
    _ => ['name', 'title', 'phone', 'email'],
  };
  String latinDigits(String value) =>
      value.replaceAllMapped(RegExp('[٠-٩۰-۹]'), (m) {
        final digit = m[0]!.codeUnitAt(0);
        return '${digit >= 0x06f0 ? digit - 0x06f0 : digit - 0x0660}';
      });
  Map<String, dynamic> draftData() {
    if (!formKind.endsWith('_create') && !formKind.endsWith('_edit')) return {};
    if (formKind.startsWith('vehicle_')) {
      return {
        for (final key in [
          'plate_country',
          'plate_number',
          'make',
          'model',
          'color',
          'fleet_reference',
        ])
          key: text(key),
        'year': text('year') == null
            ? null
            : int.parse(latinDigits(text('year')!)),
      };
    }
    return {
      for (final key in ['legal_name', 'trading_name', 'registration_country'])
        key: text(key),
      'tax': tax
          ? {for (final key in groupKeys('tax')) key: text('tax.$key')}
          : null,
      'address': address
          ? {for (final key in groupKeys('address')) key: text('address.$key')}
          : null,
      'contacts': [
        for (final contact in contacts)
          {
            'kind': contact.kind,
            'value': contact.value.text.trim(),
            'label': contact.label.text.trim().isEmpty
                ? null
                : contact.label.text.trim(),
          },
      ],
      'representative': representative
          ? {
              ...{
                for (final key in groupKeys('representative'))
                  key: text('representative.$key'),
              },
              'verification': 'unverified',
            }
          : null,
    };
  }

  Future<void> prepare() async {
    if (!allowed || formKey.currentState?.validate() != true) return;
    await c.prepare(
      kind: formKind,
      entity: entity,
      party: parent,
      expectedVersion: expectedVersion,
      data: draftData(),
      reason: reason.text,
    );
  }

  Future<void> acknowledge() async {
    await c.acknowledge();
    if (mounted && c.current && c.requestId == null) {
      setState(() {
        view = 'parties';
        party = vehicle = null;
        parent = '';
        loaded = false;
        reading = false;
        search.clear();
        includeArchived = false;
      });
      await loadParties();
    }
  }

  Future<void> back() async {
    if (view == 'form') {
      wipeDraft();
      if (formReturn == 'vehicle' && vehicle != null) {
        await openVehicle(vehicle!['vehicle_id'] as String);
      } else if (formReturn == 'party' && party != null) {
        await openParty(party!['party_id'] as String);
      } else {
        search.clear();
        includeArchived = false;
        await loadParties();
      }
    } else if (view == 'history' &&
        historyParent == 'vehicle' &&
        vehicle != null) {
      setState(() => view = 'vehicle');
    } else if (view == 'vehicle' || view == 'history') {
      await openParty(parent);
    } else {
      search.clear();
      includeArchived = false;
      await loadParties();
    }
  }

  String date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return t('غير متاح', 'Unavailable');
    final local = parsed.toLocal(), labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(local)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  String label(String key) => switch (key) {
    'legal_name' => t(
      'الاسم القانوني المسجل (غير موثّق)',
      'Recorded legal name (unverified)',
    ),
    'trading_name' => t('الاسم التجاري', 'Trading name'),
    'registration_country' => t(
      'بلد التسجيل (حرفان، اختياري)',
      'Registration country (two letters, optional)',
    ),
    'country' => t('البلد (حرفان)', 'Country (two letters)'),
    'identifier_type' => t('نوع المعرّف المسجل', 'Recorded identifier type'),
    'number' => t('رقم المعرّف المسجل', 'Recorded identifier number'),
    'region' => t('المحافظة أو المنطقة', 'Region'),
    'city' => t('المدينة', 'City'),
    'street' => t('الشارع', 'Street'),
    'building' => t('المبنى', 'Building'),
    'postal_code' => t('الرمز البريدي', 'Postal code'),
    'additional' => t('تفاصيل إضافية', 'Additional details'),
    'name' => t('الاسم', 'Name'),
    'title' => t('الصفة المسجلة', 'Recorded title'),
    'phone' => t('هاتف للتواصل (غير موثّق)', 'Contact phone (unverified)'),
    'email' => t('بريد للتواصل (ليس حساب دخول)', 'Contact email (not a login)'),
    'other' => t('وسيلة أخرى', 'Other contact'),
    'value' => t('وسيلة التواصل المسجلة', 'Recorded contact value'),
    'contact_label' => t(
      'وصف وسيلة التواصل (اختياري)',
      'Contact label (optional)',
    ),
    'plate_country' => t(
      'بلد اللوحة (حرفان، اختياري)',
      'Plate country (two letters, optional)',
    ),
    'plate_number' => t('رقم اللوحة المسجل', 'Recorded plate number'),
    'make' => t('الماركة', 'Make'),
    'model' => t('الموديل', 'Model'),
    'year' => t(
      'السنة المسجلة (٤ أرقام، اختياري)',
      'Recorded year (four digits, optional)',
    ),
    'color' => t('اللون', 'Color'),
    'fleet_reference' => t(
      'مرجع السيارة داخل الأسطول (اختياري)',
      'Internal fleet reference (optional)',
    ),
    _ => t('غير مسجل', 'Not recorded'),
  };
  String operation(dynamic kind) => switch (kind) {
    'party_create' => t('إضافة شركة أو أسطول', 'Add company or fleet'),
    'party_edit' => t('تعديل بيانات الشركة', 'Edit company details'),
    'party_archive' => t('أرشفة الشركة', 'Archive company'),
    'party_reenable' => t('إعادة تفعيل الشركة', 'Re-enable company'),
    'vehicle_create' => t('إضافة سيارة', 'Add vehicle'),
    'vehicle_edit' => t('تعديل السيارة', 'Edit vehicle'),
    'vehicle_archive' => t('أرشفة السيارة', 'Archive vehicle'),
    'vehicle_reenable' => t('إعادة تفعيل السيارة', 'Re-enable vehicle'),
    _ => t('إجراء محفوظ', 'Recorded action'),
  };
  Widget identified(String id, Widget child) =>
      Semantics(identifier: id, child: child);
  Widget action(
    String id,
    String name,
    VoidCallback? callback, {
    bool primary = false,
  }) => identified(
    id,
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: primary
          ? FilledButton(
              key: ValueKey(id),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff174b83),
              ),
              onPressed: callback,
              child: Text(name),
            )
          : OutlinedButton(
              key: ValueKey(id),
              onPressed: callback,
              child: Text(name),
            ),
    ),
  );
  Widget dataText(String name, dynamic value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Text('$name: ${value ?? t('غير مسجل', 'Not recorded')}'),
  );
  Widget termsView(String kind, Map terms) {
    final children = <Widget>[];
    if (kind == 'vehicle') {
      for (final key in [
        'plate_country',
        'plate_number',
        'make',
        'model',
        'year',
        'color',
        'fleet_reference',
      ]) {
        children.add(dataText(label(key), terms[key]));
      }
      children.add(
        Text(
          t(
            'اللوحة المسجلة لا تثبت ملكية السيارة.',
            'A recorded plate does not prove vehicle ownership.',
          ),
        ),
      );
    } else {
      for (final key in [
        'legal_name',
        'trading_name',
        'registration_country',
      ]) {
        children.add(dataText(label(key), terms[key]));
      }
      for (final group in ['tax', 'address', 'representative']) {
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            group == 'tax'
                ? t(
                    'هوية ضريبية مسجلة وغير موثّقة',
                    'Recorded, unverified tax identity',
                  )
                : group == 'address'
                ? t('العنوان المسجل', 'Recorded address')
                : t(
                    'ممثل مسجل وغير موثّق؛ بلا صلاحيات دخول',
                    'Recorded, unverified representative; no account access',
                  ),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
        final values = terms[group];
        if (values is Map) {
          for (final key in groupKeys(group)) {
            children.add(dataText(label(key), values[key]));
          }
        } else {
          children.add(Text(t('غير مسجل', 'Not recorded')));
        }
      }
      children.add(
        Text(
          t(
            'وسائل تواصل للمالك فقط؛ لا تثبت الملكية أو موافقة تسويقية',
            'Owner-only contacts; no possession proof or marketing consent',
          ),
        ),
      );
      for (final row in terms['contacts'] as List? ?? []) {
        final item = row as Map;
        children.add(
          dataText(
            label(item['kind'] as String? ?? ''),
            '${item['value']} ${item['label'] ?? ''}',
          ),
        );
      }
      if ((terms['contacts'] as List? ?? []).isEmpty) {
        children.add(
          Text(t('لا توجد وسائل تواصل مسجلة.', 'No contacts are recorded.')),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget snapshotView(String kind, Map value) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      dataText(t('الإصدار', 'Version'), value['version']),
      dataText(
        t('حالة الأرشفة', 'Archive state'),
        value['archived'] == true
            ? t('مؤرشف', 'Archived')
            : t('غير مؤرشف', 'Not archived'),
      ),
      termsView(kind, value['terms'] as Map),
    ],
  );
  String? validateField(
    String key,
    String? value, {
    bool required = false,
    int max = 120,
  }) {
    final v = value?.trim() ?? '';
    if (required && v.isEmpty) {
      return t('هذا الحقل مطلوب', 'This field is required');
    }
    if (v.length > max || RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
      return t('راجع طول النص وتنسيقه', 'Check the text length and format');
    }
    if (v.isNotEmpty &&
        (key == 'country' || key.endsWith('_country')) &&
        !RegExp(r'^[A-Za-z]{2}$').hasMatch(v)) {
      return t(
        'أدخل حرفين للبلد أو اتركه فارغاً',
        'Enter two country letters or leave blank',
      );
    }
    if (['legal_name', 'trading_name'].contains(key) &&
        v.isNotEmpty &&
        v.length < 2) {
      return t(
        'أدخل اسماً من حرفين على الأقل',
        'Enter at least two characters',
      );
    }
    if (key == 'year' &&
        v.isNotEmpty &&
        (int.tryParse(latinDigits(v)) == null ||
            int.parse(latinDigits(v)) < 1000 ||
            int.parse(latinDigits(v)) > 9999)) {
      return t('أدخل سنة مسجلة من ٤ أرقام', 'Enter a four-digit recorded year');
    }
    return null;
  }

  Widget input(String key, {bool required = false, int max = 120}) =>
      identified(
        'fleet-field-$key',
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: TextFormField(
            key: ValueKey('fleet-field-$key'),
            controller: field(key),
            enabled: allowed,
            maxLength: max,
            decoration: InputDecoration(labelText: label(key.split('.').last)),
            validator: (value) => validateField(
              key.split('.').last,
              value,
              required: required,
              max: max,
            ),
          ),
        ),
      );
  Widget filters({required bool vehicles}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      identified(
        'fleet-search',
        TextField(
          key: const ValueKey('fleet-search'),
          controller: search,
          enabled: !reading,
          maxLength: 120,
          decoration: InputDecoration(
            labelText: vehicles
                ? t(
                    'بحث دقيق ببادئة اللوحة أو بيانات السيارة',
                    'Literal prefix search for plate or vehicle details',
                  )
                : t(
                    'بحث ببادئة الاسم القانوني أو التجاري',
                    'Legal or trading name prefix search',
                  ),
          ),
          onChanged: (_) {
            readEpoch++;
            setState(() {
              rows = [];
              cursor = null;
              reading = false;
            });
          },
        ),
      ),
      CheckboxListTile(
        key: const ValueKey('fleet-include-archived'),
        value: includeArchived,
        onChanged: reading
            ? null
            : (value) {
                readEpoch++;
                setState(() {
                  includeArchived = value == true;
                  rows = [];
                  cursor = null;
                });
              },
        title: Text(t('إظهار المؤرشف أيضاً', 'Include archived records')),
        contentPadding: EdgeInsets.zero,
      ),
      action(
        'fleet-run-search',
        t('بحث وتحديث النتائج', 'Search and refresh results'),
        reading ? null : () => vehicles ? loadVehicles() : loadParties(),
      ),
    ],
  );
  Widget partyList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      action(
        'fleet-add-party',
        operation('party_create'),
        allowed ? () => startForm('party_create') : null,
        primary: true,
      ),
      filters(vehicles: false),
      if (loaded && !reading && readError.isEmpty && rows.isEmpty)
        Text(
          t(
            'لا توجد نتائج متاحة لهذا البحث.',
            'No records are available for this search.',
          ),
        ),
      for (final row in rows)
        Card(
          child: ListTile(
            key: ValueKey('fleet-party-${row['party_id']}'),
            title: Text('${row['legal_name'] ?? row['trading_name']}'),
            subtitle: Text(
              '${row['trading_name'] ?? ''}\n${row['archived'] == true ? t('مؤرشف', 'Archived') : t('نشط', 'Active')} · ${t('غير موثّق', 'Unverified')} · ${t('إصدار', 'Version')} ${row['version']}',
            ),
            onTap: reading ? null : () => openParty(row['party_id'] as String),
          ),
        ),
      if (cursor != null)
        action(
          'fleet-more-parties',
          t('عرض شركات إضافية', 'Load more companies'),
          reading ? null : () => loadParties(more: true),
        ),
    ],
  );
  Widget partyDetail() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (party != null) ...[
        Text(
          '${t('الإصدار الفعلي', 'Actual version')}: ${party!['version']} · ${party!['archived'] == true ? t('مؤرشف', 'Archived') : t('نشط', 'Active')}',
        ),
        termsView('party', party!['terms'] as Map),
        if ((party!['possible_same_name_parties'] as List? ?? []).isNotEmpty)
          Text(
            t(
              'توجد أسماء متشابهة لسجلات أخرى. تشابه الاسم لا يثبت الهوية ولا يدمج السجلات.',
              'Other records have similar names. A name match is not identity proof and does not merge records.',
            ),
          ),
        action(
          'fleet-edit-party',
          operation('party_edit'),
          allowed ? () => startForm('party_edit') : null,
        ),
        action(
          'fleet-state-party',
          operation(
            party!['archived'] == true ? 'party_reenable' : 'party_archive',
          ),
          allowed
              ? () => startForm(
                  party!['archived'] == true
                      ? 'party_reenable'
                      : 'party_archive',
                )
              : null,
        ),
        action(
          'fleet-party-history',
          t('عرض إصدارات الشركة', 'View company versions'),
          allowed
              ? () {
                  historyParent = 'party';
                  history = [];
                  historyCursor = null;
                  loadHistory();
                }
              : null,
        ),
        if (widget.contractBuilder != null)
          action(
            'fleet-company-contract-drafts',
            t('مسودات عقود الشركة', 'Company contract drafts'),
            allowed ? () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (context) => widget.contractBuilder!(context, party!['party_id'] as String),
            )) : null,
          ),
        const Divider(),
        Text(
          '${t('عدد السيارات المسجلة', 'Recorded vehicle count')}: ${party!['vehicle_count']}',
        ),
        Text(
          t(
            'الصفحات محدودة للعرض فقط؛ لا حد مصطنع لعدد سيارات الشركة.',
            'Pages are bounded for display; the catalogue has no per-company vehicle cap.',
          ),
        ),
        if (party!['archived'] == true)
          Text(
            t(
              'الشركة مؤرشفة؛ لا تُضاف أو تُفعّل سيارات حتى إعادة تفعيلها. حالة أرشفة كل سيارة مستقلة.',
              'The company is archived; adding or re-enabling cars requires an active company. Each car retains its own archive state.',
            ),
          ),
        action(
          'fleet-add-vehicle',
          operation('vehicle_create'),
          allowed && party!['archived'] == false
              ? () => startForm('vehicle_create')
              : null,
          primary: true,
        ),
        filters(vehicles: true),
        for (final row in rows)
          Card(
            child: ListTile(
              key: ValueKey('fleet-vehicle-${row['vehicle_id']}'),
              title: Text('${row['plate_number']}'),
              subtitle: Text(
                '${row['make'] ?? ''} ${row['model'] ?? ''}\n${row['effective_active'] == true ? t('نشط', 'Active') : t('غير نشط فعلياً', 'Effectively inactive')}',
              ),
              onTap: reading
                  ? null
                  : () => openVehicle(row['vehicle_id'] as String),
            ),
          ),
        if (cursor != null)
          action(
            'fleet-more-vehicles',
            t('عرض سيارات إضافية', 'Load more vehicles'),
            reading ? null : () => loadVehicles(more: true),
          ),
      ],
    ],
  );
  Widget vehicleDetail() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (vehicle != null) ...[
        Text(
          '${t('الإصدار الفعلي', 'Actual version')}: ${vehicle!['version']} · ${vehicle!['effective_active'] == true ? t('نشط', 'Active') : t('غير نشط فعلياً', 'Effectively inactive')}',
        ),
        termsView('vehicle', vehicle!['terms'] as Map),
        action(
          'fleet-edit-vehicle',
          operation('vehicle_edit'),
          allowed && vehicle!['party_archived'] == false
              ? () => startForm('vehicle_edit')
              : null,
        ),
        action(
          'fleet-state-vehicle',
          operation(
            vehicle!['archived'] == true
                ? 'vehicle_reenable'
                : 'vehicle_archive',
          ),
          allowed &&
                  (vehicle!['archived'] == false ||
                      vehicle!['party_archived'] == false)
              ? () => startForm(
                  vehicle!['archived'] == true
                      ? 'vehicle_reenable'
                      : 'vehicle_archive',
                )
              : null,
        ),
        Text(
          t(
            'انتماء السيارة للشركة ثابت هنا؛ لا يوجد نقل أو دمج سجلات.',
            'This car’s company affiliation is fixed here; transfer and merging are unavailable.',
          ),
        ),
        action(
          'fleet-vehicle-history',
          t('عرض إصدارات السيارة', 'View vehicle versions'),
          allowed
              ? () {
                  historyParent = 'vehicle';
                  history = [];
                  historyCursor = null;
                  loadHistory();
                }
              : null,
        ),
      ],
    ],
  );
  Widget catalogueForm() {
    final full = formKind.endsWith('_create') || formKind.endsWith('_edit'),
        isVehicle = formKind.startsWith('vehicle_');
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            operation(formKind),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            expectedVersion == null
                ? t(
                    'سجل جديد؛ لا تعديل لأي سجل سابق.',
                    'New record; no existing record is rewritten.',
                  )
                : '${t('الإصدار المتوقع', 'Expected version')}: $expectedVersion',
          ),
          if (full && isVehicle) ...[
            input('plate_country', max: 2),
            input('plate_number', required: true, max: 40),
            input('make', max: 80),
            input('model', max: 80),
            input('year', max: 4),
            input('color', max: 40),
            input('fleet_reference', max: 80),
          ] else if (full) ...[
            input('legal_name', max: 200),
            input('trading_name', max: 200),
            FormField<void>(
              validator: (_) =>
                  (text('legal_name')?.length ?? 0) >= 2 ||
                      (text('trading_name')?.length ?? 0) >= 2
                  ? null
                  : t(
                      'أدخل اسماً قانونياً أو تجارياً من حرفين على الأقل',
                      'Enter a legal or trading name of at least two characters',
                    ),
              builder: (state) => state.hasError
                  ? Text(
                      state.errorText!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            input('registration_country', max: 2),
            for (final group in ['tax', 'address', 'representative']) ...[
              CheckboxListTile(
                key: ValueKey('fleet-record-$group'),
                contentPadding: EdgeInsets.zero,
                value: group == 'tax'
                    ? tax
                    : group == 'address'
                    ? address
                    : representative,
                onChanged: allowed
                    ? (value) => setState(() {
                        if (group == 'tax') {
                          tax = value == true;
                        } else if (group == 'address') {
                          address = value == true;
                        } else {
                          representative = value == true;
                        }
                      })
                    : null,
                title: Text(
                  group == 'tax'
                      ? t(
                          'تسجيل هوية ضريبية فعلية (غير موثّقة)',
                          'Record actual tax identity (unverified)',
                        )
                      : group == 'address'
                      ? t('تسجيل عنوان منظم', 'Record structured address')
                      : t(
                          'تسجيل ممثل (غير موثّق، بلا صلاحية دخول)',
                          'Record representative (unverified, no account access)',
                        ),
                ),
              ),
              if (group == 'tax'
                  ? tax
                  : group == 'address'
                  ? address
                  : representative)
                for (final key in groupKeys(group))
                  input(
                    '$group.$key',
                    required:
                        group == 'tax' ||
                        (group == 'representative' && key == 'name'),
                    max: key == 'additional'
                        ? 300
                        : key == 'identifier_type'
                        ? 40
                        : key == 'number'
                        ? 80
                        : key == 'phone'
                        ? 64
                        : key == 'email'
                        ? 254
                        : key == 'country'
                        ? 2
                        : 120,
                  ),
            ],
            Text(
              t(
                'وسائل التواصل مسجلة للمالك فقط وليست حسابات دخول أو إثبات ملكية.',
                'Contacts are recorded for the owner only; they are not logins or possession proof.',
              ),
            ),
            for (var i = 0; i < contacts.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        key: ValueKey('fleet-contact-kind-$i'),
                        initialValue: contacts[i].kind,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: t('نوع وسيلة التواصل', 'Contact type'),
                        ),
                        items: [
                          for (final kind in ['phone', 'email', 'other'])
                            DropdownMenuItem(
                              value: kind,
                              child: Text(label(kind)),
                            ),
                        ],
                        onChanged: allowed
                            ? (value) =>
                                  setState(() => contacts[i].kind = value)
                            : null,
                        validator: (value) => value == null
                            ? t('اختر نوعاً صريحاً', 'Choose a contact type')
                            : null,
                      ),
                      TextFormField(
                        key: ValueKey('fleet-contact-value-$i'),
                        controller: contacts[i].value,
                        enabled: allowed,
                        maxLength: contacts[i].kind == 'phone' ? 64 : 254,
                        decoration: InputDecoration(labelText: label('value')),
                        validator: (value) {
                          final valid = validateField(
                            'value',
                            value,
                            required: true,
                            max: contacts[i].kind == 'phone' ? 64 : 254,
                          );
                          if (valid != null) return valid;
                          if (contacts[i].kind == 'email' &&
                              value!.trim().indexOf('@') < 1) {
                            return t(
                              'راجع صيغة البريد المسجل',
                              'Check the recorded email format',
                            );
                          }
                          return null;
                        },
                      ),
                      TextFormField(
                        controller: contacts[i].label,
                        enabled: allowed,
                        maxLength: 80,
                        decoration: InputDecoration(
                          labelText: label('contact_label'),
                        ),
                      ),
                      TextButton(
                        onPressed: allowed
                            ? () => setState(() {
                                retiredContacts.add(contacts.removeAt(i));
                              })
                            : null,
                        child: Text(
                          t(
                            'إزالة وسيلة التواصل من المسودة',
                            'Remove draft contact',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            action(
              'fleet-add-contact',
              t('إضافة وسيلة تواصل مسجلة', 'Add recorded contact'),
              allowed && contacts.length < 25
                  ? () => setState(() => contacts.add(_Contact()))
                  : null,
            ),
          ],
          identified(
            'fleet-change-reason',
            TextFormField(
              key: const ValueKey('fleet-change-reason'),
              controller: reason,
              enabled: allowed,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: t(
                  'سبب هذا الإجراء (١٠ أحرف على الأقل)',
                  'Reason for this action (at least 10 characters)',
                ),
              ),
              validator: (value) => (value?.trim().length ?? 0) < 10
                  ? t(
                      'أدخل سبباً فعلياً من ١٠ أحرف على الأقل',
                      'Enter an actual reason of at least 10 characters',
                    )
                  : null,
            ),
          ),
          action(
            'fleet-prepare',
            t('تحضير معاينة الإجراء', 'Prepare action preview'),
            allowed ? prepare : null,
            primary: true,
          ),
        ],
      ),
    );
  }

  Widget commandView() {
    final payload = c.receipt?['payload'] as Map?,
        result = c.receipt?['result'] as Map?;
    final type = payload?['kind'].toString().startsWith('vehicle_') == true
        ? 'vehicle'
        : 'party';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          c.phase == 'open'
              ? t(
                  'معاينة محفوظة؛ لم تُطبّق بعد.',
                  'Prepared preview; not applied yet.',
                )
              : c.phase == 'succeeded'
              ? t(
                  'تم تنفيذ الإجراء وحفظ الإصدار.',
                  'Action completed and version retained.',
                )
              : c.phase == 'closed'
              ? t(
                  'أُغلق المرجع بأمان. الإغلاق لا يلغي إجراءً سبق تنفيذه.',
                  'Reference safely closed. Closing does not undo a previously completed action.',
                )
              : t(
                  'النتيجة غير مؤكدة؛ استعد المرجع نفسه أو أغلقه قبل أي إجراء آخر.',
                  'Outcome unconfirmed; recover or close the same reference before another operation.',
                ),
        ),
        if (payload != null) ...[
          Text(operation(payload['kind'])),
          dataText(
            t('الإصدار المتوقع', 'Expected version'),
            payload['expected_version'],
          ),
          dataText(
            t('سبب الإجراء المسجل', 'Recorded action reason'),
            payload['reason'],
          ),
          if (payload['data'] is Map && (payload['data'] as Map).isNotEmpty)
            termsView(type, payload['data'] as Map),
        ],
        if (result?['entity'] is Map) ...[
          dataText(
            t('الإصدار الناتج', 'Resulting version'),
            result!['entity']['version'],
          ),
          termsView(
            result['entity_kind'] as String,
            result['entity']['terms'] as Map,
          ),
        ],
        if (c.canApply)
          action(
            'fleet-apply',
            t('تطبيق الإجراء المحضّر', 'Apply prepared action'),
            c.apply,
            primary: true,
          ),
        if (c.canRetryPrepare)
          action(
            'fleet-retry-prepare',
            t(
              'إعادة التحضير نفسه بالمرجع المحفوظ',
              'Retry the exact saved preparation',
            ),
            c.retryPrepare,
          ),
        action(
          'fleet-recover',
          t('استعادة نتيجة المرجع نفسه', 'Recover the same command result'),
          c.busy || !c.current ? null : c.recover,
        ),
        if (c.canClose)
          action(
            'fleet-close',
            t(
              'إغلاق المرجع غير المحسوم بأمان',
              'Safely close unresolved command',
            ),
            c.close,
          ),
        if (c.canAcknowledge)
          action(
            'fleet-acknowledge',
            t('راجعت النتيجة النهائية', 'I reviewed the definitive outcome'),
            acknowledge,
          ),
      ],
    );
  }

  Widget historyView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final row in history)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${operation(row['operation'])} · ${t('إصدار', 'Version')} ${row['version']}',
                ),
                Text(date(row['created_at'])),
                dataText(
                  t('بواسطة', 'By'),
                  row['actor_role'] == 'owner'
                      ? t('المالك', 'Owner')
                      : t('مستخدم مصرح', 'Authorized user'),
                ),
                dataText(t('السبب المسجل', 'Recorded reason'), row['reason']),
                Text(
                  t('قبل الإجراء', 'Before the action'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (row['before'] is Map)
                  snapshotView(
                    historyParent == 'vehicle' ? 'vehicle' : 'party',
                    row['before'] as Map,
                  )
                else
                  Text(
                    t(
                      'لا يوجد إصدار سابق؛ هذا إنشاء جديد.',
                      'No prior version; this created a new record.',
                    ),
                  ),
                Text(
                  t('بعد الإجراء', 'After the action'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                snapshotView(
                  historyParent == 'vehicle' ? 'vehicle' : 'party',
                  row['after'] as Map,
                ),
              ],
            ),
          ),
        ),
      if (historyCursor != null)
        action(
          'fleet-more-history',
          t('عرض إصدارات أقدم', 'Load older versions'),
          reading ? null : () => loadHistory(more: true),
        ),
    ],
  );
  String commandError() => switch (c.error) {
    'stale' => t(
      'الإصدار تغيّر. أغلق المرجع المحفوظ ثم أعد قراءة السجل؛ لا يُعاد إرسال نسخة جديدة تلقائياً.',
      'The version changed. Close the saved command and reload the record; no new request is sent automatically.',
    ),
    'conflict' => t(
      'يوجد تعارض في معرّف مسجل. راجع البيانات؛ لا دمج تلقائي ولا تحرير للمعرّف بالأرشفة.',
      'A recorded identifier conflicts. Review the data; there is no automatic merge or key release by archiving.',
    ),
    'denied' => t(
      'تعذر تأكيد صلاحية المالك الحالية. لا تُعرض بيانات خاصة قديمة.',
      'Current owner access could not be confirmed. Old private data is not displayed.',
    ),
    'invalid' => t(
      'راجع الحقول والغرض المسجل ثم استعد المرجع أو أغلقه.',
      'Review the fields and reason, then recover or close the reference.',
    ),
    'blocked' => t(
      'حالة السجل لا تسمح بهذا الإجراء. استعد المرجع أو أغلقه وراجع الحالة الحالية.',
      'The record state blocks this action. Recover or close the command and check the current state.',
    ),
    _ => t(
      'تعذر تأكيد النتيجة. احتفظ بالمرجع المحفوظ نفسه ولا تبدأ إجراءً بديلاً.',
      'The outcome is unconfirmed. Keep the same saved reference and do not start another operation.',
    ),
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f6f8),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(title),
      leading: !['parties', 'command'].contains(view)
          ? IconButton(
              key: const ValueKey('fleet-back-to-records'),
              tooltip: t('العودة إلى السجل', 'Back to records'),
              onPressed: reading ? null : back,
              icon: const Icon(Icons.arrow_back),
            )
          : null,
    ),
    body: !c.current
        ? Center(
            child: Text(
              t(
                'تغيرت الجلسة. أعد فتح الدليل بحساب المالك المصرّح.',
                'Session changed. Reopen the catalogue with the authorized owner account.',
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              identified(
                'fleet-scope-notice',
                Text(
                  t(
                    'دليل خاص بالمالك. بيانات الشركات والضرائب والتواصل والممثلين مسجلة وغير موثّقة. لا توجد هنا حسابات شركة أو فواتير أو أسعار أو ائتمان أو إرسال ضريبي رسمي.',
                    'Private owner catalogue. Company, tax, contact and representative details are recorded and unverified. Company logins, billing, prices, credit and official tax submission are unavailable here.',
                  ),
                ),
              ),
              if (reading || c.busy) const LinearProgressIndicator(),
              if (c.error.isNotEmpty) Text(commandError()),
              if (readError.isNotEmpty)
                Text(
                  t(
                    'تعذر جلب السجلات الحالية. أعد المحاولة؛ لا نفترض نتائج فارغة.',
                    'Current records could not be retrieved. Retry; an empty catalogue is not assumed.',
                  ),
                ),
              if (!c.ready && !c.busy)
                action(
                  'fleet-retry-initialize',
                  t('التحقق من صلاحية الوصول مجدداً', 'Check access again'),
                  c.initialize,
                ),
              if (c.ready)
                switch (view) {
                  'form' => catalogueForm(),
                  'command' => commandView(),
                  'party' => partyDetail(),
                  'vehicle' => vehicleDetail(),
                  'history' => historyView(),
                  _ => partyList(),
                },
            ],
          ),
  );
}
