import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'offline_customer_claim.dart'
    show OfflineClaimGateway, SupabaseOfflineClaimGateway;
import 'workflow.dart' show newOrderRequestId;

const recoveryEvidenceTypes = {
  'in_person_original_service_documents',
  'in_person_independent_continuity_witness',
};
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

class OwnerProposalReference {
  const OwnerProposalReference(
    this.proposal,
    this.caseId,
    this.query,
    this.profile,
  );
  final String proposal, caseId, query, profile;
  List<String> get values => [proposal, caseId, query, profile];
  bool get valid => values.every(_uuid.hasMatch);
}

abstract class OwnerProposalStore {
  Future<OwnerProposalReference?> read();
  Future<void> save(OwnerProposalReference value);
  Future<void> clear(OwnerProposalReference value);
}

class SharedOwnerProposalStore implements OwnerProposalStore {
  SharedOwnerProposalStore(this.client, this.caseId)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String caseId;
  final String? actor;
  String get key {
    if (actor == null ||
        client.auth.currentUser?.id != actor ||
        !_uuid.hasMatch(caseId)) {
      throw StateError('Session or case changed');
    }
    return 'owner_visit_recovery_proposal_uuid/$actor/$caseId';
  }

  @override
  Future<OwnerProposalReference?> read() async {
    final k = key, prefs = await SharedPreferences.getInstance();
    if (key != k) throw StateError('Session changed');
    final raw = prefs.getString(k);
    if (raw == null) return null;
    final ids = jsonDecode(raw);
    if (ids is! List ||
        ids.length != 4 ||
        ids.any((v) => v is! String || !_uuid.hasMatch(v))) {
      throw StateError('Invalid saved reference');
    }
    final ref = OwnerProposalReference(ids[0], ids[1], ids[2], ids[3]);
    if (ref.caseId != caseId) throw StateError('Case changed');
    return ref;
  }

  @override
  Future<void> save(OwnerProposalReference value) async {
    if (!value.valid || value.caseId != caseId) {
      throw StateError('Invalid reference');
    }
    final k = key, old = await read();
    if (old != null && old.values.join('/') != value.values.join('/')) {
      throw StateError('Recover original proposal');
    }
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.setString(k, jsonEncode(value.values))) {
      throw StateError('Reference not saved');
    }
    if (key != k) throw StateError('Session changed');
  }

  @override
  Future<void> clear(OwnerProposalReference value) async {
    final k = key, old = await read();
    if (old == null || old.values.join('/') != value.values.join('/')) {
      throw StateError('Saved reference changed');
    }
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.remove(k)) {
      throw StateError('Reference not cleared');
    }
  }
}

class OwnerRecoveryProposalController extends ChangeNotifier {
  OwnerRecoveryProposalController({
    required this.gateway,
    required this.store,
    required this.actorId,
    required this.caseId,
    required this.query,
    required this.profile,
    required this.plate,
    this.rpcTimeout = const Duration(seconds: 30),
  }) : actor = actorId();
  final OfflineClaimGateway gateway;
  final Duration rpcTimeout;
  final OwnerProposalStore store;
  final String? Function() actorId;
  final String? actor, plate;
  final String caseId, query, profile;
  OwnerProposalReference? reference;
  Map<String, dynamic>? receipt, _payload;
  String phase = 'loading', error = '';
  bool busy = false, invalid = false, disposed = false;
  int epoch = 0;
  bool get current =>
      !disposed && !invalid && actor != null && actorId() == actor;
  bool get contextMatches =>
      reference == null ||
      (reference!.caseId == caseId &&
          reference!.query == query &&
          reference!.profile == profile);
  bool get canPrepare =>
      current && !busy && phase == 'ready' && reference == null;
  bool get canRetry =>
      current &&
      !busy &&
      phase == 'uncertain' &&
      reference != null &&
      _payload != null &&
      contextMatches;
  bool get canClose =>
      current &&
      !busy &&
      reference != null &&
      !['accepted', 'review_required', 'closed'].contains(phase);
  bool get canAcknowledge =>
      current &&
      !busy &&
      reference != null &&
      ['accepted', 'review_required', 'closed'].contains(phase);
  bool owns(int e) => current && e == epoch;
  void changed() {
    if (!disposed) notifyListeners();
  }

  void invalidate() {
    epoch++;
    invalid = true;
    busy = false;
    receipt = _payload = null;
    reference = null;
    phase = 'invalid';
    error = 'identity';
    changed();
  }

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

  Future<dynamic> rpc(String name, Map<String, dynamic> params) =>
      gateway.rpc(name, params).timeout(rpcTimeout);

  void apply(dynamic raw) {
    final data = Map<String, dynamic>.from(raw as Map), ref = reference!;
    if (data['proposal_id'] != ref.proposal) {
      throw StateError('Proposal mismatch');
    }
    final state = data['state'];
    if (![
      'open',
      'accepted',
      'review_required',
      'expired',
      'unavailable',
      'absent',
      'closed',
    ].contains(state)) {
      throw StateError('Unknown proposal state');
    }
    if (!['absent', 'closed'].contains(state)) {
      if (data['case_id'] != ref.caseId ||
          data['query_id'] != ref.query ||
          data['profile_reference'] != ref.profile ||
          data['link_created'] != false) {
        throw StateError('Context mismatch');
      }
    } else if (state == 'closed' &&
        data['case_id'] != null &&
        (data['case_id'] != ref.caseId ||
            data['query_id'] != ref.query ||
            data['profile_reference'] != ref.profile ||
            data['link_created'] != false)) {
      throw StateError('Closed proposal mismatch');
    }
    phase = state == 'absent' ? 'uncertain' : state as String;
    receipt = {
      'state': state,
      'expires_at': data['expires_at'],
      'link_created': false,
      if (contextMatches) 'evidence_type': data['evidence_type'],
      if (contextMatches) 'private_reason': data['private_reason'],
    };
  }

  Future<void> refresh() => run((e) async {
    final saved = await store.read();
    if (!owns(e)) return;
    if (saved != null &&
        (!saved.valid ||
            saved.caseId != caseId ||
            (reference != null &&
                saved.values.join('/') != reference!.values.join('/')))) {
      throw StateError('Saved reference changed');
    }
    reference = saved ?? reference;
    if (reference == null) {
      phase = 'ready';
      receipt = null;
      return;
    }
    phase = 'uncertain';
    final value = await rpc('get_visit_recovery_proposal', {
      'p_proposal': reference!.proposal,
    });
    if (owns(e)) apply(value);
  });
  Future<void> prepare(String? evidence, String reason, bool attested) async {
    if (!canPrepare ||
        !recoveryEvidenceTypes.contains(evidence) ||
        reason.trim().length < 10 ||
        reason.trim().length > 500 ||
        !attested) {
      return;
    }
    await run((e) async {
      reference = OwnerProposalReference(
        newOrderRequestId(),
        caseId,
        query,
        profile,
      );
      _payload = Map.unmodifiable({
        'p_proposal': reference!.proposal,
        'p_query': query,
        'p_profile': profile,
        'p_evidence_type': evidence,
        'p_reason': reason.trim(),
        'p_attested': true,
        'p_plate': plate,
      });
      phase = 'uncertain';
      await dispatch(e);
    });
  }

  Future<void> dispatch(int e) async {
    await store.save(reference!);
    if (!owns(e)) return;
    final value = await rpc(
      'prepare_visit_recovery_proposal',
      Map.of(_payload!),
    );
    if (owns(e)) apply(value);
  }

  Future<void> retry() async {
    if (canRetry) await run(dispatch);
  }

  Future<void> close() async {
    if (!canClose) return;
    await run((e) async {
      await store.save(reference!);
      if (!owns(e)) return;
      final value = await rpc('close_visit_recovery_proposal', {
        'p_proposal': reference!.proposal,
      });
      if (owns(e)) apply(value);
    });
  }

  Future<void> acknowledge() async {
    if (!canAcknowledge) return;
    await run((e) async {
      await store.clear(reference!);
      if (!owns(e)) return;
      reference = null;
      receipt = _payload = null;
      // Do not silently prepare another proposal after reading this receipt.
      phase = 'acknowledged';
    });
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    receipt = _payload = null;
    super.dispose();
  }
}

class OwnerRecoveryProposalScreen extends StatefulWidget {
  const OwnerRecoveryProposalScreen({
    super.key,
    required this.client,
    required this.caseId,
    required this.query,
    required this.profile,
    required this.plate,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final String caseId, query, profile;
  final String? plate;
  final OfflineClaimGateway? gateway;
  final OwnerProposalStore? store;
  @override
  State<OwnerRecoveryProposalScreen> createState() =>
      _OwnerRecoveryProposalScreenState();
}

class _OwnerRecoveryProposalScreenState
    extends State<OwnerRecoveryProposalScreen> {
  late final OwnerRecoveryProposalController c;
  final reason = TextEditingController();
  final evidenceField = GlobalKey<FormFieldState<String>>();
  String? evidence;
  bool attested = false;
  StreamSubscription<AuthState>? auth;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    c = OwnerRecoveryProposalController(
      gateway: widget.gateway ?? SupabaseOfflineClaimGateway(widget.client),
      store:
          widget.store ??
          SharedOwnerProposalStore(widget.client, widget.caseId),
      actorId: () => widget.client.auth.currentUser?.id,
      caseId: widget.caseId,
      query: widget.query,
      profile: widget.profile,
      plate: widget.plate,
    );
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      clearPrivate();
      c.invalidate();
    });
    unawaited(c.refresh());
  }

  void clearPrivate() {
    reason.clear();
    evidence = null;
    attested = false;
    evidenceField.currentState?.didChange(null);
  }

  @override
  void didUpdateWidget(covariant OwnerRecoveryProposalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.caseId != widget.caseId ||
        oldWidget.query != widget.query ||
        oldWidget.profile != widget.profile ||
        oldWidget.plate != widget.plate) {
      clearPrivate();
      c.invalidate();
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    reason.dispose();
    c.dispose();
    super.dispose();
  }

  String evidenceLabel(String? type) =>
      type == 'in_person_original_service_documents'
      ? t(
          'مستندات الخدمة الأصلية بحضور العميل',
          'Original service documents presented in person',
        )
      : type == 'in_person_independent_continuity_witness'
      ? t(
          'شهادة مستقلة باستمرارية الهوية بحضور العميل',
          'Independent continuity witness in person',
        )
      : t('غير متاح', 'Unavailable');
  String stateLabel() => switch (c.phase) {
    'open' => t(
      'اقتراح محفوظ بانتظار موافقة العميل',
      'Proposal saved; awaiting customer consent',
    ),
    'accepted' => t(
      'سُجلت موافقة العميل؛ تابع قرار المراجعة النهائية لدى المالك',
      'Customer consent recorded; follow the final owner review decision',
    ),
    'review_required' => t(
      'تحتاج الحالة إلى مراجعة مستقلة إضافية',
      'Further independent review is required',
    ),
    'closed' => t('مرجع الاقتراح مغلق', 'Proposal reference closed'),
    'expired' => t(
      'انتهت صلاحية الاقتراح؛ أغلق المرجع قبل المتابعة',
      'Proposal expired; close the reference before continuing',
    ),
    'unavailable' => t(
      'الاقتراح غير متاح؛ تحقق أو أغلق المرجع بأمان',
      'Proposal unavailable; check or safely close its reference',
    ),
    'uncertain' => t(
      'النتيجة غير محسومة؛ لا تبدأ اقتراحاً بديلاً',
      'Outcome unresolved; do not create a replacement proposal',
    ),
    'acknowledged' => t(
      'تمت مراجعة النتيجة. يمكنك العودة إلى الطلب.',
      'Outcome reviewed. You can return to the case.',
    ),
    _ => '',
  };
  Widget identified(String id, Widget child) =>
      Semantics(identifier: id, child: child);
  String expiry(dynamic value) {
    final stamp = DateTime.tryParse(value?.toString() ?? '');
    if (stamp == null) return t('غير متاح', 'Unavailable');
    final labels = MaterialLocalizations.of(context), local = stamp.toLocal();
    return '${labels.formatFullDate(local)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(
        t(
          'اقتراح سجل للتحقق المستقل',
          'Propose a record for independent verification',
        ),
      ),
    ),
    body: AnimatedBuilder(
      animation: c,
      builder: (_, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          identified(
            'owner-proposal-safety',
            Text(
              t(
                'هذا مسار منفصل عن نتائج البحث. تطابق الهاتف أو اللوحة لا يثبت الهوية. يلزم دليل مستقل فعلي وموافقة العميل ثم مراجعة المالك النهائية؛ لا يُنشأ ربط هنا.',
                'This is separate from search results. Phone or plate matching is not identity proof. Actual independent evidence, customer consent and final owner review are required; this step creates no link.',
              ),
            ),
          ),
          if (!c.contextMatches)
            Text(
              t(
                'يوجد مرجع محفوظ لسجل أو بحث سابق في هذا الطلب. استعد نتيجته أو أغلقه بأمان؛ لا نعتمد السجل الحالي بديلاً.',
                'A saved reference belongs to another investigation or record in this case. Recover or safely close it; the current selection is not substituted.',
              ),
            ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error.isNotEmpty)
            Text(
              c.invalid
                  ? t(
                      'تغيرت الجلسة أو نطاق الطلب. أعد فتحه بالحساب الصحيح.',
                      'Session or case scope changed. Reopen with the correct account.',
                    )
                  : t(
                      'تعذر تأكيد النتيجة. احتفظ بالمرجع نفسه وتحقق قبل أي محاولة أخرى.',
                      'The outcome is unconfirmed. Keep the same reference and check before another attempt.',
                    ),
            ),
          if (c.reference == null && c.phase == 'ready') ...[
            identified(
              'owner-proposal-evidence',
              DropdownButtonFormField<String>(
                key: evidenceField,
                initialValue: null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t(
                    'نوع الدليل المستقل الفعلي',
                    'Actual independent evidence type',
                  ),
                ),
                items: [
                  for (final type in recoveryEvidenceTypes)
                    DropdownMenuItem(
                      value: type,
                      child: Text(evidenceLabel(type)),
                    ),
                ],
                onChanged: c.canPrepare
                    ? (value) => setState(() => evidence = value)
                    : null,
              ),
            ),
            identified(
              'owner-proposal-reason',
              TextField(
                key: const ValueKey('owner-proposal-reason'),
                controller: reason,
                enabled: c.canPrepare,
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: t(
                    'سبب خاص مبني على الدليل (١٠ أحرف على الأقل)',
                    'Private evidence-based reason (at least 10 characters)',
                  ),
                ),
              ),
            ),
            identified(
              'owner-proposal-attestation',
              CheckboxListTile(
                key: const ValueKey('owner-proposal-attestation'),
                contentPadding: EdgeInsets.zero,
                value: attested,
                onChanged: c.canPrepare
                    ? (value) => setState(() => attested = value == true)
                    : null,
                title: Text(
                  t(
                    'تحققت حضورياً من دليل مستقل فعلي؛ لم أعتمد الهاتف أو رقم الإيصال وحده',
                    'I checked actual independent evidence in person; phone or receipt reference alone was insufficient',
                  ),
                ),
              ),
            ),
            identified(
              'owner-proposal-prepare',
              FilledButton(
                key: const ValueKey('owner-proposal-prepare'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff174b83),
                ),
                onPressed:
                    c.canPrepare &&
                        recoveryEvidenceTypes.contains(evidence) &&
                        reason.text.trim().length >= 10 &&
                        attested
                    ? () => c.prepare(evidence, reason.text, attested)
                    : null,
                child: Text(
                  t(
                    'حفظ الاقتراح وطلب موافقة العميل',
                    'Save proposal and request customer consent',
                  ),
                ),
              ),
            ),
          ],
          if (stateLabel().isNotEmpty) Text(stateLabel()),
          if (c.receipt?['expires_at'] != null)
            Text(
              '${t('صالح حتى', 'Valid until')}: ${expiry(c.receipt!['expires_at'])}',
            ),
          if (c.contextMatches && c.receipt?['private_reason'] is String)
            Text(
              '${t('السبب المسجل', 'Recorded reason')}: ${c.receipt!['private_reason']}',
            ),
          if (c.canRetry)
            OutlinedButton(
              key: const ValueKey('owner-proposal-retry'),
              onPressed: c.retry,
              child: Text(
                t('إعادة إرسال الاقتراح نفسه', 'Retry the exact proposal'),
              ),
            ),
          if (c.reference != null)
            OutlinedButton(
              key: const ValueKey('owner-proposal-refresh'),
              onPressed: c.current && !c.busy ? c.refresh : null,
              child: Text(
                t('استعادة حالة الاقتراح', 'Recover proposal status'),
              ),
            ),
          if (c.canClose)
            OutlinedButton(
              key: const ValueKey('owner-proposal-close'),
              onPressed: c.close,
              child: Text(
                t(
                  'إغلاق مرجع الاقتراح بأمان',
                  'Safely close proposal reference',
                ),
              ),
            ),
          if (c.canAcknowledge)
            OutlinedButton(
              key: const ValueKey('owner-proposal-acknowledge'),
              onPressed: c.acknowledge,
              child: Text(
                t(
                  'راجعت النتيجة النهائية',
                  'I reviewed the definitive outcome',
                ),
              ),
            ),
          Text(
            t(
              'لا تُستخدم موافقة العميل كبديل عن التحقق المستقل، ولا تُنقل أرصدة أو مكافآت بهذه الخطوة.',
              'Customer consent does not replace independent verification. This step transfers no credits or rewards.',
            ),
          ),
        ],
      ),
    ),
  );
}
