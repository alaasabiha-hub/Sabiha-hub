import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

final _id = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

class RecoveryProposalReference {
  const RecoveryProposalReference(this.request, this.caseId, this.proposal);
  final String request, caseId, proposal;
  bool get valid => [request, caseId, proposal].every(_id.hasMatch);
  List<String> get values => [request, caseId, proposal];
}

abstract class RecoveryProposalStore {
  Future<RecoveryProposalReference?> read();
  Future<RecoveryProposalReference> save(RecoveryProposalReference value);
  Future<void> clear(RecoveryProposalReference value);
}

/// The durable record contains UUIDs only, never proof, contacts or consent text.
class SharedRecoveryProposalStore implements RecoveryProposalStore {
  SharedRecoveryProposalStore(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return 'visit_recovery_proposal_uuid/$actor';
  }

  @override
  Future<RecoveryProposalReference?> read() async {
    final k = key, prefs = await SharedPreferences.getInstance();
    if (key != k) throw StateError('Session changed');
    final raw = prefs.getString(k);
    if (raw == null) return null;
    final values = jsonDecode(raw);
    if (values is! List ||
        values.length != 3 ||
        !values.every((x) => x is String && _id.hasMatch(x))) {
      throw StateError('Unconfirmed reference');
    }
    return RecoveryProposalReference(values[0], values[1], values[2]);
  }

  @override
  Future<RecoveryProposalReference> save(
    RecoveryProposalReference value,
  ) async {
    if (!value.valid) throw StateError('Invalid reference');
    final k = key, previous = await read();
    if (previous != null) {
      if (previous.values.join('/') != value.values.join('/')) {
        throw StateError('Recover original request');
      }
      return previous;
    }
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.setString(k, jsonEncode(value.values))) {
      throw StateError('Reference not saved');
    }
    if (key != k) throw StateError('Session changed');
    return value;
  }

  @override
  Future<void> clear(RecoveryProposalReference value) async {
    final k = key, previous = await read();
    if (previous == null ||
        previous.values.join('/') != value.values.join('/')) {
      throw StateError('Reference changed');
    }
    final prefs = await SharedPreferences.getInstance();
    if (key != k || !await prefs.remove(k)) {
      throw StateError('Reference not cleared');
    }
  }
}

abstract class RecoveryProposalGateway {
  String? get actor;
  Future<Map<String, dynamic>> current(String caseId);
  Future<Map<String, dynamic>> accept(
    RecoveryProposalReference ref,
    Map<String, dynamic> consent,
    Map<String, dynamic> claimConsent,
  );
  Future<Map<String, dynamic>> result(String request);
  Future<Map<String, dynamic>> close(String request);
}

class SupabaseRecoveryProposalGateway implements RecoveryProposalGateway {
  SupabaseRecoveryProposalGateway(this.client)
    : boundActor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? boundActor;
  @override
  String? get actor => client.auth.currentUser?.id;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (boundActor == null || actor != boundActor) {
      throw StateError('Session changed');
    }
    final data = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 30));
    if (actor != boundActor) throw StateError('Session changed');
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<Map<String, dynamic>> current(String caseId) =>
      call('get_my_visit_recovery_proposal', {'p_case': caseId});
  @override
  Future<Map<String, dynamic>> accept(
    RecoveryProposalReference ref,
    Map<String, dynamic> consent,
    Map<String, dynamic> claimConsent,
  ) => call('accept_my_visit_recovery_proposal', {
    'p_request': ref.request,
    'p_proposal': ref.proposal,
    'p_consent': consent,
    'p_claim_consent': claimConsent,
  });
  @override
  Future<Map<String, dynamic>> result(String request) =>
      call('get_my_visit_recovery_acceptance', {'p_request': request});
  @override
  Future<Map<String, dynamic>> close(String request) =>
      call('close_my_visit_recovery_acceptance', {'p_request': request});
}

class RecoveryProposalController extends ChangeNotifier {
  RecoveryProposalController({
    required this.caseId,
    required this.gateway,
    required this.store,
  }) : actor = gateway.actor;
  final String caseId;
  final RecoveryProposalGateway gateway;
  final RecoveryProposalStore store;
  final String? actor;
  RecoveryProposalReference? reference;
  Map<String, dynamic>? view;
  String phase = 'loading';
  bool busy = false, invalidated = false, disposed = false;
  int epoch = 0;
  String? error;
  bool get current =>
      !disposed && !invalidated && actor != null && actor == gateway.actor;
  bool get terminal =>
      ['accepted', 'review_required', 'closed'].contains(phase);
  bool get canAccept =>
      current &&
      !busy &&
      reference == null &&
      view?['state'] == 'open' &&
      view?['proposal'] is Map;
  void changed() {
    if (!disposed) notifyListeners();
  }

  void ensure() {
    if (!current) throw StateError('Session changed');
  }

  void invalidate() {
    epoch++;
    invalidated = true;
    busy = false;
    view = null;
    reference = null;
    phase = 'invalid';
    error = 'identity';
    changed();
  }

  Future<void> run(Future<void> Function() work) async {
    if (!current || busy) return;
    final token = epoch;
    busy = true;
    error = null;
    changed();
    try {
      await work();
    } catch (_) {
      if (current && token == epoch) {
        view = null;
        error = 'unconfirmed';
      }
    } finally {
      if (current && token == epoch) {
        busy = false;
        changed();
      }
    }
  }

  void applyResult(Map<String, dynamic> data) {
    ensure();
    final ref = reference!;
    if (data['request_id'] != ref.request) throw StateError('Result mismatch');
    final state = data['state'];
    if (['accepted', 'review_required'].contains(state)) {
      if (data['proposal_id'] != ref.proposal ||
          data['case_id'] != ref.caseId ||
          data['link_created'] != false ||
          data['approval_required'] != true) {
        throw StateError('Unconfirmed result');
      }
      phase = state;
    } else if (state == 'closed') {
      phase = 'closed';
    } else if (['absent', 'manual_review_required'].contains(state)) {
      phase = 'uncertain';
    } else {
      throw StateError('Unsupported result');
    }
    // Own claim IDs and server payloads are deliberately not cached or shown.
    view = null;
  }

  Future<void> load() async {
    final saved = await store.read();
    ensure();
    if (saved != null &&
        reference != null &&
        saved.values.join('/') != reference!.values.join('/')) {
      throw StateError('Saved reference changed');
    }
    reference = saved ?? reference;
    if (reference != null) {
      if (!reference!.valid) throw StateError('Invalid saved reference');
      phase = 'uncertain';
      applyResult(await gateway.result(reference!.request));
      ensure();
      return;
    }
    view = null;
    final data = await gateway.current(caseId);
    ensure();
    if (data['case_id'] != caseId ||
        ![
          'unavailable',
          'review_required',
          'open',
          'accepted',
          'closed',
          'expired',
        ].contains(data['state']) ||
        data['approval_required'] != true ||
        data['link_created'] != false) {
      throw StateError('Unconfirmed proposal');
    }
    if (data['state'] == 'open') {
      final proposal = data['proposal'];
      if (proposal is! Map ||
          !_id.hasMatch(proposal['proposal_id'] as String? ?? '') ||
          data['consent_version'] != 'visit-recovery-proposal-v1' ||
          data['canonical_consent_version'] != 'offline-claim-v1') {
        throw StateError('Unconfirmed terms');
      }
      for (final key in [
        'notice_ar',
        'notice_en',
        'canonical_notice_ar',
        'canonical_notice_en',
      ]) {
        if (data[key] is! String || (data[key] as String).isEmpty) {
          throw StateError('Missing terms');
        }
      }
      // Whitelist the only information needed before owner approval.
      view = {
        for (final k in [
          'case_id',
          'state',
          'consent_version',
          'notice_ar',
          'notice_en',
          'canonical_consent_version',
          'canonical_notice_ar',
          'canonical_notice_en',
        ])
          k: data[k],
        'proposal': {
          'proposal_id': proposal['proposal_id'],
          'expires_at': proposal['expires_at'],
        },
      };
    }
    phase = data['state'];
  }

  Future<void> refresh() => run(load);
  Future<void> accept({
    required String language,
    required bool accepted,
    required bool claimAccepted,
  }) => run(() async {
    if (reference != null ||
        view?['state'] != 'open' ||
        !accepted ||
        !claimAccepted ||
        !['ar', 'en'].contains(language)) {
      return;
    }
    final captured = view!;
    final ref = RecoveryProposalReference(
      newOrderRequestId(),
      caseId,
      captured['proposal']['proposal_id'],
    );
    reference = ref;
    phase = 'uncertain';
    // Set the in-memory tuple first so a failed save can never rotate a nonce.
    final saved = await store.save(ref);
    ensure();
    if (saved.values.join('/') != ref.values.join('/')) {
      throw StateError('Reference changed');
    }
    final consent = {
      'accepted': true,
      'version': captured['consent_version'],
      'language': language,
      'text': captured['notice_$language'],
    };
    final claim = {
      'accepted': true,
      'version': captured['canonical_consent_version'],
      'language': language,
      'text': captured['canonical_notice_$language'],
    };
    view = null;
    changed();
    final result = await gateway.accept(ref, consent, claim);
    ensure();
    applyResult(result);
  });
  Future<void> close() => run(() async {
    final ref = reference;
    if (ref == null || terminal) return;
    // A failed local save must succeed before any server close/accept dispatch.
    await store.save(ref);
    ensure();
    applyResult(await gateway.close(ref.request));
    ensure();
  });
  Future<void> acknowledge() => run(() async {
    if (!terminal || reference == null) return;
    await store.clear(reference!);
    ensure();
    reference = null;
    await load();
  });
  @override
  void dispose() {
    disposed = true;
    epoch++;
    super.dispose();
  }
}

class RecoveryProposalPanel extends StatefulWidget {
  const RecoveryProposalPanel({
    super.key,
    required this.client,
    required this.caseId,
    this.gateway,
    this.store,
    this.onChanged,
  });
  final SupabaseClient client;
  final String caseId;
  final RecoveryProposalGateway? gateway;
  final RecoveryProposalStore? store;
  final VoidCallback? onChanged;
  @override
  State<RecoveryProposalPanel> createState() => _RecoveryProposalPanelState();
}

class _RecoveryProposalPanelState extends State<RecoveryProposalPanel> {
  late final RecoveryProposalController c;
  StreamSubscription<AuthState>? sub;
  bool accepted = false, claimAccepted = false;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    c = RecoveryProposalController(
      caseId: widget.caseId,
      gateway: widget.gateway ?? SupabaseRecoveryProposalGateway(widget.client),
      store: widget.store ?? SharedRecoveryProposalStore(widget.client),
    );
    final initial = widget.client.auth.currentSession;
    var replay = true;
    sub = widget.client.auth.onAuthStateChange.listen((event) {
      final same = replay && matchesInitialAuthReplay(event, initial);
      replay = false;
      if (!same && event.event != AuthChangeEvent.initialSession) {
        accepted = false;
        claimAccepted = false;
        c.invalidate();
      }
    });
    unawaited(c.refresh());
  }

  @override
  void didUpdateWidget(covariant RecoveryProposalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.caseId != widget.caseId ||
        oldWidget.client != widget.client) {
      accepted = false;
      claimAccepted = false;
      c.invalidate();
    }
  }

  @override
  void dispose() {
    sub?.cancel();
    c.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      accepted = false;
      claimAccepted = false;
    });
    await c.refresh();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('مراجعة السجل المقترح', 'Proposed record review'),
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: const Color(0xff071a36)),
            ),
            const SizedBox(height: 8),
            Text(
              t(
                'لا يظهر أي سجل قديم قبل التحقق المستقل وموافقة المالك. موافقتك هنا لطلب المراجعة فقط، وليست ربطًا أو استبدالًا للنقاط.',
                'Previous records remain private until independent verification and owner approval. Your consent requests review only; it does not link records or redeem points.',
              ),
            ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.error != null)
              Text(
                c.invalidated
                    ? t(
                        'تغيرت الجلسة. أعد فتح الصفحة بالحساب الصحيح.',
                        'Your session changed. Reopen with the correct account.',
                      )
                    : t(
                        'لم تتأكد النتيجة. تحقق بالمرجع المحفوظ قبل بدء طلب آخر.',
                        'The outcome is unconfirmed. Check the saved reference before another request.',
                      ),
              ),
            if (c.view?['state'] == 'open') ...[
              const SizedBox(height: 12),
              Text(
                c.view!['notice_${Localizations.localeOf(context).languageCode == 'ar' ? 'ar' : 'en'}'],
              ),
              CheckboxListTile(
                value: accepted,
                onChanged: c.canAccept
                    ? (v) => setState(() => accepted = v ?? false)
                    : null,
                title: Text(
                  t(
                    'أوافق على مراجعة اقتراح المالك',
                    'I agree to review the owner proposal',
                  ),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              Text(
                c.view!['canonical_notice_${Localizations.localeOf(context).languageCode == 'ar' ? 'ar' : 'en'}'],
              ),
              CheckboxListTile(
                value: claimAccepted,
                onChanged: c.canAccept
                    ? (v) => setState(() => claimAccepted = v ?? false)
                    : null,
                title: Text(
                  t(
                    'أوافق على طلب التحقق المستقل',
                    'I agree to request independent verification',
                  ),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              FilledButton(
                key: const ValueKey('recovery-proposal-accept'),
                onPressed: c.canAccept && accepted && claimAccepted
                    ? () async {
                        await c.accept(
                          language:
                              Localizations.localeOf(context).languageCode ==
                                  'ar'
                              ? 'ar'
                              : 'en',
                          accepted: accepted,
                          claimAccepted: claimAccepted,
                        );
                        if (mounted) {
                          setState(() {
                            accepted = false;
                            claimAccepted = false;
                          });
                          widget.onChanged?.call();
                        }
                      }
                    : null,
                child: Text(
                  t('إرسال موافقتي للمراجعة', 'Submit my consent for review'),
                ),
              ),
            ] else if (c.terminal)
              Text(
                c.phase == 'accepted'
                    ? t(
                        'سُجل طلب التحقق. راجع حالة طلب الاسترجاع لمعرفة القرار النهائي؛ هذه الخطوة لا تنشئ ربطًا بنفسها.',
                        'Your verification request is recorded. Check your recovery request for the final decision; this step does not create a link.',
                      )
                    : c.phase == 'closed'
                    ? t(
                        'أُغلق مرجع المحاولة دون إلغاء أي مراجعة سابقة.',
                        'The attempt reference is closed; prior reviews were not cancelled.',
                      )
                    : t(
                        'تحتاج الحالة إلى مراجعة إضافية من الإدارة.',
                        'Additional administrative review is required.',
                      ),
              )
            else if (c.phase == 'uncertain')
              Text(
                t(
                  'قد تكون المحاولة السابقة قد اكتملت. تحقق من نتيجتها أو أغلق مرجعها بأمان؛ لا تبدأ محاولة بديلة.',
                  'The previous attempt may have completed. Check its result or safely close its reference before another attempt.',
                ),
              )
            else
              Text(
                t(
                  'لا يوجد اقتراح حالي قابل للمراجعة. يمكنك متابعة طلب الاسترجاع أو التواصل مع الإدارة.',
                  'No current proposal is available. Follow your recovery request or contact management.',
                ),
              ),
            const SizedBox(height: 8),
            if (c.terminal && c.reference != null)
              OutlinedButton(
                onPressed: !c.busy && c.current
                    ? () async {
                        await c.acknowledge();
                        widget.onChanged?.call();
                      }
                    : null,
                child: Text(
                  t('راجعت نتيجة الموافقة', 'I reviewed the consent outcome'),
                ),
              ),
            OutlinedButton(
              onPressed: !c.busy && c.current ? refresh : null,
              child: Text(
                t('تحديث الاقتراح والنتيجة', 'Refresh proposal and outcome'),
              ),
            ),
            if (c.reference != null && !c.terminal)
              OutlinedButton(
                onPressed: !c.busy && c.current ? c.close : null,
                child: Text(
                  t(
                    'إغلاق مرجع المحاولة بأمان',
                    'Safely close attempt reference',
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
