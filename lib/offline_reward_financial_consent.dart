import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
final _fingerprint = RegExp(r'^[0-9a-f]{64}$');
const offlineFinancialRules = {
  'pooling': {'policy_version', 'offer_branch'},
  'expiry': {'no_expiry', 'snapshot_offer_end'},
  'cancellation': {'restore_visits', 'forfeit_visits'},
  'refunded_contribution': {'offset_future_visits', 'freeze_for_owner_review'},
};

class OfflineFinancialReference {
  const OfflineFinancialReference(
    this.request,
    this.proposal, [
    this.withdrawal,
  ]);
  final String request, proposal;
  final String? withdrawal;
  List<String> get ids => [request, proposal, ?withdrawal];
  bool get valid => ids.every(_uuid.hasMatch);
}

abstract class OfflineFinancialStore {
  Future<OfflineFinancialReference?> read();
  Future<void> save(OfflineFinancialReference value);
}

abstract class OfflineFinancialRotationStore implements OfflineFinancialStore {
  Future<void> rotate(
    OfflineFinancialReference expected,
    OfflineFinancialReference replacement,
  );
  Future<List<OfflineFinancialReference>> history();
}

/// Receipt UUIDs only. Rotation is a local compare-and-swap, never financial
/// authority: the controller still requires a fresh server-confirmed revocation.
/// Per-request history keys preserve both receipts even if a pointer write loses
/// its response. Serialization covers store instances in this app isolate;
/// server nonce/ownership/unique-proposal checks remain authoritative elsewhere.
class SharedOfflineFinancialStore implements OfflineFinancialRotationStore {
  SharedOfflineFinancialStore(this.client)
    : actor = client.auth.currentUser?.id,
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? actor, token;
  static final _writes = <String, Future<void>>{};
  String get key {
    if (actor == null ||
        client.auth.currentUser?.id != actor ||
        token == null ||
        client.auth.currentSession?.accessToken != token ||
        client.auth.currentSession?.user.id != actor) {
      throw StateError('Session changed');
    }
    return 'offline_reward_financial_consent_uuid/$actor';
  }

  String get historyPrefix =>
      'offline_reward_financial_consent_history_uuid/$actor/';
  OfflineFinancialReference? decode(String? raw) {
    if (raw == null) return null;
    final ids = jsonDecode(raw);
    if (ids is! List ||
        ![2, 3].contains(ids.length) ||
        ids.any((v) => v is! String || !_uuid.hasMatch(v))) {
      throw StateError('Invalid saved reference');
    }
    return OfflineFinancialReference(
      ids[0],
      ids[1],
      ids.length == 3 ? ids[2] : null,
    );
  }

  bool same(OfflineFinancialReference? a, OfflineFinancialReference b) =>
      a != null && a.ids.join('/') == b.ids.join('/');
  bool extension(
    OfflineFinancialReference old,
    OfflineFinancialReference next,
  ) =>
      old.request == next.request &&
      old.proposal == next.proposal &&
      (old.withdrawal == null || old.withdrawal == next.withdrawal);
  Future<void> serialize(String k, Future<void> Function() write) async {
    final previous = _writes[k] ?? Future<void>.value();
    final done = Completer<void>();
    _writes[k] = done.future;
    try {
      await previous;
      if (key != k) throw StateError('Session changed');
      await write();
    } finally {
      done.complete();
      if (identical(_writes[k], done.future)) _writes.remove(k);
    }
  }

  Future<SharedPreferences> fresh(String k) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (key != k) throw StateError('Session changed');
    return prefs;
  }

  Future<void> archive(
    SharedPreferences prefs,
    String k,
    OfflineFinancialReference value,
  ) async {
    final h = '$historyPrefix${value.request}',
        old = decode(prefs.getString('$historyPrefix${value.request}'));
    if (old != null && !extension(old, value)) {
      throw StateError('History reference changed');
    }
    if (key != k || !await prefs.setString(h, jsonEncode(value.ids))) {
      throw StateError('History not retained');
    }
    if (key != k) throw StateError('Session changed');
  }

  @override
  Future<OfflineFinancialReference?> read() async {
    final k = key, prefs = await fresh(key);
    if (key != k) throw StateError('Session changed');
    return decode(prefs.getString(k));
  }

  @override
  Future<void> save(OfflineFinancialReference value) async {
    if (!value.valid) throw StateError('Invalid reference');
    final k = key;
    await serialize(k, () async {
      final prefs = await fresh(k);
      final old = decode(prefs.getString(k));
      if (old != null && !extension(old, value)) {
        throw StateError('Recover original consent');
      }
      if (prefs.containsKey('$historyPrefix${value.request}')) {
        await archive(prefs, k, value);
      }
      if (key != k || !await prefs.setString(k, jsonEncode(value.ids))) {
        throw StateError('Reference not saved');
      }
      if (key != k) throw StateError('Session changed');
    });
  }

  @override
  Future<void> rotate(
    OfflineFinancialReference expected,
    OfflineFinancialReference replacement,
  ) async {
    if (!expected.valid ||
        !replacement.valid ||
        expected.request == replacement.request ||
        expected.proposal == replacement.proposal) {
      throw StateError('A different proposal and consent are required');
    }
    final k = key;
    await serialize(k, () async {
      final prefs = await fresh(k);
      final current = decode(prefs.getString(k));
      if (!same(current, expected) && !same(current, replacement)) {
        throw StateError('Expected old reference changed');
      }
      await archive(prefs, k, expected);
      await archive(prefs, k, replacement);
      final checked = decode((await fresh(k)).getString(k));
      if (!same(checked, expected) && !same(checked, replacement)) {
        throw StateError('Expected old reference changed');
      }
      if (key != k || !await prefs.setString(k, jsonEncode(replacement.ids))) {
        throw StateError('Rotation not confirmed');
      }
      if (!same(decode((await fresh(k)).getString(k)), replacement)) {
        throw StateError('Rotation changed');
      }
    });
  }

  @override
  Future<List<OfflineFinancialReference>> history() async {
    final k = key, prefs = await fresh(key);
    final values = <OfflineFinancialReference>[];
    for (final name in prefs.getKeys().where(
      (name) => name.startsWith(historyPrefix),
    )) {
      final ref = decode(prefs.getString(name));
      if (ref == null || name != '$historyPrefix${ref.request}') {
        throw StateError('Invalid receipt history');
      }
      values.add(ref);
    }
    if (key != k) throw StateError('Session changed');
    return values;
  }
}

abstract class OfflineFinancialGateway {
  String? get actor;
  Future<Map<String, dynamic>> proposal(String? proposal);
  Future<Map<String, dynamic>> accept(
    String request,
    String proposal,
    String fingerprint,
    Map<String, dynamic> consent,
  );
  Future<Map<String, dynamic>> receipt(String request);
  Future<Map<String, dynamic>> revoke(String request, String consentRequest);
}

class SupabaseOfflineFinancialGateway implements OfflineFinancialGateway {
  SupabaseOfflineFinancialGateway(
    this.client, {
    this.timeout = const Duration(seconds: 30),
  }) : boundActor = client.auth.currentUser?.id,
       boundToken = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? boundActor, boundToken;
  final Duration timeout;
  @override
  String? get actor => client.auth.currentUser?.id;
  bool get current =>
      actor != null &&
      actor == boundActor &&
      boundToken != null &&
      client.auth.currentSession?.accessToken == boundToken &&
      client.auth.currentSession?.user.id == boundActor;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current) throw StateError('Session changed');
    final value = await client.rpc(name, params: params).timeout(timeout);
    if (!current) throw StateError('Session changed');
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> proposal(String? proposal) => call(
    'get_my_offline_reward_financial_proposal',
    {'p_proposal': proposal},
  );
  @override
  Future<Map<String, dynamic>> accept(
    String request,
    String proposal,
    String fingerprint,
    Map<String, dynamic> consent,
  ) => call('accept_my_offline_reward_financial_consent', {
    'p_request': request,
    'p_proposal': proposal,
    'p_fingerprint': fingerprint,
    'p_consent': consent,
  });
  @override
  Future<Map<String, dynamic>> receipt(String request) =>
      call('get_my_offline_reward_financial_consent', {'p_request': request});
  @override
  Future<Map<String, dynamic>> revoke(String request, String consentRequest) =>
      call('revoke_my_offline_reward_financial_consent', {
        'p_request': request,
        'p_consent_request': consentRequest,
      });
}

class OfflineFinancialConsentController extends ChangeNotifier {
  OfflineFinancialConsentController({
    required this.gateway,
    required this.store,
    this.proposalId,
    this.timeout = const Duration(seconds: 30),
  }) : actor = gateway.actor;
  final OfflineFinancialGateway gateway;
  final OfflineFinancialStore store;
  final String? actor, proposalId;
  final Duration timeout;
  OfflineFinancialReference? reference, _rotationOld, _previewOld;
  String? _rotatedProposal;
  Map<String, dynamic>? view, _acceptPayload;
  String phase = 'loading', error = '';
  bool busy = false, invalid = false, disposed = false;
  int epoch = 0, displayEpoch = 0;
  bool get current =>
      !disposed && !invalid && actor != null && gateway.actor == actor;
  bool get contextMatches =>
      reference == null ||
      phase == 'replacement_preview' ||
      (_rotatedProposal ?? proposalId) == null ||
      reference!.proposal == (_rotatedProposal ?? proposalId);
  String? get consentScope => view == null
      ? null
      : '$displayEpoch:${view!['proposal_id']}:${view!['fingerprint']}';
  bool get canConsent =>
      current &&
      !busy &&
      view != null &&
      ((reference == null && phase == 'proposal') ||
          (phase == 'replacement_preview' &&
              _previewOld != null &&
              reference?.ids.join('/') == _previewOld!.ids.join('/') &&
              store is OfflineFinancialRotationStore));
  bool get canPreviewReplacement =>
      current &&
      !busy &&
      phase == 'revoked' &&
      reference != null &&
      store is OfflineFinancialRotationStore;
  bool get canRetry =>
      current &&
      !busy &&
      phase == 'uncertain' &&
      reference?.withdrawal == null &&
      _acceptPayload != null;
  bool get canWithdraw =>
      current &&
      !busy &&
      reference != null &&
      !['revoked', 'already_issued', 'replacement_preview'].contains(phase);
  bool owns(int e) => current && e == epoch;
  void changed() {
    if (!disposed) notifyListeners();
  }

  void clearDisplay() {
    displayEpoch++;
    view = null;
  }

  void invalidate() {
    epoch++;
    invalid = true;
    busy = false;
    clearDisplay();
    reference = null;
    _acceptPayload = null;
    _rotationOld = _previewOld = null;
    phase = 'invalid';
    error = 'identity';
    changed();
  }

  Future<T> wait<T>(Future<T> value) => value.timeout(timeout);
  Future<void> run(Future<void> Function(int) work) async {
    if (!current || busy) return;
    final e = epoch;
    busy = true;
    error = '';
    changed();
    try {
      await work(e);
    } catch (_) {
      if (owns(e)) {
        clearDisplay();
        error = 'unconfirmed';
      }
    } finally {
      if (owns(e)) {
        busy = false;
        changed();
      }
    }
  }

  Map<String, dynamic> validateProposal(
    Map<String, dynamic> data, {
    String? expected,
  }) {
    if (data['issuer_enabled'] != false ||
        data['redemption_enabled'] != false ||
        !['proposal', 'inactive', 'issued'].contains(data['state']) ||
        !_uuid.hasMatch(data['proposal_id'] as String? ?? '') ||
        (expected != null && data['proposal_id'] != expected) ||
        !_fingerprint.hasMatch(data['fingerprint'] as String? ?? '')) {
      throw StateError('Unverified proposal');
    }
    final terms = Map<String, dynamic>.from(data['terms'] as Map);
    final gross = terms['gross_amount'],
        discount = terms['reward_discount'],
        due = terms['amount_due'],
        visits = terms['visits'];
    if (terms['currency'] != 'EGP' ||
        terms['unit'] != 'service_visits' ||
        gross is! num ||
        !gross.isFinite ||
        gross <= 0 ||
        discount is! num ||
        !discount.isFinite ||
        discount != gross ||
        due is! num ||
        due != 0 ||
        visits is! num ||
        !visits.isFinite ||
        visits <= 0 ||
        visits != visits.roundToDouble() ||
        DateTime.tryParse(terms['expires_at'] as String? ?? '') == null) {
      throw StateError('Unverified amounts or unit');
    }
    for (final field in ['service', 'branch']) {
      final names = terms[field];
      if (names is! Map ||
          ![
            names['name_ar'],
            names['name_en'],
          ].any((v) => v is String && v.trim().isNotEmpty)) {
        throw StateError('Missing actual names');
      }
    }
    final rules = Map<String, dynamic>.from(terms['rules'] as Map);
    if (rules.length != offlineFinancialRules.length ||
        offlineFinancialRules.entries.any(
          (entry) => !entry.value.contains(rules[entry.key]),
        )) {
      throw StateError('Unsupported frozen rules');
    }
    if (data['state'] == 'issued') {
      if (data['reward_issued'] != true) {
        throw StateError('Unverified issue state');
      }
    } else {
      if (data['reward_issued'] != false) {
        throw StateError('Unverified preparation state');
      }
      final consent = data['consent'];
      if (consent is! Map ||
          consent['version'] != 'offline-reward-financial-v1' ||
          ['notice_ar', 'notice_en'].any(
            (key) =>
                consent[key] is! String || (consent[key] as String).isEmpty,
          )) {
        throw StateError('Missing exact notice');
      }
    }
    return {
      'state': data['state'],
      'proposal_id': data['proposal_id'],
      'fingerprint': data['fingerprint'],
      'terms': terms,
      if (data['consent'] is Map)
        'consent': Map<String, dynamic>.from(data['consent'] as Map),
    };
  }

  void applyProposal(Map<String, dynamic> data, {String? expected}) {
    clearDisplay();
    if (data['state'] == 'unavailable') {
      if (data['issuer_enabled'] != false ||
          data['redemption_enabled'] != false) {
        throw StateError('Unknown capabilities');
      }
      phase = 'unavailable';
      return;
    }
    final checked = validateProposal(data, expected: expected);
    phase = checked['state'] as String;
    if (contextMatches) view = checked;
  }

  void applyReceipt(Map<String, dynamic> data) {
    clearDisplay();
    final ref = reference!;
    if (data['request_id'] != ref.request || data['issuer_enabled'] != false) {
      throw StateError('Receipt mismatch');
    }
    final state = data['state'];
    if (state == 'absent') {
      if (data['definitive_failure'] != false) {
        throw StateError('Unverified absence');
      }
      phase = ref.withdrawal == null ? 'uncertain' : 'withdrawal_pending';
      return;
    }
    if (state == 'revoked') {
      if (data['definitive_failure'] != true) {
        throw StateError('Unverified revocation');
      }
      phase = 'revoked';
      _acceptPayload = null;
      return;
    }
    if (state == 'already_issued') {
      if (ref.withdrawal == null ||
          data['revoke_request_id'] != ref.withdrawal ||
          data['withdrawal_applied'] != false ||
          data['reward_issued'] != true) {
        throw StateError('Unverified issued withdrawal');
      }
      phase = 'already_issued';
      _acceptPayload = null;
      return;
    }
    if (!['consent_recorded', 'inactive', 'issued'].contains(state) ||
        data['proposal_id'] != ref.proposal ||
        data['redemption_enabled'] != false ||
        !_fingerprint.hasMatch(data['fingerprint'] as String? ?? '')) {
      throw StateError('Unverified consent result');
    }
    final checked = validateProposal(
      Map<String, dynamic>.from(data['proposal'] as Map),
      expected: ref.proposal,
    );
    final consent = Map<String, dynamic>.from(data['consent'] as Map);
    if (consent.length != 4 ||
        consent['accepted'] != true ||
        consent['version'] != 'offline-reward-financial-v1' ||
        !['ar', 'en'].contains(consent['language']) ||
        consent['text'] is! String ||
        (consent['text'] as String).isEmpty ||
        data['fingerprint'] != checked['fingerprint']) {
      throw StateError('Unverified frozen receipt');
    }
    if ((state == 'consent_recorded' && checked['state'] != 'proposal') ||
        (state == 'inactive' && checked['state'] != 'inactive')) {
      throw StateError('Changed proposal status');
    }
    if (_acceptPayload != null &&
        (data['fingerprint'] != _acceptPayload!['fingerprint'] ||
            ['accepted', 'version', 'language', 'text'].any(
              (key) => consent[key] != (_acceptPayload!['consent'] as Map)[key],
            ))) {
      throw StateError('Changed accepted terms');
    }
    if (checked['state'] != 'issued' &&
        consent['text'] !=
            (checked['consent'] as Map)['notice_${consent['language']}']) {
      throw StateError('Changed notice');
    }
    if (state == 'issued'
        ? (data['reward_issued'] != true || checked['state'] != 'issued')
        : data['reward_issued'] != false) {
      throw StateError('Unverified issue receipt');
    }
    phase = state == 'issued'
        ? 'issued'
        : ref.withdrawal != null
        ? 'withdrawal_pending'
        : state as String;
    _acceptPayload = null;
    if (contextMatches) view = checked;
  }

  Future<void> previewReplacement() async {
    if (!canPreviewReplacement) return;
    await run((e) async {
      final old = reference!;
      clearDisplay();
      _previewOld = null;
      final prior = await wait(gateway.receipt(old.request));
      if (!owns(e)) return;
      applyReceipt(prior);
      if (phase != 'revoked') return;
      final latest = await wait(gateway.proposal(null));
      if (!owns(e)) return;
      if (latest['state'] != 'proposal' ||
          latest['proposal_id'] == old.proposal) {
        clearDisplay();
        error = 'no_new_proposal';
        return;
      }
      final checked = validateProposal(latest);
      clearDisplay();
      _previewOld = old;
      view = checked;
      phase = 'replacement_preview';
    });
  }

  Future<void> commitRotation(int e) async {
    final old = _rotationOld;
    if (old == null) return;
    final rotator = store;
    if (rotator is! OfflineFinancialRotationStore) {
      throw StateError('Rotation store required');
    }
    await rotator.rotate(old, reference!);
    if (!owns(e)) return;
    _rotatedProposal = reference!.proposal;
    _rotationOld = null;
  }

  Future<void> refresh() => run((e) async {
    clearDisplay();
    _previewOld = null;
    final saved = await store.read();
    if (!owns(e)) return;
    if (saved != null &&
        (!saved.valid ||
            (reference != null &&
                (saved.request != reference!.request ||
                    saved.proposal != reference!.proposal ||
                    (reference!.withdrawal != null &&
                        saved.withdrawal != reference!.withdrawal)) &&
                (_rotationOld == null ||
                    saved.ids.join('/') != _rotationOld!.ids.join('/'))))) {
      throw StateError('Saved consent changed');
    }
    if (_rotationOld == null) reference = saved ?? reference;
    if (reference != null) {
      phase = reference!.withdrawal == null
          ? 'uncertain'
          : 'withdrawal_pending';
      final data = await wait(gateway.receipt(reference!.request));
      if (owns(e)) applyReceipt(data);
    } else {
      final data = await wait(gateway.proposal(proposalId));
      if (owns(e)) applyProposal(data, expected: proposalId);
    }
  });
  Future<void> consent(
    String language, {
    required bool accepted,
    required String? scope,
  }) async {
    if (!canConsent ||
        !accepted ||
        scope != consentScope ||
        !['ar', 'en'].contains(language)) {
      return;
    }
    await run((e) async {
      final captured = view!;
      _rotationOld = _previewOld;
      _previewOld = null;
      reference = OfflineFinancialReference(
        newOrderRequestId(),
        captured['proposal_id'] as String,
      );
      _acceptPayload = Map.unmodifiable({
        'proposal': captured['proposal_id'],
        'fingerprint': captured['fingerprint'],
        'consent': Map<String, dynamic>.unmodifiable({
          'accepted': true,
          'version': (captured['consent'] as Map)['version'],
          'language': language,
          'text': (captured['consent'] as Map)['notice_$language'],
        }),
      });
      phase = 'uncertain';
      clearDisplay();
      await dispatch(e);
    });
  }

  Future<void> dispatch(int e) async {
    await commitRotation(e);
    if (!owns(e)) return;
    await store.save(reference!);
    if (!owns(e)) return;
    final data = await wait(
      gateway.accept(
        reference!.request,
        _acceptPayload!['proposal'] as String,
        _acceptPayload!['fingerprint'] as String,
        Map<String, dynamic>.from(_acceptPayload!['consent'] as Map),
      ),
    );
    if (owns(e)) applyReceipt(data);
  }

  Future<void> retry() async {
    if (canRetry) await run(dispatch);
  }

  Future<void> withdraw() async {
    if (!canWithdraw) return;
    await run((e) async {
      _acceptPayload = null;
      await commitRotation(e);
      if (!owns(e)) return;
      final old = reference!;
      reference = OfflineFinancialReference(
        old.request,
        old.proposal,
        old.withdrawal ?? newOrderRequestId(),
      );
      _acceptPayload = null;
      phase = 'withdrawal_pending';
      clearDisplay();
      await store.save(reference!);
      if (!owns(e)) return;
      final data = await wait(
        gateway.revoke(reference!.withdrawal!, reference!.request),
      );
      if (owns(e)) applyReceipt(data);
    });
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    view = _acceptPayload = null;
    super.dispose();
  }
}

/// Isolated preparatory component: intentionally has no issuer/payment API and
/// is not wired to any production reward route by this source addition.
class OfflineRewardFinancialConsentPanel extends StatefulWidget {
  const OfflineRewardFinancialConsentPanel({
    super.key,
    required this.client,
    this.proposalId,
    this.scopeKey,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final String? proposalId;

  /// Host context invalidation only; never sent as authorization or RPC input.
  final Object? scopeKey;
  final OfflineFinancialGateway? gateway;
  final OfflineFinancialStore? store;
  @override
  State<OfflineRewardFinancialConsentPanel> createState() =>
      _OfflineRewardFinancialConsentPanelState();
}

class _OfflineRewardFinancialConsentPanelState
    extends State<OfflineRewardFinancialConsentPanel> {
  late final OfflineFinancialConsentController c;
  StreamSubscription<AuthState>? auth;
  String? acceptedScope;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  bool get arabic => Localizations.localeOf(context).languageCode == 'ar';
  @override
  void initState() {
    super.initState();
    c = OfflineFinancialConsentController(
      gateway: widget.gateway ?? SupabaseOfflineFinancialGateway(widget.client),
      store: widget.store ?? SharedOfflineFinancialStore(widget.client),
      proposalId: widget.proposalId,
    );
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      acceptedScope = null;
      c.invalidate();
    });
    unawaited(c.refresh());
  }

  @override
  void didUpdateWidget(covariant OfflineRewardFinancialConsentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.proposalId != widget.proposalId ||
        oldWidget.scopeKey != widget.scopeKey ||
        oldWidget.gateway != widget.gateway ||
        oldWidget.store != widget.store) {
      acceptedScope = null;
      c.invalidate();
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    c.dispose();
    super.dispose();
  }

  String digits(String value) => arabic
      ? value
            .replaceAllMapped(
              RegExp('[0-9]'),
              (m) => '٠١٢٣٤٥٦٧٨٩'[int.parse(m[0]!)],
            )
            .replaceAll('.', '٫')
      : value;
  String money(num value) => arabic
      ? '${digits(value.toStringAsFixed(2))} جنيه مصري'
      : 'EGP ${value.toStringAsFixed(2)}';
  String date(String value) {
    final stamp = DateTime.parse(value).toLocal(),
        labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(stamp)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(stamp))}';
  }

  String name(Map value) {
    final own = value[arabic ? 'name_ar' : 'name_en'];
    if (own is String && own.trim().isNotEmpty) return own;
    return '${value[arabic ? 'name_en' : 'name_ar']} · ${t('الاسم بالعربية غير متاح', 'English name unavailable')}';
  }

  String rule(String key, dynamic value) => switch ('$key:$value') {
    'pooling:policy_version' => t(
      'زيارات هذا الإصدار من البرنامج فقط.',
      'Visits from this policy version only.',
    ),
    'pooling:offer_branch' => t(
      'زيارات البرنامج نفسه في الفرع نفسه.',
      'Visits from the same program and branch.',
    ),
    'expiry:no_expiry' => t(
      'لا انتهاء إضافي؛ تبقى صلاحية كل زيارة الأصلية محفوظة.',
      'No additional expiry; each visit retains its original expiry.',
    ),
    'expiry:snapshot_offer_end' => t(
      'نهاية العرض المثبتة، دون تمديد صلاحية الزيارات الأصلية.',
      'Frozen offer-end expiry; original visit expiries are not extended.',
    ),
    'cancellation:restore_visits' => t(
      'تُعاد الزيارات عند الإلغاء وفق القاعدة المثبتة.',
      'Visits are restored on cancellation under the frozen rule.',
    ),
    'cancellation:forfeit_visits' => t(
      'لا تُعاد الزيارات عند الإلغاء.',
      'Visits are forfeited on cancellation.',
    ),
    'refunded_contribution:offset_future_visits' => t(
      'رد مساهمة يخصم من أهلية الزيارات المقبلة؛ لا مطالبة نقدية رجعية.',
      'A refunded contribution offsets future visit eligibility; no retroactive cash charge.',
    ),
    'refunded_contribution:freeze_for_owner_review' => t(
      'رد مساهمة يوقف الاستبدال المقبل لمراجعة المالك؛ لا تحويل تلقائي إلى دين نقدي.',
      'A refunded contribution freezes future redemption for owner review; no automatic cash debt.',
    ),
    _ => '',
  };
  Widget identified(String id, Widget child) =>
      Semantics(identifier: id, child: child);
  String status() => switch (c.phase) {
    'replacement_preview' => t(
      'مراجعة مقترح جديد بعد سحب الموافقة السابقة؛ يلزم اختيار الموافقة المالية من جديد.',
      'Previewing a new proposal after withdrawal; separate financial consent must be chosen again.',
    ),
    'consent_recorded' => t(
      'سُجلت الموافقة المالية. تسجيلها وحده لا يصدر مكافأة ولا يحصّل مبلغاً.',
      'Financial consent recorded. Recording consent alone does not issue a reward or collect money.',
    ),
    'inactive' => t(
      'المقترح أو الموافقة غير نشطين. تحقق من الحالة قبل أي متابعة.',
      'The proposal or consent is inactive. Check its status before continuing.',
    ),
    'uncertain' => t(
      'النتيجة غير مؤكدة. تحقق بالمرجع المحفوظ نفسه أو اسحب الموافقة بأمان؛ لا تبدأ محاولة بديلة.',
      'The outcome is unconfirmed. Recover the same saved reference or safely withdraw consent; do not start a replacement attempt.',
    ),
    'withdrawal_pending' => t(
      'لم يتأكد سحب الموافقة. تحقق أو أعد السحب بالمرجع نفسه.',
      'Withdrawal is unconfirmed. Check or retry withdrawal using the same reference.',
    ),
    'revoked' => t(
      'سُحبت الموافقة أو أُغلق مرجعها بأمان. لا يمكن إعادة استخدام هذه الموافقة.',
      'Consent was withdrawn or its reference safely closed. This consent cannot be reused.',
    ),
    'issued' => t(
      'أفاد إيصال الخادم بإصدار المكافأة. لا تمنح هذه الحالة حق إصدار آخر أو استعادة الموافقة.',
      'The server receipt reports a reward was issued. This does not authorize reissue or restore the consent.',
    ),
    'already_issued' => t(
      'لم يُطبق السحب لأن المكافأة صدرت بالفعل. الفاتورة المصدرة لم تتغير؛ هذا الإجراء لا يلغيها ولا يرد قيمتها ولا يعيد الإصدار.',
      'Withdrawal was not applied because the reward was already issued. The issued invoice is unchanged; this action does not cancel, refund or reissue it.',
    ),
    'unavailable' => t(
      'لا يوجد مقترح متاح لهذا الحساب والنطاق الحالي.',
      'No proposal is available for this account and current scope.',
    ),
    _ => '',
  };
  Future<void> refresh() async {
    setState(() => acceptedScope = null);
    await c.refresh();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final view = c.view,
          terms = view?['terms'] as Map?,
          rules = terms?['rules'] as Map?;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t(
                  'موافقة مالية منفصلة على مكافأة زيارات الاستقبال',
                  'Separate financial consent for a reception visits reward',
                ),
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: const Color(0xff071a36)),
              ),
              const SizedBox(height: 12),
              identified(
                'offline-financial-preparatory',
                Text(
                  t(
                    'واجهة تحضيرية: لا تتضمن إجراء إصدار أو استبدال. تسجيل الموافقة ليس تحصيلاً مالياً ولا إصداراً تلقائياً.',
                    'Preparatory interface: issuing and redemption actions are unavailable. Recording consent does not collect money or automatically issue a reward.',
                  ),
                ),
              ),
              if (c.busy) const LinearProgressIndicator(),
              if (c.error.isNotEmpty)
                Text(
                  c.invalid
                      ? t(
                          'تغيرت الجلسة أو نطاق المقترح. أعد فتحه بالحساب الصحيح.',
                          'The session or proposal scope changed. Reopen with the correct account.',
                        )
                      : t(
                          'تعذر تأكيد النتيجة. احتفظ بالمرجع المحفوظ وتحقق مجدداً.',
                          'The outcome could not be confirmed. Keep the saved reference and check again.',
                        ),
                ),
              if (!c.contextMatches)
                Text(
                  t(
                    'يوجد مرجع موافقة سابق لمقترح آخر. لا نبدله بهذا المقترح؛ تحقّق منه أو اسحبه أولاً.',
                    'A saved consent belongs to another proposal. It is not replaced with this proposal; recover or withdraw it first.',
                  ),
                ),
              if (terms != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${t('الخدمة', 'Service')}: ${name(terms['service'] as Map)}',
                ),
                Text(
                  '${t('الفرع', 'Branch')}: ${name(terms['branch'] as Map)}',
                ),
                Text(
                  '${t('الزيارات المستخدمة (ليست نقاطاً)', 'Visits used (not points)')}: ${digits('${terms['visits']}')}',
                ),
                Text(
                  '${t('السعر الأصلي', 'Original price')}: ${money(terms['gross_amount'] as num)}',
                ),
                Text(
                  '${t('خصم المكافأة', 'Reward discount')}: ${money(terms['reward_discount'] as num)}',
                ),
                identified(
                  'offline-financial-amount-due',
                  Text(
                    '${t('المستحق النهائي', 'Final customer charge')}: ${money(terms['amount_due'] as num)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${t('انتهاء المقترح (توقيت جهازك)', 'Proposal expires (your device time)')}: ${date(terms['expires_at'] as String)}',
                ),
                for (final key in offlineFinancialRules.keys)
                  Text(rule(key, rules![key])),
              ],
              if (status().isNotEmpty)
                identified(
                  'offline-financial-status',
                  Text(
                    status(),
                    key: const ValueKey('offline-financial-status'),
                  ),
                ),
              if (c.canConsent) ...[
                const SizedBox(height: 12),
                identified(
                  'offline-financial-exact-notice',
                  Text(
                    (view!['consent'] as Map)[arabic
                            ? 'notice_ar'
                            : 'notice_en']
                        as String,
                    key: const ValueKey('offline-financial-exact-notice'),
                  ),
                ),
                identified(
                  'offline-financial-checkbox',
                  CheckboxListTile(
                    key: const ValueKey('offline-financial-checkbox'),
                    contentPadding: EdgeInsets.zero,
                    value:
                        acceptedScope != null &&
                        acceptedScope == c.consentScope,
                    onChanged: (value) => setState(
                      () =>
                          acceptedScope = value == true ? c.consentScope : null,
                    ),
                    title: Text(
                      t(
                        'أوافق مالياً على هذا المقترح بهذه الشروط فقط',
                        'I give separate financial consent to this proposal and these terms only',
                      ),
                    ),
                  ),
                ),
                identified(
                  'offline-financial-record',
                  FilledButton(
                    key: const ValueKey('offline-financial-record'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xff174b83),
                    ),
                    onPressed:
                        acceptedScope != null && acceptedScope == c.consentScope
                        ? () => c.consent(
                            arabic ? 'ar' : 'en',
                            accepted: true,
                            scope: acceptedScope,
                          )
                        : null,
                    child: Text(
                      t(
                        'تسجيل موافقتي المالية لهذا المقترح فقط',
                        'Record financial consent for this proposal only',
                      ),
                    ),
                  ),
                ),
              ],
              if (c.canPreviewReplacement)
                OutlinedButton(
                  key: const ValueKey('offline-financial-preview-new'),
                  onPressed: () async {
                    setState(() => acceptedScope = null);
                    await c.previewReplacement();
                  },
                  child: Text(
                    t(
                      'مراجعة مقترح جديد بعد سحب الموافقة',
                      'Preview a new proposal after withdrawal',
                    ),
                  ),
                ),
              if (c.canRetry)
                OutlinedButton(
                  key: const ValueKey('offline-financial-retry'),
                  onPressed: c.retry,
                  child: Text(
                    t('إعادة إرسال الموافقة نفسها', 'Retry the exact consent'),
                  ),
                ),
              if (c.canWithdraw)
                OutlinedButton(
                  key: const ValueKey('offline-financial-withdraw'),
                  onPressed: c.withdraw,
                  child: Text(
                    t(
                      'سحب الموافقة أو إغلاق المحاولة بأمان',
                      'Withdraw consent or safely close this attempt',
                    ),
                  ),
                ),
              OutlinedButton(
                key: const ValueKey('offline-financial-refresh'),
                onPressed: c.current && !c.busy ? refresh : null,
                child: Text(
                  t(
                    'تحديث المقترح وإيصال الموافقة',
                    'Refresh proposal and consent receipt',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
