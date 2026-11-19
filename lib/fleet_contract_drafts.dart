import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

final _contractUuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class FleetContractReference {
  const FleetContractReference(this.request, this.fingerprint);
  final String request, fingerprint;
  bool get valid =>
      _contractUuid.hasMatch(request) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint);
  String encode() => jsonEncode([request, fingerprint]);
}

abstract class FleetContractStore {
  Future<FleetContractReference?> read();
  Future<void> save(FleetContractReference reference);
  Future<void> clear(FleetContractReference expected);
}

class SharedFleetContractStore implements FleetContractStore {
  SharedFleetContractStore(this.client, this.party)
    : actor = client.auth.currentUser?.id,
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String party;
  final String? actor, token;
  static final _writes = <String, Future<void>>{};
  String get key {
    if (actor == null ||
        token == null ||
        client.auth.currentUser?.id != actor ||
        client.auth.currentSession?.accessToken != token ||
        client.auth.currentSession?.user.id != actor ||
        !_contractUuid.hasMatch(party)) {
      throw StateError('Session changed');
    }
    return 'fleet_contract_reference/$actor/$party';
  }

  @override
  Future<FleetContractReference?> read() async {
    final bound = key, prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (key != bound) throw StateError('Session changed');
    final value = prefs.getString(bound);
    if (value == null) return null;
    final ids = jsonDecode(value);
    if (ids is! List || ids.length != 2 || ids.any((v) => v is! String)) {
      throw StateError('Invalid draft reference');
    }
    final ref = FleetContractReference(ids[0], ids[1]);
    if (!ref.valid) throw StateError('Invalid draft reference');
    return ref;
  }

  Future<void> serialized(Future<void> Function() task) async {
    final bound = key,
        previous = _writes[bound] ?? Future<void>.value(),
        done = Completer<void>();
    _writes[bound] = done.future;
    try {
      await previous;
      if (key != bound) throw StateError('Session changed');
      await task();
    } finally {
      done.complete();
      if (identical(_writes[bound], done.future)) _writes.remove(bound);
    }
  }

  @override
  Future<void> save(FleetContractReference reference) => serialized(() async {
    if (!reference.valid) throw StateError('Invalid reference');
    final prior = await read();
    if (prior != null && prior.encode() != reference.encode()) {
      throw StateError('Unresolved draft reference');
    }
    final bound = key, prefs = await SharedPreferences.getInstance();
    if (key != bound) throw StateError('Session changed');
    if (!await prefs.setString(bound, reference.encode())) {
      throw StateError('Reference not saved');
    }
    if (key != bound) throw StateError('Session changed');
  });
  @override
  Future<void> clear(FleetContractReference expected) => serialized(() async {
    final prior = await read();
    if (prior != null && prior.encode() != expected.encode()) {
      throw StateError('Reference changed');
    }
    final bound = key, prefs = await SharedPreferences.getInstance();
    if (key != bound) throw StateError('Session changed');
    if (prior != null && !await prefs.remove(bound)) {
      throw StateError('Reference not cleared');
    }
  });
}

abstract class FleetContractGateway {
  bool get current;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  );
}

class SupabaseFleetContractGateway implements FleetContractGateway {
  SupabaseFleetContractGateway(this.client)
    : actor = client.auth.currentUser?.id,
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? actor, token;
  @override
  bool get current =>
      actor != null &&
      token != null &&
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession?.accessToken == token &&
      client.auth.currentSession?.user.id == actor;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    if (!current ||
        !const {
          'get_fleet_contract_draft_context',
          'list_fleet_contracts',
          'save_fleet_contract_draft',
          'get_fleet_contract_command',
          'close_fleet_contract_command',
          'get_fleet_contract_draft_history',
        }.contains(name)) {
      throw StateError('Contract endpoint unavailable');
    }
    final result = await client
        .rpc(name, params: parameters)
        .timeout(const Duration(seconds: 25));
    if (!current) throw StateError('Session changed');
    return Map<String, dynamic>.from(result as Map);
  }
}

class _ContractRate {
  _ContractRate([Map? value])
    : service = value?['service_id'] as String?,
      price = TextEditingController(
        text: value?['price_egp']?.toString() ?? '',
      );
  final key = newOrderRequestId();
  String? service;
  final TextEditingController price;
}

class FleetContractDraftsScreen extends StatefulWidget {
  const FleetContractDraftsScreen({
    super.key,
    required this.client,
    required this.partyId,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final String partyId;
  final FleetContractGateway? gateway;
  final FleetContractStore? store;
  @override
  State<FleetContractDraftsScreen> createState() =>
      _FleetContractDraftsScreenState();
}

class _FleetContractDraftsScreenState extends State<FleetContractDraftsScreen> {
  late FleetContractGateway gateway;
  late FleetContractStore store;
  StreamSubscription<AuthState>? auth;
  Map<String, dynamic>? options, receipt, editing, payload;
  List<Map<String, dynamic>> rows = [], history = [];
  FleetContractReference? reference;
  String phase = 'list', error = '', cycle = 'per_visit', method = 'cash';
  bool busy = false,
      invalid = false,
      ready = false,
      more = false,
      historyMore = false,
      archiveOnly = false;
  int epoch = 0;
  String? historyContract;
  final formKey = GlobalKey<FormState>();
  final nameAr = TextEditingController(),
      nameEn = TextEditingController(),
      start = TextEditingController(),
      end = TextEditingController(),
      due = TextEditingController(),
      notesAr = TextEditingController(),
      notesEn = TextEditingController(),
      reason = TextEditingController();
  List<_ContractRate> rates = [];
  final retired = <_ContractRate>[];
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool live(int generation) =>
      mounted && !invalid && gateway.current && epoch == generation;
  bool get canManage => options?['can_manage_drafts'] == true;
  String latin(String s) => s
      .replaceAllMapped(RegExp('[٠-٩۰-۹]'), (m) {
        final n = m[0]!.codeUnitAt(0);
        return '${n >= 0x06f0 ? n - 0x06f0 : n - 0x0660}';
      })
      .replaceAll('٫', '.');
  @override
  void initState() {
    super.initState();
    gateway = widget.gateway ?? SupabaseFleetContractGateway(widget.client);
    store =
        widget.store ?? SharedFleetContractStore(widget.client, widget.partyId);
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      if (mounted) setState(invalidate);
    });
    unawaited(load());
  }

  void invalidate() {
    invalid = true;
    epoch++;
    busy = false;
    ready = false;
    options = null;
    rows = [];
    history = [];
    receipt = null;
    payload = null;
  }

  @override
  void didUpdateWidget(covariant FleetContractDraftsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.partyId != widget.partyId ||
        oldWidget.gateway != widget.gateway ||
        oldWidget.store != widget.store) {
      invalidate();
    }
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    for (final c in [
      nameAr,
      nameEn,
      start,
      end,
      due,
      notesAr,
      notesEn,
      reason,
    ]) {
      c.dispose();
    }
    for (final rate in [...rates, ...retired]) {
      rate.price.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function(int) task) async {
    if (busy || invalid || !gateway.current) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await task(generation);
    } catch (e) {
      if (live(generation)) {
        setState(() {
          error = e is PostgrestException && e.code == '40001'
              ? 'conflict'
              : 'unconfirmed';
          options = null;
          rows = [];
          history = [];
          receipt = null;
          ready = false;
          phase = reference != null ? 'uncertain' : 'list';
        });
      }
    } finally {
      if (live(generation)) setState(() => busy = false);
    }
  }

  void validateEntity(Map value) {
    if (value['party_id'] != widget.partyId ||
        !_contractUuid.hasMatch('${value['contract_id']}') ||
        !_contractUuid.hasMatch('${value['branch_id']}') ||
        value['version'] is! int ||
        (value['version'] as int) < 1 ||
        !const {'draft', 'archived'}.contains(value['state']) ||
        value['terms'] is! Map) {
      throw StateError('Unverified contract');
    }
    final terms = value['terms'] as Map;
    if (terms['currency'] != 'EGP' ||
        terms['pricing_active'] != false ||
        terms['tax_configuration'] != 'unconfigured' ||
        terms['name_ar'] is! String ||
        (terms['name_ar'] as String).trim().isEmpty ||
        terms['name_en'] is! String ||
        (terms['name_en'] as String).trim().isEmpty ||
        terms['services'] is! List ||
        (terms['services'] as List).isEmpty ||
        (terms['services'] as List).length > 100) {
      throw StateError('Unverified draft terms');
    }
    final ids = <String>{};
    for (final entry in terms['services'] as List) {
      if (entry is! Map ||
          !_contractUuid.hasMatch('${entry['service_id']}') ||
          !ids.add(entry['service_id'] as String) ||
          entry['price_egp'] is! num ||
          !(entry['price_egp'] as num).isFinite ||
          entry['price_egp'] < 0 ||
          entry['price_egp'] > 999999999.99) {
        throw StateError('Unverified draft service');
      }
    }
  }

  void applyResult(Map<String, dynamic> data) {
    if (reference == null || data['request_id'] != reference!.request) {
      throw StateError('Unverified command');
    }
    if (data['state'] == 'absent') {
      if (data['definitive_failure'] != false) {
        throw StateError('Unverified absence');
      }
      receipt = null;
      phase = 'uncertain';
      return;
    }
    if (data['state'] == 'closed') {
      if (data['definitive_failure'] != true) {
        throw StateError('Unverified close');
      }
    } else if (data['state'] == 'succeeded') {
      if (data['draft_only'] != true ||
          data['pricing_active'] != false ||
          data['billing_enabled'] != false ||
          data['entity'] is! Map) {
        throw StateError('Unverified draft receipt');
      }
      validateEntity(data['entity'] as Map);
    } else {
      throw StateError('Unknown receipt state');
    }
    receipt = data;
    phase = 'receipt';
  }

  Future<void> readData(int generation) async {
    final saved = await store.read();
    if (!live(generation)) return;
    reference = saved;
    final context = await gateway.call('get_fleet_contract_draft_context', {
      'p_party': widget.partyId,
    });
    if (!live(generation)) return;
    if (context['module'] != 'fleet_contract_drafts_v1' ||
        context['party_id'] != widget.partyId ||
        context['draft_only'] != true ||
        context['pricing_active'] != false ||
        context['billing_enabled'] != false ||
        context['eta_submission_enabled'] != false ||
        context['contract_activation_available'] != false ||
        context['currency'] != 'EGP' ||
        context['services'] is! List) {
      throw StateError('Unverified draft context');
    }
    final data = await gateway.call('list_fleet_contracts', {
      'p_party': widget.partyId,
      'p_before_created_at': null,
      'p_before_id': null,
      'p_limit': 25,
    });
    if (!live(generation)) return;
    if (data['draft_only'] != true ||
        data['pricing_active'] != false ||
        data['billing_enabled'] != false ||
        data['items'] is! List ||
        (data['items'] as List).length > 25) {
      throw StateError('Unverified draft list');
    }
    final actual = (data['items'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    for (final row in actual) {
      validateEntity(row);
    }
    options = context;
    rows = actual;
    more = actual.length == 25;
    ready = true;
    phase = 'list';
    receipt = null;
    if (reference != null) {
      final data = await gateway.call('get_fleet_contract_command', {
        'p_request': reference!.request,
      });
      if (!live(generation)) return;
      applyResult(data);
    }
    if (live(generation)) setState(() {});
  }

  Future<void> load() => run(readData);
  void startForm([Map<String, dynamic>? row, bool archive = false]) {
    if (busy ||
        invalid ||
        reference != null ||
        !ready ||
        (!archive && !canManage)) {
      return;
    }
    editing = row;
    archiveOnly = archive;
    final terms = row?['terms'] as Map?;
    nameAr.text = terms?['name_ar']?.toString() ?? '';
    nameEn.text = terms?['name_en']?.toString() ?? '';
    final now = DateTime.now();
    start.text =
        terms?['starts_on']?.toString() ??
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    end.text = terms?['ends_on']?.toString() ?? '';
    cycle = terms?['billing_cycle'] as String? ?? 'per_visit';
    method = terms?['payment_method'] as String? ?? 'cash';
    due.text = '${terms?['due_days'] ?? 0}';
    notesAr.text = terms?['notes_ar']?.toString() ?? '';
    notesEn.text = terms?['notes_en']?.toString() ?? '';
    reason.clear();
    retired.addAll(rates);
    rates = [
      for (final v in (terms?['services'] as List? ?? []))
        _ContractRate(v as Map),
    ];
    if (rates.isEmpty) rates.add(_ContractRate());
    setState(() {
      phase = 'form';
      error = '';
      payload = null;
    });
  }

  Map<String, dynamic> formPayload() {
    final ids = rates.map((r) => r.service).toSet();
    if (ids.length != rates.length) throw StateError('Duplicate service');
    return {
      'p_party': widget.partyId,
      'p_branch':
          editing?['branch_id'] ?? (options!['branch'] as Map)['branch_id'],
      'p_contract': editing?['contract_id'],
      'p_expected_version': editing?['version'],
      'p_terms': archiveOnly
          ? null
          : {
              'name_ar': nameAr.text.trim(),
              'name_en': nameEn.text.trim(),
              'starts_on': latin(start.text.trim()),
              'ends_on': end.text.trim().isEmpty
                  ? null
                  : latin(end.text.trim()),
              'billing_cycle': cycle,
              'payment_method': method,
              'due_days': method == 'credit'
                  ? int.parse(latin(due.text.trim()))
                  : 0,
              'services': [
                for (final rate in rates)
                  {
                    'service_id': rate.service,
                    'price_egp': num.parse(latin(rate.price.text.trim())),
                  },
              ],
              'notes_ar': notesAr.text.trim().isEmpty
                  ? null
                  : notesAr.text.trim(),
              'notes_en': notesEn.text.trim().isEmpty
                  ? null
                  : notesEn.text.trim(),
            },
      'p_archive': archiveOnly,
      'p_reason': reason.text.trim(),
    };
  }

  void preview() {
    if (busy || formKey.currentState?.validate() != true) return;
    try {
      payload = jsonDecode(jsonEncode(formPayload())) as Map<String, dynamic>;
      setState(() {
        phase = 'preview';
        error = '';
      });
    } catch (_) {
      setState(() => error = 'invalid');
    }
  }

  Future<void> save() => run((generation) async {
    if (reference != null || payload == null) return;
    final data = <String, dynamic>{
      'p_request': newOrderRequestId(),
      ...payload!,
    };
    final ref = FleetContractReference(
      data['p_request'],
      sha256.convert(utf8.encode(jsonEncode(data))).toString(),
    );
    await store.save(ref);
    if (!live(generation)) return;
    reference = ref;
    payload = data;
    phase = 'uncertain';
    final result = await gateway.call('save_fleet_contract_draft', data);
    if (!live(generation)) return;
    setState(() => applyResult(result));
  });
  Future<void> retry() => run((generation) async {
    if (reference == null || payload?['p_request'] != reference!.request) {
      return;
    }
    final result = await gateway.call(
      'save_fleet_contract_draft',
      jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    );
    if (live(generation)) setState(() => applyResult(result));
  });
  Future<void> recover() => run((generation) async {
    if (reference == null) return;
    final result = await gateway.call('get_fleet_contract_command', {
      'p_request': reference!.request,
    });
    if (live(generation)) setState(() => applyResult(result));
  });
  Future<void> close() => run((generation) async {
    if (reference == null) return;
    final result = await gateway.call('close_fleet_contract_command', {
      'p_request': reference!.request,
    });
    if (live(generation)) setState(() => applyResult(result));
  });
  Future<void> acknowledge() => run((generation) async {
    if (reference == null ||
        !const {'succeeded', 'closed'}.contains(receipt?['state'])) {
      return;
    }
    await store.clear(reference!);
    if (!live(generation)) return;
    reference = null;
    receipt = null;
    payload = null;
    await readData(generation);
  });
  Future<void> loadMore() => run((generation) async {
    if (!more || rows.isEmpty || reference != null) return;
    final last = rows.last;
    final data = await gateway.call('list_fleet_contracts', {
      'p_party': widget.partyId,
      'p_before_created_at': last['created_at'],
      'p_before_id': last['contract_id'],
      'p_limit': 25,
    });
    if (!live(generation)) return;
    if (data['draft_only'] != true ||
        data['pricing_active'] != false ||
        data['items'] is! List ||
        (data['items'] as List).length > 25) {
      throw StateError('Unverified page');
    }
    final next = (data['items'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    for (final row in next) {
      validateEntity(row);
    }
    final merged = [...rows, ...next];
    if (merged.map((r) => r['contract_id']).toSet().length != merged.length) {
      throw StateError('Repeated cursor');
    }
    setState(() {
      rows = merged;
      more = next.length == 25;
    });
  });
  Future<void> showHistory(Map<String, dynamic> row, {bool append = false}) =>
      run((generation) async {
        final before = append && history.isNotEmpty
            ? history.last['version']
            : null;
        final data = await gateway.call('get_fleet_contract_draft_history', {
          'p_contract': row['contract_id'],
          'p_before_version': before,
          'p_limit': 25,
        });
        if (!live(generation)) return;
        if (data['contract_id'] != row['contract_id'] ||
            data['draft_only'] != true ||
            data['items'] is! List ||
            (data['items'] as List).length > 25) {
          throw StateError('Unverified history');
        }
        final next = (data['items'] as List)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList();
        for (final v in next) {
          if (v['after'] is! Map) throw StateError('Invalid history');
          validateEntity(v['after'] as Map);
          if (v['after']['contract_id'] != row['contract_id'] ||
              v['version'] != v['after']['version']) {
            throw StateError('History scope changed');
          }
        }
        setState(() {
          history = append ? [...history, ...next] : next;
          historyMore = next.length == 25;
          historyContract = row['contract_id'];
          phase = 'history';
        });
      });
  String label(Object? value) => switch (value) {
    'draft' => t('مسودة', 'Draft'),
    'archived' => t('مؤرشف', 'Archived'),
    'per_visit' => t('لكل زيارة', 'Per visit'),
    'weekly' => t('أسبوعي', 'Weekly'),
    'monthly' => t('شهري', 'Monthly'),
    'cash' => t('نقدي', 'Cash'),
    'electronic' => t(
      'إلكتروني — نية سداد فقط',
      'Electronic — payment intent only',
    ),
    'bank_transfer' => t(
      'تحويل بنكي — نية سداد فقط',
      'Bank transfer — payment intent only',
    ),
    'credit' => t('آجل — دون إنشاء مديونية', 'Credit — no receivable created'),
    _ => t('غير مسجل', 'Not recorded'),
  };
  String digits(String value) => ar
      ? value.replaceAllMapped(
          RegExp('[0-9]'),
          (m) => '٠١٢٣٤٥٦٧٨٩'[int.parse(m[0]!)],
        )
      : value;
  String money(Object? value) {
    if (value is! num || !value.isFinite) return t('غير مسجل', 'Not recorded');
    return ar
        ? '${digits(value.toStringAsFixed(2)).replaceAll('.', '٫')} جنيه مصري'
        : 'EGP ${value.toStringAsFixed(2)}';
  }

  String date(Object? value, {bool includeTime = false}) {
    final parsed = DateTime.tryParse('$value');
    if (parsed == null) return t('غير محدد', 'Not specified');
    final local = includeTime ? parsed.toLocal() : parsed;
    final labels = MaterialLocalizations.of(context);
    final day = labels.formatFullDate(local);
    return includeTime
        ? '$day · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))} · ${t('بتوقيت الجهاز', 'device local time')}'
        : day;
  }

  String serviceName(Map value) {
    Map data = value;
    if (data['name_ar'] == null && data['name_en'] == null) {
      for (final service in (options?['services'] as List? ?? [])) {
        if (service['service_id'] == value['service_id']) {
          data = service as Map;
          break;
        }
      }
    }
    final desired = data[ar ? 'name_ar' : 'name_en'];
    if (desired is String && desired.trim().isNotEmpty) return desired;
    final other = data[ar ? 'name_en' : 'name_ar'];
    return other is String && other.trim().isNotEmpty
        ? '$other · ${t('الترجمة غير متاحة', 'Translation unavailable')}'
        : t('خدمة غير متاحة', 'Service unavailable');
  }

  bool validDate(String value) {
    final text = latin(value.trim()), parsed = DateTime.tryParse(text);
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) &&
        parsed != null &&
        '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' ==
            text;
  }

  Widget input(
    TextEditingController controller,
    String title, {
    int max = 160,
    bool required = false,
    bool multiline = false,
    String? Function(String?)? validate,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      maxLength: max,
      minLines: multiline ? 2 : 1,
      maxLines: multiline ? 4 : 1,
      decoration: InputDecoration(labelText: title),
      validator:
          validate ??
          (value) => required && (value?.trim().isEmpty ?? true)
              ? t('هذا الحقل مطلوب', 'This field is required')
              : null,
    ),
  );
  Widget termsView(Map terms) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('${t('الاسم', 'Name')}: ${terms[ar ? 'name_ar' : 'name_en']}'),
      Text(
        '${t('الفترة', 'Period')}: ${date(terms['starts_on'])} — ${date(terms['ends_on'])}',
      ),
      Text(
        '${t('دورية الفوترة المقترحة', 'Proposed billing cycle')}: ${label(terms['billing_cycle'])}',
      ),
      Text(
        '${t('نية السداد', 'Payment intent')}: ${label(terms['payment_method'])}',
      ),
      Text(
        '${t('أيام الاستحقاق المقترحة', 'Proposed due days')}: ${digits('${terms['due_days']}')}',
      ),
      for (final item in (terms['services'] as List? ?? []))
        Text('${serviceName(item as Map)}: ${money(item['price_egp'])}'),
      if (terms[ar ? 'notes_ar' : 'notes_en'] != null)
        Text(
          '${t('ملاحظات', 'Notes')}: ${terms[ar ? 'notes_ar' : 'notes_en']}',
        ),
    ],
  );
  Widget action(
    String a,
    String e,
    VoidCallback? pressed, {
    bool primary = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: primary
        ? FilledButton(
            onPressed: busy || invalid ? null : pressed,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xff174b83),
            ),
            child: Text(t(a, e)),
          )
        : OutlinedButton(
            onPressed: busy || invalid ? null : pressed,
            child: Text(t(a, e)),
          ),
  );
  Widget contractForm() {
    final services = (options?['services'] as List? ?? []).cast<Map>();
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            archiveOnly
                ? t(
                    'أرشفة المسودة دون حذف سجلها',
                    'Archive the draft while retaining its history',
                  )
                : t('شروط مسودة العقد', 'Contract draft terms'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (!archiveOnly) ...[
            input(
              nameAr,
              t('اسم العقد بالعربية', 'Contract name in Arabic'),
              required: true,
            ),
            input(
              nameEn,
              t('اسم العقد بالإنجليزية', 'Contract name in English'),
              required: true,
            ),
            input(
              start,
              t('تاريخ البدء YYYY-MM-DD', 'Start date YYYY-MM-DD'),
              max: 10,
              validate: (v) => validDate(v ?? '')
                  ? null
                  : t(
                      'أدخل تاريخاً صحيحاً بالصيغة المحددة',
                      'Enter a valid date in the stated format',
                    ),
            ),
            input(
              end,
              t(
                'تاريخ الانتهاء YYYY-MM-DD (اختياري)',
                'End date YYYY-MM-DD (optional)',
              ),
              max: 10,
              validate: (v) => (v?.trim().isEmpty ?? true) || validDate(v!)
                  ? null
                  : t('أدخل تاريخاً صحيحاً', 'Enter a valid date'),
            ),
            Semantics(
              identifier: 'fleet-contract-cycle',
              child: DropdownButtonFormField<String>(
                initialValue: cycle,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t(
                    'دورية الفوترة المقترحة',
                    'Proposed billing cycle',
                  ),
                ),
                items: [
                  for (final value in ['per_visit', 'weekly', 'monthly'])
                    DropdownMenuItem(value: value, child: Text(label(value))),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => cycle = value!),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              identifier: 'fleet-contract-method',
              child: DropdownButtonFormField<String>(
                initialValue: method,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t('نية السداد', 'Payment intent'),
                ),
                items: [
                  for (final value in [
                    'cash',
                    'electronic',
                    'bank_transfer',
                    'credit',
                  ])
                    DropdownMenuItem(
                      value: value,
                      child: Text(label(value), maxLines: 2),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => method = value!),
              ),
            ),
            if (method == 'credit')
              input(
                due,
                t('أيام الاستحقاق المقترحة', 'Proposed due days'),
                max: 3,
                validate: (v) {
                  final n = int.tryParse(latin(v ?? ''));
                  return n == null || n < 0 || n > 365
                      ? t(
                          'أدخل عدداً من ٠ إلى ٣٦٥',
                          'Enter a number from 0 to 365',
                        )
                      : null;
                },
              ),
            const Divider(),
            Text(
              t(
                'الخدمات والأسعار المتفق عليها في المسودة',
                'Services and agreed draft prices',
              ),
            ),
            for (final rate in rates)
              Card(
                key: ValueKey(rate.key),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        identifier: 'fleet-contract-service-${rate.key}',
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('service-${rate.key}'),
                          initialValue:
                              services.any(
                                (s) => s['service_id'] == rate.service,
                              )
                              ? rate.service
                              : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: t('الخدمة', 'Service'),
                          ),
                          items: [
                            for (final service in services)
                              DropdownMenuItem(
                                value: service['service_id'] as String,
                                child: Text(
                                  serviceName(service),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) => setState(() => rate.service = value),
                          validator: (value) => value == null
                              ? t(
                                  'اختر خدمة نشطة فعلية',
                                  'Choose an actual active service',
                                )
                              : null,
                        ),
                      ),
                      input(
                        rate.price,
                        t(
                          'سعر الخدمة المتفق عليه EGP',
                          'Agreed service price (EGP)',
                        ),
                        max: 12,
                        validate: (v) {
                          final text = latin((v ?? '').trim()),
                              price = num.tryParse(text);
                          return !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text) ||
                                  price == null ||
                                  !price.isFinite ||
                                  price < 0 ||
                                  price > 999999999.99
                              ? t(
                                  'أدخل سعراً صحيحاً بالجنيه حتى منزلتين عشريتين',
                                  'Enter a valid EGP price with up to two decimals',
                                )
                              : null;
                        },
                      ),
                      if (rates.length > 1)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  rates.remove(rate);
                                  retired.add(rate);
                                }),
                          child: Text(
                            t(
                              'إزالة الخدمة من المسودة',
                              'Remove draft service',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            action(
              'إضافة خدمة للمسودة',
              'Add draft service',
              rates.length >= 100
                  ? null
                  : () => setState(() => rates.add(_ContractRate())),
            ),
            input(
              notesAr,
              t('ملاحظات بالعربية (اختياري)', 'Arabic notes (optional)'),
              max: 1000,
              multiline: true,
            ),
            input(
              notesEn,
              t('ملاحظات بالإنجليزية (اختياري)', 'English notes (optional)'),
              max: 1000,
              multiline: true,
            ),
          ],
          input(
            reason,
            t(
              'سبب الإجراء (١٠ أحرف على الأقل)',
              'Action reason (at least 10 characters)',
            ),
            max: 500,
            multiline: true,
            validate: (v) => (v?.trim().length ?? 0) < 10
                ? t(
                    'أدخل سبباً من ١٠ أحرف على الأقل',
                    'Enter a reason of at least 10 characters',
                  )
                : null,
          ),
          action('معاينة المسودة', 'Preview draft', preview, primary: true),
          action(
            'العودة دون إرسال',
            'Back without sending',
            () => setState(() => phase = 'list'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xff071a36),
        foregroundColor: Colors.white,
        title: Text(t('مسودات عقود الشركات', 'Company contract drafts')),
        actions: [
          IconButton(
            onPressed: busy || invalid || phase == 'form' || phase == 'preview'
                ? null
                : load,
            icon: const Icon(Icons.refresh),
            tooltip: t('تحديث', 'Refresh'),
          ),
        ],
      ),
      body: invalid
          ? Center(
              child: Text(
                t(
                  'تغير الحساب أو نطاق الشركة. أعد فتح الصفحة بالحساب الصحيح.',
                  'Account or company scope changed. Reopen with the correct account.',
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  t(
                    'مسودات فقط: لا تُطبق هذه الأسعار على الحجوزات أو الفواتير، ولا تنشئ مستحقات أو مستندات ETA. الضرائب والتفعيل الفعلي غير مهيأين.',
                    'Drafts only: these prices do not apply to bookings or invoices and do not create receivables or ETA documents. Tax and live activation are not configured.',
                  ),
                ),
                if (options != null)
                  Text(
                    '${t('الشركة', 'Company')}: ${options!['company_name']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                if (busy) const LinearProgressIndicator(),
                if (error.isNotEmpty)
                  Text(
                    error == 'conflict'
                        ? t(
                            'تغير إصدار العقد. أغلق المرجع المعلق بأمان ثم حدّث البيانات.',
                            'Contract version changed. Safely close the pending reference and refresh.',
                          )
                        : error == 'invalid'
                        ? t(
                            'راجع الخدمات والقيم؛ لا تُكرر الخدمة في المسودة.',
                            'Check the services and values; do not repeat a draft service.',
                          )
                        : t(
                            'تعذر تأكيد النتيجة. احتفظ بالمرجع وتحقق مجدداً؛ لا تبدأ طلباً آخر.',
                            'The outcome could not be confirmed. Keep the reference and check again; do not start another request.',
                          ),
                  ),
                if (phase == 'list' && ready && reference == null) ...[
                  action(
                    'إضافة مسودة عقد',
                    'Add contract draft',
                    canManage && (options!['services'] as List).isNotEmpty
                        ? () => startForm()
                        : null,
                    primary: true,
                  ),
                  if (!canManage)
                    Text(
                      t(
                        'إدارة المسودات غير متاحة لهذه الشركة أو لإعداد المركز الحالي.',
                        'Draft management is unavailable for this company or the current establishment configuration.',
                      ),
                    ),
                  if (rows.isEmpty)
                    Text(
                      t(
                        'لا توجد مسودات عقود مسجلة.',
                        'No contract drafts are recorded.',
                      ),
                    ),
                  for (final row in rows)
                    Semantics(
                      identifier: "fleet-contract-row-${row['contract_id']}",
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${label(row['state'])} · ${t('الإصدار', 'Version')} ${digits('${row['version']}')}',
                              ),
                              termsView(row['terms'] as Map),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed:
                                        busy ||
                                            row['state'] != 'draft' ||
                                            !canManage ||
                                            row['branch_id'] !=
                                                (options?['branch']
                                                    as Map?)?['branch_id']
                                        ? null
                                        : () => startForm(row),
                                    child: Text(
                                      t('تعديل المسودة', 'Edit draft'),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => showHistory(row),
                                    child: Text(
                                      t('سجل التعديلات', 'Revision history'),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: busy || row['state'] != 'draft'
                                        ? null
                                        : () => startForm(row, true),
                                    child: Text(
                                      t('أرشفة المسودة', 'Archive draft'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (more)
                    action('عرض مسودات أقدم', 'Load older drafts', loadMore),
                ],
                if (phase == 'form') contractForm(),
                if (phase == 'preview' && payload != null) ...[
                  Text(
                    t(
                      'معاينة قبل الحفظ؛ لم يتغير أي سجل بعد.',
                      'Preview before saving; no record has changed yet.',
                    ),
                  ),
                  if (payload!['p_terms'] is Map)
                    termsView(payload!['p_terms'] as Map)
                  else
                    Text(
                      t(
                        'أرشفة المسودة دون تعديل شروطها أو حذف تاريخها.',
                        'Archive the draft without changing its terms or deleting history.',
                      ),
                    ),
                  Text('${t('السبب', 'Reason')}: ${payload!['p_reason']}'),
                  action(
                    'حفظ المسودة فقط',
                    'Save draft only',
                    save,
                    primary: true,
                  ),
                  action(
                    'العودة للتعديل دون إرسال',
                    'Back to edit without sending',
                    () => setState(() => phase = 'form'),
                  ),
                ],
                if (phase == 'uncertain' && reference != null) ...[
                  Text(
                    t(
                      'المرجع محفوظ. غياب الإيصال ليس دليلاً على فشل الطلب.',
                      'The reference is saved. A missing receipt does not prove failure.',
                    ),
                  ),
                  if (payload?['p_request'] == reference!.request)
                    action(
                      'إعادة إرسال الطلب نفسه',
                      'Retry the exact request',
                      retry,
                    ),
                  action(
                    'التحقق من الطلب المحفوظ',
                    'Check saved request',
                    recover,
                  ),
                  action(
                    'إغلاق الطلب غير المحسوم بأمان',
                    'Safely close unresolved request',
                    close,
                  ),
                ],
                if (phase == 'receipt' && receipt != null) ...[
                  Text(
                    receipt!['state'] == 'succeeded'
                        ? t(
                            'حُفظت المسودة وإصدارها. لم تُفعل أسعار أو فوترة.',
                            'The draft and its revision were saved. No prices or billing were activated.',
                          )
                        : t(
                            'أُغلق المرجع بأمان. لا يلغي ذلك مسودة حُفظت سابقاً.',
                            'The reference is safely closed. This does not undo a previously saved draft.',
                          ),
                  ),
                  if (receipt!['entity'] is Map)
                    termsView(receipt!['entity']['terms'] as Map),
                  action(
                    'راجعت النتيجة النهائية',
                    'I reviewed the definitive outcome',
                    acknowledge,
                    primary: true,
                  ),
                ],
                if (phase == 'history') ...[
                  for (final row in history)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${t('الإصدار', 'Version')} ${digits('${row['version']}')} · ${date(row['created_at'], includeTime: true)}',
                            ),
                            Text(
                              '${t('سبب التعديل المسجل', 'Recorded change reason')}: ${row['reason']}',
                            ),
                            Text(label(row['after']['state'])),
                            termsView(row['after']['terms'] as Map),
                          ],
                        ),
                      ),
                    ),
                  if (historyMore && historyContract != null)
                    action(
                      'عرض إصدارات أقدم',
                      'Load older revisions',
                      () => showHistory({
                        'contract_id': historyContract,
                      }, append: true),
                    ),
                  action(
                    'العودة للمسودات',
                    'Back to drafts',
                    () => setState(() => phase = 'list'),
                  ),
                ],
              ],
            ),
    );
  }
}
