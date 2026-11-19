import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'offline_customer_claim.dart';
import 'visit_recovery_request.dart';
import 'visit_recovery_proposal.dart';

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

class VisitRecoveryAttachmentReference {
  const VisitRecoveryAttachmentReference(
    this.requestId,
    this.caseId,
    this.claimId,
  );
  final String requestId, caseId, claimId;
  bool get valid => [requestId, caseId, claimId].every(_uuid.hasMatch);
}

/// RFC4122v5 identity, not proof/authority. Same actor/case/claim never rotates
/// across tabs/devices. Actual session, ownership and proof remain server checks.
VisitRecoveryAttachmentReference visitRecoveryAttachmentReference(
  String actor,
  String caseId,
  String claimId,
) {
  if (![actor, caseId, claimId].every(_uuid.hasMatch)) {
    throw const FormatException('Invalid reference');
  }
  const namespace = [
    0x6b,
    0xa7,
    0xb8,
    0x11,
    0x9d,
    0xad,
    0x11,
    0xd1,
    0x80,
    0xb4,
    0x00,
    0xc0,
    0x4f,
    0xd4,
    0x30,
    0xc8,
  ];
  final bytes = sha1
      .convert([
        ...namespace,
        ...utf8.encode(
          'sabiha/visit-recovery-attachment/v1/${actor.toLowerCase()}/${caseId.toLowerCase()}/${claimId.toLowerCase()}',
        ),
      ])
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 15) | 0x50;
  bytes[8] = (bytes[8] & 63) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return VisitRecoveryAttachmentReference(
    '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
    caseId.toLowerCase(),
    claimId.toLowerCase(),
  );
}

abstract class VisitRecoveryAttachmentStore {
  Future<List<VisitRecoveryAttachmentReference>> read();
  Future<VisitRecoveryAttachmentReference> save(
    VisitRecoveryAttachmentReference reference,
  );
  Future<void> clear(VisitRecoveryAttachmentReference reference);
}

/// Keys and values contain UUIDs only; no secret/receipt proof/phone/consent.
class SharedVisitRecoveryAttachmentStore
    implements VisitRecoveryAttachmentStore {
  SharedVisitRecoveryAttachmentStore(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get prefix {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return 'visit_recovery_attachment_uuid/$actor/';
  }

  @override
  Future<List<VisitRecoveryAttachmentReference>> read() async {
    final p = prefix, preferences = await SharedPreferences.getInstance();
    if (p != prefix) throw StateError('Session changed');
    final result = <VisitRecoveryAttachmentReference>[];
    for (final key in preferences.getKeys().where((k) => k.startsWith(p))) {
      final parts = key.substring(p.length).split('/');
      if (parts.length != 2) throw StateError('Unconfirmed reference');
      final ref = VisitRecoveryAttachmentReference(
        preferences.getString(key) ?? '',
        parts[0],
        parts[1],
      );
      if (!ref.valid) throw StateError('Unconfirmed reference');
      result.add(ref);
    }
    return result;
  }

  @override
  Future<VisitRecoveryAttachmentReference> save(
    VisitRecoveryAttachmentReference reference,
  ) async {
    if (!reference.valid) throw const FormatException('Invalid reference');
    final p = prefix, preferences = await SharedPreferences.getInstance();
    if (p != prefix) throw StateError('Session changed');
    final previous = await read();
    if (previous.isNotEmpty) {
      if (previous.length != 1 ||
          previous.single.caseId != reference.caseId ||
          previous.single.claimId != reference.claimId) {
        throw StateError('Recover original reference first');
      }
      return previous.single;
    }
    if (!await preferences.setString(
      '$p${reference.caseId}/${reference.claimId}',
      reference.requestId,
    )) {
      throw StateError('Reference not saved');
    }
    if (p != prefix) throw StateError('Session changed');
    return reference;
  }

  @override
  Future<void> clear(VisitRecoveryAttachmentReference reference) async {
    final p = prefix, preferences = await SharedPreferences.getInstance();
    if (p != prefix) throw StateError('Session changed');
    final key = '$p${reference.caseId}/${reference.claimId}';
    if (preferences.getString(key) != reference.requestId) {
      throw StateError('Reference changed');
    }
    if (!await preferences.remove(key)) {
      throw StateError('Reference not cleared');
    }
  }
}

abstract class VisitRecoveryEvidenceGateway {
  String? get currentActor;
  Future<Map<String, dynamic>> currentCase(String? caseId);
  Future<Map<String, dynamic>> ownClaim(String claimId);
  Future<Map<String, dynamic>> attach(
    VisitRecoveryAttachmentReference reference,
  );
}

class SupabaseVisitRecoveryEvidenceGateway
    implements VisitRecoveryEvidenceGateway {
  SupabaseVisitRecoveryEvidenceGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  @override
  String? get currentActor => client.auth.currentUser?.id;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (actor == null || currentActor != actor) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    final value = await client.rpc(name, params: params);
    if (currentActor != actor) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> currentCase(String? caseId) =>
      call('get_my_visit_recovery_request', {'p_case': caseId});
  @override
  Future<Map<String, dynamic>> ownClaim(String claimId) =>
      call('get_my_offline_customer_claim', {'p_request': claimId});
  @override
  Future<Map<String, dynamic>> attach(VisitRecoveryAttachmentReference ref) =>
      call('attach_my_visit_recovery_claim', {
        'p_request': ref.requestId,
        'p_case': ref.caseId,
        'p_claim': ref.claimId,
      });
}

class VisitRecoveryEvidenceController extends ChangeNotifier {
  VisitRecoveryEvidenceController({
    required this.gateway,
    required this.store,
    required this.claimStore,
  }) : actor = gateway.currentActor;
  final VisitRecoveryEvidenceGateway gateway;
  final VisitRecoveryAttachmentStore store;
  final OfflineClaimStore claimStore;
  final String? actor;
  Map<String, dynamic>? view;
  VisitRecoveryAttachmentReference? reference;
  String? claimId, claimStatus, error;
  bool busy = false,
      initialized = false,
      invalidated = false,
      disposed = false,
      uncertain = false;
  int epoch = 0;
  String? get caseId =>
      view?['case'] is Map ? view!['case']['case_id'] as String? : null;
  String? get caseStatus =>
      view?['case'] is Map ? view!['case']['status'] as String? : null;
  bool get open => ['awaiting_matching', 'more_info'].contains(caseStatus);
  bool get terminal => ['linked', 'rejected', 'revoked'].contains(caseStatus);
  bool get current =>
      !disposed &&
      !invalidated &&
      actor != null &&
      gateway.currentActor == actor;
  bool get proofCurrent => [
    'pending_owner_review',
    'approved_pending_reader_bridge',
  ].contains(claimStatus);
  bool get canAttach =>
      current &&
      initialized &&
      !busy &&
      open &&
      view?['case']['identity_current'] == true &&
      claimId != null &&
      proofCurrent;
  bool get canOpenProof =>
      current &&
      initialized &&
      !busy &&
      reference == null &&
      open &&
      view?['case']['identity_current'] == true;
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
    claimId = null;
    claimStatus = null;
    error = 'identity';
    changed();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy || !current) return;
    final token = epoch;
    busy = true;
    error = null;
    changed();
    try {
      await work();
    } catch (e) {
      if (current && token == epoch) {
        error = e is PostgrestException && e.code == '42501'
            ? 'identity'
            : 'unconfirmed';
      }
    } finally {
      if (current && token == epoch) {
        busy = false;
        initialized = true;
        changed();
      }
    }
  }

  void applyCase(Map<String, dynamic> value, {String? expected}) {
    ensure();
    if (value['state'] != 'available' ||
        value['case'] is! Map ||
        value['case']['case_id'] is! String ||
        !_uuid.hasMatch(value['case']['case_id']) ||
        (expected != null && value['case']['case_id'] != expected)) {
      throw StateError('Own case unconfirmed');
    }
    view = value;
  }

  Future<void> load({String? exactCase}) async {
    final refs = await store.read();
    ensure();
    if (refs.length > 1) throw StateError('Multiple pending references');
    reference = refs.isEmpty ? null : refs.single;
    if (reference != null && !reference!.valid) {
      throw StateError('Unconfirmed reference');
    }
    if (reference != null &&
        exactCase != null &&
        reference!.caseId != exactCase) {
      throw StateError('Recover original request first');
    }
    final target = reference?.caseId ?? exactCase;
    final data = await gateway.currentCase(target);
    ensure();
    if (data['state'] == 'unavailable' && target == null) {
      view = data;
      claimId = null;
      claimStatus = null;
      return;
    }
    applyCase(data, expected: target);
    if (reference != null && terminal) {
      await store.clear(reference!);
      ensure();
      reference = null;
      uncertain = false;
      claimId = null;
      claimStatus = null;
      return;
    }
    if (!open) {
      claimId = null;
      claimStatus = null;
      return;
    }
    if (reference != null) uncertain = true;
    final saved = reference?.claimId ?? await claimStore.read();
    ensure();
    claimId = null;
    claimStatus = null;
    if (saved == null) return;
    if (!_uuid.hasMatch(saved)) throw StateError('Claim reference unconfirmed');
    final claim = await gateway.ownClaim(saved);
    ensure();
    if (claim['request_id'] != saved) throw StateError('Own proof unconfirmed');
    claimId = saved;
    claimStatus = claim['status'] as String?;
  }

  Future<void> refresh() => run(() => load());
  Future<void> afterProof(String originalCase) =>
      run(() => load(exactCase: originalCase));
  Future<void> send() => run(() async {
    if (!open ||
        view?['case']['identity_current'] != true ||
        claimId == null ||
        !proofCurrent) {
      return;
    }
    final target = caseId!, proof = claimId!;
    final now = await gateway.currentCase(target);
    ensure();
    applyCase(now, expected: target);
    if (!open || view?['case']['identity_current'] != true) {
      throw StateError('Current case review required');
    }
    final claim = await gateway.ownClaim(proof);
    ensure();
    if (claim['request_id'] != proof ||
        ![
          'pending_owner_review',
          'approved_pending_reader_bridge',
        ].contains(claim['status'])) {
      throw StateError('Current proof required');
    }
    final intended =
        reference ?? visitRecoveryAttachmentReference(actor!, target, proof);
    if (intended.caseId != target || intended.claimId != proof) {
      throw StateError('Recover original request first');
    }
    final saved = await store.save(intended);
    ensure();
    if (!saved.valid || saved.caseId != target || saved.claimId != proof) {
      throw StateError('Stored identity changed');
    }
    reference = saved;
    uncertain = true;
    changed(); // Persistence MUST precede mutation.
    final response = await gateway.attach(saved);
    ensure();
    applyCase(response, expected: target);
    uncertain = false;
    if (terminal) {
      await store.clear(saved);
      ensure();
      reference = null;
    }
    // Pending is deliberately NOT an acknowledgment that any profile was mapped.
  });
  @override
  void dispose() {
    disposed = true;
    epoch++;
    super.dispose();
  }
}

class VisitRecoveryEvidenceScreen extends StatefulWidget {
  const VisitRecoveryEvidenceScreen({
    super.key,
    required this.client,
    this.gateway,
    this.attachmentStore,
    this.claimStore,
    this.requestPanelBuilder,
    this.proofBuilder,
    this.proposalBuilder,
  });
  final SupabaseClient client;
  final VisitRecoveryEvidenceGateway? gateway;
  final VisitRecoveryAttachmentStore? attachmentStore;
  final OfflineClaimStore? claimStore;
  final WidgetBuilder? requestPanelBuilder;
  final Widget Function(BuildContext, OfflineClaimStore)? proofBuilder;
  final Widget Function(BuildContext, String)? proposalBuilder;
  @override
  State<VisitRecoveryEvidenceScreen> createState() =>
      _VisitRecoveryEvidenceScreenState();
}

class _VisitRecoveryEvidenceScreenState
    extends State<VisitRecoveryEvidenceScreen>
    with WidgetsBindingObserver {
  late final VisitRecoveryEvidenceController controller;
  late final OfflineClaimStore claimStore;
  StreamSubscription<AuthState>? subscription;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  @override
  void initState() {
    super.initState();
    claimStore =
        widget.claimStore ??
        SharedOfflineClaimStore(widget.client, owner: false);
    controller = VisitRecoveryEvidenceController(
      gateway:
          widget.gateway ?? SupabaseVisitRecoveryEvidenceGateway(widget.client),
      store:
          widget.attachmentStore ??
          SharedVisitRecoveryAttachmentStore(widget.client),
      claimStore: claimStore,
    );
    final initial = widget.client.auth.currentSession;
    var replay = true;
    subscription = widget.client.auth.onAuthStateChange.listen((event) {
      final same = replay && matchesInitialAuthReplay(event, initial);
      replay = false;
      if (!same && event.event != AuthChangeEvent.initialSession) {
        controller.invalidate();
      }
    });
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(controller.refresh());
  }

  @override
  void dispose() {
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  Future<void> openProof() async {
    await controller.refresh();
    if (!mounted || !controller.canOpenProof) return;
    final original = controller.caseId!;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            widget.proofBuilder?.call(context, claimStore) ??
            CustomerOfflineClaimScreen(
              client: widget.client,
              store: claimStore,
            ),
      ),
    );
    if (mounted) await controller.afterProof(original);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(t('استرجاع زياراتي السابقة', 'Recover previous visits')),
    ),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          widget.requestPanelBuilder?.call(context) ??
              VisitRecoveryRequestPanel(
                client: widget.client,
                onRequestChanged: () {
                  if (mounted && controller.current) {
                    unawaited(controller.refresh());
                  }
                },
              ),
          if (controller.caseId != null)
            widget.proposalBuilder?.call(context, controller.caseId!) ??
                RecoveryProposalPanel(
                  key: ValueKey(
                    'recovery-proposal-${controller.caseId}-${controller.caseStatus}',
                  ),
                  client: widget.client,
                  caseId: controller.caseId!,
                  onChanged: () {
                    if (mounted && controller.current) {
                      unawaited(controller.refresh());
                    }
                  },
                ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t(
                      'إثبات الزيارة للمراجعة',
                      'Provide visit evidence for review',
                    ),
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(color: const Color(0xff071a36)),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t(
                      'إذا كان إيصال الاستقبال بحوزتك، افتح شاشة الإثبات وأدخله بنفسك. تطابق الهاتف ليس إثباتًا، ولا تُربط السجلات تلقائيًا.',
                      'If you have your reception receipt, enter it in the proof screen yourself. A phone match is not proof and records are never linked automatically.',
                    ),
                  ),
                  if (controller.busy) const LinearProgressIndicator(),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        controller.error == 'identity'
                            ? t(
                                'تعذر تأكيد الجلسة أو بيانات الحساب. أعد فتح الصفحة بعد تسجيل الدخول بالحساب نفسه.',
                                'Your current session or account could not be confirmed. Reopen with the same signed-in account.',
                              )
                            : t(
                                'تعذر تأكيد النتيجة. احتفظ بالمرجع المحفوظ وتحقق مجددًا؛ لا تبدأ طلبًا بديلًا.',
                                'The outcome is unconfirmed. Keep the saved reference and check again; do not create a replacement.',
                              ),
                      ),
                    ),
                  if (controller.caseStatus == 'linked')
                    Text(
                      t(
                        'تم تسجيل نتيجة المراجعة. عرض السجلات يتطلب إذن وصول منفصل وحالي.',
                        'The review outcome is recorded. Previous records require separate current access permission.',
                      ),
                    )
                  else if (controller.open)
                    Text(
                      t(
                        'لا يزال الطلب في انتظار مطابقة المعلومات أو مراجعة المالك. إرسال الإثبات لا يؤكد ربط أي سجل.',
                        'Still awaiting information matching or owner review. Sending proof does not confirm any record link.',
                      ),
                    )
                  else if (controller.terminal)
                    Text(
                      t(
                        'انتهت مراجعة هذا الطلب. راجع حالته قبل أي طلب جديد.',
                        'Review of this request has ended. Check its status before any new request.',
                      ),
                    )
                  else
                    Text(
                      t(
                        'أرسل طلب الاسترجاع أولًا ثم حدّث الحالة للمتابعة بالإثبات.',
                        'Submit a recovery request first, then refresh its status to continue with proof.',
                      ),
                    ),
                  if (controller.claimStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        controller.proofCurrent
                            ? t(
                                'تم العثور على طلب الإثبات الخاص بحسابك؛ لا يزال الربط خاضعًا للمراجعة.',
                                'Your saved proof request was found; linking still requires review.',
                              )
                            : t(
                                'الإثبات الحالي غير جاهز للربط. راجع حالته في شاشة الإثبات أو مع المالك.',
                                'Current proof is not ready for linking. Review its status in the proof screen or with the owner.',
                              ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('recovery-open-proof'),
                    onPressed:
                        controller.current &&
                            !controller.busy &&
                            controller.reference == null
                        ? openProof
                        : null,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(
                      t('فتح شاشة إثبات الإيصال', 'Open receipt proof screen'),
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('recovery-attach-proof'),
                    onPressed: controller.canAttach ? controller.send : null,
                    child: Text(
                      controller.reference == null
                          ? t('إرسال الإثبات للمراجعة', 'Send proof for review')
                          : t(
                              'إعادة المحاولة بالمرجع المحفوظ',
                              'Retry saved review request',
                            ),
                    ),
                  ),
                  OutlinedButton(
                    key: const ValueKey('recovery-evidence-refresh'),
                    onPressed: controller.current && !controller.busy
                        ? controller.refresh
                        : null,
                    child: Text(
                      t(
                        'تحديث حالة الطلب والإثبات',
                        'Refresh request and proof status',
                      ),
                    ),
                  ),
                  if (controller.uncertain)
                    Text(
                      t(
                        'قد يكون الإرسال السابق قد اكتمل. ستستخدم إعادة المحاولة المرجع نفسه فقط.',
                        'The previous submission may have completed. Retrying uses only the same saved reference.',
                      ),
                    ),
                  Text(
                    t(
                      'لا تمنح هذه الخطوة مكافآت أو صلاحية عرض سجلات تلقائيًا.',
                      'This step grants no rewards or automatic record access.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
