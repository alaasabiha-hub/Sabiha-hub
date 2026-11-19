import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_customer_claim.dart'
    show OfflineClaimGateway, OfflineClaimStore, SupabaseOfflineClaimGateway;
import 'workflow.dart' show newOrderRequestId;
import 'invoices.dart' show matchesInitialAuthReplay;
import 'owner_visit_recovery_investigation.dart';

Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);

class VisitRecoveryReviewStore implements OfflineClaimStore {
  VisitRecoveryReviewStore(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Identity changed');
    }
    return 'owner_visit_recovery_review_uuid_$actor';
  }

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String id) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, id)) {
      throw StateError('Reference unavailable');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Reference unavailable');
    }
  }
}

class OwnerVisitRecoveryController extends ChangeNotifier {
  OwnerVisitRecoveryController({required this.gateway, required this.store});
  final OfflineClaimGateway gateway;
  final OfflineClaimStore store;
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic>? cursor, receipt;
  String? requestId, error;
  bool busy = false, initialized = false, invalid = false;
  int epoch = 0;
  bool _disposed = false;
  bool get locked => !initialized || busy || invalid || requestId != null;
  String get state => receipt?['state']?.toString() ?? 'unconfirmed';
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    epoch++;
    invalid = true;
    items = [];
    cursor = null;
    receipt = null;
    requestId = null;
    busy = false;
    error = 'identity';
    changed();
  }

  bool current(int e) => !_disposed && !invalid && epoch == e;
  Future<void> run(Future<void> Function(int) task) async {
    if (busy || invalid || _disposed) return;
    final e = epoch;
    busy = true;
    error = null;
    changed();
    try {
      await task(e);
    } on PostgrestException catch (ex) {
      if (current(e)) {
        if (ex.code == '42501') {
          items = [];
          cursor = null;
          receipt = null;
        }
        error = ex.code == '40001'
            ? 'stale'
            : ex.code == '42501'
            ? 'denied'
            : 'unknown';
      }
    } catch (_) {
      if (current(e)) error = 'unknown';
    } finally {
      if (current(e)) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> _accept(dynamic value, int e) async {
    if (!current(e)) return;
    final v = _map(value);
    if (v['request_id'] != requestId) throw StateError('Receipt mismatch');
    receipt = v;
  }

  Future<void> _list(int e, {bool more = false}) async {
    final next = more ? cursor : null;
    final v = _map(
      await gateway.rpc('list_visit_recovery_requests', {
        'p_status': null,
        'p_before_created_at': next?['created_at'],
        'p_before_case': next?['case_id'],
        'p_limit': 25,
      }),
    );
    if (!current(e)) return;
    final page = (v['items'] as List).map(_map).toList();
    items = more ? [...items, ...page] : page;
    cursor = v['next_cursor'] == null ? null : _map(v['next_cursor']);
  }

  Future<void> initialize() => run((e) async {
    final id = await store.read();
    if (!current(e)) return;
    requestId = id;
    initialized = true;
    if (id != null) {
      await _accept(
        await gateway.rpc('get_visit_recovery_review', {'p_request': id}),
        e,
      );
    }
    if (current(e)) await _list(e);
  });
  Future<void> refresh() => run((e) async {
    if (requestId != null) {
      await _accept(
        await gateway.rpc('get_visit_recovery_review', {
          'p_request': requestId,
        }),
        e,
      );
    }
    if (current(e)) await _list(e);
  });
  Future<void> loadMore() => run((e) async {
    if (cursor != null) await _list(e, more: true);
  });
  Future<void> prepare(
    Map<String, dynamic> item,
    String action,
    String reason,
  ) => run((e) async {
    if (requestId != null || !initialized) return;
    if (item['canonical_claim_mapped'] == true) {
      throw StateError('Canonical review required');
    }
    final trimmed = reason.trim();
    if (trimmed.length < 10 || trimmed.length > 500) {
      throw StateError('Reason required');
    }
    if (action == 'more_info' && item['more_info_available'] != true ||
        action == 'reject' && item['reject_available'] != true) {
      throw StateError('Unavailable action');
    }
    final id = newOrderRequestId();
    await store.write(id);
    if (!current(e)) return;
    requestId = id;
    receipt = null;
    await _accept(
      await gateway.rpc('prepare_visit_recovery_review', {
        'p_request': id,
        'p_case': item['case_id'],
        'p_expected_status': item['status'],
        'p_action': action,
        'p_reason': trimmed,
      }),
      e,
    );
  });
  Future<void> apply() => run((e) async {
    if (requestId == null || state != 'open') return;
    await _accept(
      await gateway.rpc('apply_visit_recovery_review', {
        'p_request': requestId,
      }),
      e,
    );
    if (current(e)) await _list(e);
  });
  Future<void> close() => run((e) async {
    if (requestId == null) return;
    await _accept(
      await gateway.rpc('close_visit_recovery_review', {
        'p_request': requestId,
      }),
      e,
    );
  });
  Future<void> acknowledge() => run((e) async {
    if (!['closed', 'succeeded'].contains(state)) return;
    await store.clear();
    if (!current(e)) return;
    requestId = null;
    receipt = null;
    await _list(e);
  });
  @override
  void dispose() {
    _disposed = true;
    epoch++;
    super.dispose();
  }
}

class OwnerVisitRecoveryScreen extends StatefulWidget {
  const OwnerVisitRecoveryScreen({
    super.key,
    required this.client,
    this.gateway,
    this.store,
    this.onCanonicalReview,
  });
  final SupabaseClient client;
  final OfflineClaimGateway? gateway;
  final OfflineClaimStore? store;
  final Future<void> Function(BuildContext context, String claimId)?
  onCanonicalReview;
  @override
  State<OwnerVisitRecoveryScreen> createState() =>
      _OwnerVisitRecoveryScreenState();
}

class _OwnerVisitRecoveryScreenState extends State<OwnerVisitRecoveryScreen> {
  late final OwnerVisitRecoveryController flow;
  StreamSubscription<AuthState>? subscription;
  TextEditingController? activeReason;
  BuildContext? reviewDialogContext;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  String statusLabel(dynamic value) => switch (value) {
    'awaiting_matching' => t(
      'بانتظار مطابقة المعلومات',
      'Awaiting information matching',
    ),
    'more_info' => t('مطلوب معلومات إضافية', 'More information requested'),
    'rejected' => t('مرفوض', 'Rejected'),
    'linked' => t('تم ربط الزيارات', 'Visits linked'),
    'revoked' => t('تم إلغاء الربط', 'Link revoked'),
    'open' => t('مراجعة محضرة', 'Prepared review'),
    'succeeded' => t('تم تنفيذ المراجعة', 'Review completed'),
    'closed' => t('مرجع مغلق', 'Closed reference'),
    _ => t('النتيجة غير مؤكدة', 'Outcome unconfirmed'),
  };
  @override
  void initState() {
    super.initState();
    flow = OwnerVisitRecoveryController(
      gateway: widget.gateway ?? SupabaseOfflineClaimGateway(widget.client),
      store: widget.store ?? VisitRecoveryReviewStore(widget.client),
    );
    final initialSession = widget.client.auth.currentSession;
    var replayPending = true;
    subscription = widget.client.auth.onAuthStateChange.listen((s) {
      final sameReplay =
          replayPending && matchesInitialAuthReplay(s, initialSession);
      replayPending = false;
      if (sameReplay) return;
      if (s.event != AuthChangeEvent.initialSession) {
        activeReason?.clear();
        final dialog = reviewDialogContext;
        if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
        flow.invalidate();
      }
    });
    flow.initialize();
  }

  @override
  void dispose() {
    subscription?.cancel();
    flow.dispose();
    super.dispose();
  }

  Future<void> review(Map<String, dynamic> item, String action) async {
    final reason = TextEditingController();
    activeReason = reason;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) {
        reviewDialogContext = c;
        return AlertDialog(
          title: Text(t('سبب المراجعة', 'Review reason')),
          content: TextField(
            controller: reason,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: t(
                'سبب خاص بالمالك (١٠ أحرف على الأقل)',
                'Private owner reason (at least 10 characters)',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t('تحضير المراجعة', 'Prepare review')),
            ),
          ],
        );
      },
    );
    reviewDialogContext = null;
    activeReason = null;
    if (confirmed == true && mounted) {
      await flow.prepare(item, action, reason.text);
    }
    reason.clear();
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f6f8),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(t('مراجعة استعادة الزيارات', 'Visit recovery reviews')),
    ),
    body: AnimatedBuilder(
      animation: flow,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  'الربط يتطلب الإثبات والمراجعة المعتمدة. لا يتم منح مكافآت تلقائياً.',
                  'Linking requires canonical proof and review. Rewards are not granted automatically.',
                ),
              ),
              if (flow.error != null)
                Text(
                  flow.error == 'stale'
                      ? t(
                          'تغيرت حالة الطلب. أغلق مرجع المراجعة ثم حدّث القائمة.',
                          'Case changed. Close the review reference, then refresh.',
                        )
                      : flow.error == 'identity'
                      ? t(
                          'تغيرت الجلسة. أعد فتح الشاشة بحساب المالك.',
                          'Session changed. Reopen with the owner account.',
                        )
                      : t(
                          'لم تتأكد النتيجة. احتفظ بالمرجع واستعلم أو أغلقه بأمان.',
                          'Result unconfirmed. Recover or safely close the reference.',
                        ),
                  style: const TextStyle(color: Colors.red),
                ),
              if (flow.busy) const LinearProgressIndicator(),
              if (flow.requestId != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('مرجع المراجعة', 'Review reference')),
                        SelectableText(flow.requestId!),
                        Text(statusLabel(flow.state)),
                        if (flow.receipt?['payload'] is Map)
                          Text(
                            '${flow.receipt!['payload']['private_reason'] ?? ''}',
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: flow.busy ? null : flow.refresh,
                              child: Text(
                                t('استعادة النتيجة', 'Recover result'),
                              ),
                            ),
                            if (flow.state == 'open')
                              FilledButton(
                                onPressed: flow.busy ? null : flow.apply,
                                child: Text(
                                  t(
                                    'تنفيذ المراجعة المحضرة',
                                    'Apply prepared review',
                                  ),
                                ),
                              ),
                            if (!['closed', 'succeeded'].contains(flow.state))
                              TextButton(
                                onPressed: flow.busy ? null : flow.close,
                                child: Text(
                                  t(
                                    'إغلاق المرجع بأمان',
                                    'Safely close reference',
                                  ),
                                ),
                              ),
                            if (['closed', 'succeeded'].contains(flow.state))
                              FilledButton(
                                onPressed: flow.busy ? null : flow.acknowledge,
                                child: Text(
                                  t('تمت مراجعة النتيجة', 'Acknowledge result'),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: flow.busy || flow.invalid ? null : flow.refresh,
                  child: Text(t('تحديث', 'Refresh')),
                ),
              ),
              for (final item in flow.items)
                Card(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item['requester_name'] ?? ''}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xff174b83),
                          ),
                        ),
                        Text('${item['registered_phone'] ?? ''}'),
                        Text(statusLabel(item['status'])),
                        SelectableText('${item['case_id']}'),
                        if (item['identity_current'] != true)
                          Text(
                            t(
                              'بيانات الهوية تحتاج مراجعة حالية',
                              'Identity requires current review',
                            ),
                          ),
                        if (item['canonical_claim_mapped'] == false &&
                            item['identity_current'] == true &&
                            [
                              'awaiting_matching',
                              'more_info',
                            ].contains(item['status']))
                          TextButton(
                            key: ValueKey(
                              'investigation-open-${item['case_id']}',
                            ),
                            onPressed: flow.locked || flow.invalid
                                ? null
                                : () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            VisitRecoveryInvestigationScreen(
                                              client: widget.client,
                                              caseId: item['case_id'] as String,
                                              gateway: widget.gateway,
                                            ),
                                      ),
                                    );
                                    if (mounted && !flow.invalid) {
                                      await flow.refresh();
                                    }
                                  },
                            child: Text(
                              t(
                                'التحقق من سجلات الاستقبال',
                                'Investigate reception records',
                              ),
                            ),
                          ),
                        if (item['canonical_claim_mapped'] == true) ...[
                          Text(
                            t(
                              'مرجع طلب الإثبات المعتمد',
                              'Canonical claim reference',
                            ),
                          ),
                          SelectableText(
                            '${item['canonical_claim_reference'] ?? ''}',
                          ),
                          TextButton(
                            onPressed:
                                flow.locked || widget.onCanonicalReview == null
                                ? null
                                : () async {
                                    await widget.onCanonicalReview!(
                                      context,
                                      item['canonical_claim_reference']
                                          .toString(),
                                    );
                                    if (mounted) flow.refresh();
                                  },
                            child: Text(
                              t('فتح مراجعة الإثبات', 'Open canonical review'),
                            ),
                          ),
                        ] else
                          Wrap(
                            spacing: 8,
                            children: [
                              if (item['more_info_available'] == true)
                                TextButton(
                                  onPressed: flow.locked
                                      ? null
                                      : () => review(item, 'more_info'),
                                  child: Text(
                                    t(
                                      'طلب معلومات إضافية',
                                      'Request more information',
                                    ),
                                  ),
                                ),
                              if (item['reject_available'] == true)
                                TextButton(
                                  onPressed: flow.locked
                                      ? null
                                      : () => review(item, 'reject'),
                                  child: Text(t('رفض', 'Reject')),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              if (flow.cursor != null)
                TextButton(
                  onPressed: flow.busy ? null : flow.loadMore,
                  child: Text(t('تحميل المزيد', 'Load more')),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
