import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

abstract class OwnerEvidenceTasksGateway {
  String? get actor;
  Stream<void> get authChanges;
  Future<List<Map<String, dynamic>>> list();
  Future<Map<String, dynamic>> save(Map<String, dynamic> params);
  Future<List<Map<String, dynamic>>> history(String task);
}

class SupabaseOwnerEvidenceTasksGateway implements OwnerEvidenceTasksGateway {
  final SupabaseClient client;
  final Session? session;
  SupabaseOwnerEvidenceTasksGateway(this.client)
    : session = client.auth.currentSession;
  @override
  String? get actor =>
      client.auth.currentSession?.accessToken == session?.accessToken
      ? session?.user.id
      : null;
  @override
  Stream<void> get authChanges => client.auth.onAuthStateChange
      .where(
        (e) =>
            e.session?.accessToken != session?.accessToken ||
            e.event == AuthChangeEvent.signedOut,
      )
      .map((_) {});
  void check() {
    if (actor == null) throw StateError('Owner session changed');
  }

  @override
  Future<List<Map<String, dynamic>>> list() async {
    check();
    final data = await client.rpc('list_owner_evidence_tasks');
    check();
    return List<Map<String, dynamic>>.from(data as List);
  }

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> params) async {
    check();
    final data = await client.rpc('save_owner_evidence_task', params: params);
    check();
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> history(String task) async {
    check();
    final data = await client.rpc(
      'get_owner_evidence_task_history',
      params: {'p_task': task},
    );
    check();
    return List<Map<String, dynamic>>.from(data as List);
  }
}

const evidenceTaskActions = <String, (String, String)>{
  'reconcile_invoices': (
    'مراجعة مطابقة الفواتير والتحصيل',
    'Review invoice and collection reconciliation',
  ),
  'review_expense_records': (
    'مراجعة مستندات المصروفات',
    'Review expense records',
  ),
  'verify_stock_counts': (
    'مراجعة الجرد الفعلي',
    'Review physical stock counts',
  ),
  'review_appointment_workload': (
    'مراجعة عبء المواعيد',
    'Review appointment workload',
  ),
  'review_feedback_coverage': (
    'مراجعة تمثيل تقييمات العملاء',
    'Review feedback coverage',
  ),
};

class OwnerEvidenceTasksScreen extends StatefulWidget {
  final OwnerEvidenceTasksGateway gateway;
  final DateTime from, to;
  const OwnerEvidenceTasksScreen({
    super.key,
    required this.gateway,
    required this.from,
    required this.to,
  });
  @override
  State<OwnerEvidenceTasksScreen> createState() =>
      _OwnerEvidenceTasksScreenState();
}

class _OwnerEvidenceTasksScreenState extends State<OwnerEvidenceTasksScreen> {
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic>? pending;
  String action = 'reconcile_invoices';
  String? error;
  bool busy = true, invalid = false;
  int epoch = 0;
  StreamSubscription<void>? subscription;
  final scopeLost = ValueNotifier<bool>(false);
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String label(String key) => switch (key) {
    'proposed' => t('بانتظار المراجعة', 'Awaiting review'),
    'approved' => t(
      'موافق عليه للمراجعة اليدوية',
      'Approved for manual review',
    ),
    'dismissed' => t('مرفوض', 'Dismissed'),
    'completed' => t(
      'سجّل المالك إتمام المراجعة',
      'Owner recorded review completion',
    ),
    _ => key,
  };
  bool current(int generation, String? actor) =>
      mounted &&
      !invalid &&
      generation == epoch &&
      actor != null &&
      widget.gateway.actor == actor;
  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.authChanges.listen((_) {
      if (mounted) {
        scopeLost.value = true;
        setState(() {
          invalid = true;
          epoch++;
          rows = [];
          pending = null;
          busy = false;
          error = null;
        });
      }
    });
    load();
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    scopeLost.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (invalid || pending != null) return;
    final generation = ++epoch, actor = widget.gateway.actor;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.list();
      if (current(generation, actor)) {
        setState(() {
          rows = result;
          error = null;
        });
      }
    } catch (_) {
      if (current(generation, actor)) {
        setState(
          () => error = t(
            'تعذر تحميل المقترحات. تحقق من الاتصال وصلاحية المالك.',
            'Unable to load proposals. Check connection and owner access.',
          ),
        );
      }
    } finally {
      if (current(generation, actor)) setState(() => busy = false);
    }
  }

  Future<String?> reason() => showDialog<String>(
    context: context,
    builder: (_) => scopedDialog(_EvidenceDecisionDialog(arabic: ar)),
  );

  Widget scopedDialog(Widget dialog) => ValueListenableBuilder<bool>(
    valueListenable: scopeLost,
    builder: (context, lost, _) => lost
        ? AlertDialog(
            title: Text(t('انتهت الجلسة', 'Session ended')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('إغلاق', 'Close')),
              ),
            ],
          )
        : dialog,
  );

  Future<void> proposeOrReview(Map<String, dynamic>? row, String state) async {
    if (busy || invalid || pending != null) return;
    final actor = widget.gateway.actor, generation = epoch;
    final note = await reason();
    if (!current(generation, actor) || note == null) return;
    pending = {
      'p_request': newOrderRequestId(),
      'p_action': row?['action'] ?? action,
      'p_from': row?['from'] ?? widget.from.toIso8601String().substring(0, 10),
      'p_to': row?['to'] ?? widget.to.toIso8601String().substring(0, 10),
      'p_task': row?['task_id'],
      'p_expected_version': row?['version'],
      'p_state': state,
      'p_reason': note,
    };
    await dispatch();
  }

  Future<void> dispatch() async {
    if (pending == null || invalid || busy) return;
    final actor = widget.gateway.actor, generation = epoch;
    final params = Map<String, dynamic>.from(pending!);
    setState(() => busy = true);
    var reload = false;
    try {
      await widget.gateway.save(params);
      if (!current(generation, actor)) return;
      pending = null;
      error = null;
      reload = true;
    } catch (e) {
      if (!current(generation, actor)) return;
      if (e is PostgrestException &&
          const {
            '22023',
            '42501',
            '40001',
            '55000',
            '23514',
          }.contains(e.code)) {
        pending = null;
        error = t(
          'لم يُحفظ القرار. حدّث المقترح وراجع الأدلة والصلاحيات قبل محاولة جديدة.',
          'Decision not saved. Reload and review evidence and access before trying again.',
        );
      } else {
        error = t(
          'نتيجة الحفظ غير مؤكدة. أعد نفس الطلب للتحقق دون تكرار القرار.',
          'Save outcome is uncertain. Retry the same request to resolve it without duplicating the decision.',
        );
      }
    } finally {
      if (current(generation, actor)) {
        setState(() => busy = false);
        if (reload) await load();
      }
    }
  }

  Future<void> showHistory(Map<String, dynamic> row) async {
    final actor = widget.gateway.actor, generation = epoch;
    setState(() => busy = true);
    try {
      final events = await widget.gateway.history(row['task_id'] as String);
      if (!current(generation, actor)) return;
      if (!mounted) return;
      setState(() => busy = false);
      await showDialog<void>(
        context: context,
        builder: (context) => scopedDialog(
          AlertDialog(
            title: Text(t('سجل القرارات', 'Decision history')),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: events
                      .map(
                        (e) => ListTile(
                          title: Text(label(e['after_state'] as String)),
                          subtitle: Text(
                            '${e['reason']}\n${formatDate(e['created_at'] as String)}',
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('إغلاق', 'Close')),
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (current(generation, actor)) {
        setState(
          () => error = t(
            'تعذر تحميل سجل القرارات.',
            'Unable to load decision history.',
          ),
        );
      }
    } finally {
      if (current(generation, actor)) setState(() => busy = false);
    }
  }

  String formatDate(String raw) {
    final date = DateTime.tryParse(raw)?.toLocal();
    return date == null
        ? '—'
        : MaterialLocalizations.of(context).formatMediumDate(date);
  }

  Widget evidence(Map<String, dynamic> row) {
    final data = row['evidence'];
    final metrics = data is Map ? data['metrics'] : null;
    const names = {
      'billed_revenue': ('الفواتير', 'Invoices'),
      'cash_net': ('صافي التحصيل النقدي', 'Net cash collections'),
      'recorded_expenses': ('المصروفات المسجلة', 'Recorded expenses'),
      'bookings': ('الحجوزات', 'Bookings'),
      'completed_bookings': ('الحجوزات المكتملة', 'Completed bookings'),
      'distinct_booking_customers': ('عملاء الحجوزات', 'Booking customers'),
      'active_products': ('المنتجات النشطة', 'Active products'),
      'out_of_stock_products': ('منتجات نفدت', 'Out-of-stock products'),
      'average_review_stars': ('متوسط التقييمات', 'Average reviews'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(
            'لقطة أدلة عند إنشاء المقترح؛ ليست توقعًا أو ربحًا مؤكدًا.',
            'Evidence captured when proposed; not a forecast or confirmed profit.',
          ),
        ),
        if (metrics is List)
          ...metrics
              .whereType<Map>()
              .where((m) => names.containsKey(m['code']))
              .map((m) {
                final n = names[m['code']]!;
                return Text(
                  '${ar ? n.$1 : n.$2}: ${m['value'] ?? t('بيانات غير كافية', 'Insufficient data')} ${m['unit'] == 'EGP' ? 'EGP' : ''}',
                );
              }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        t('مقترحات المالك وسجل الموافقات', 'Owner proposals and approvals'),
      ),
    ),
    body: invalid
        ? Center(
            child: Text(
              t(
                'تغيّرت الجلسة. أعد فتح الشاشة بحساب المالك.',
                'Session changed. Reopen with the owner account.',
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  'مراجعات يدوية مجانية مستندة إلى سجلات الخادم. الموافقة لا تغيّر الأسعار أو الرواتب أو المخزون ولا تنفّذ تحويلًا ماليًا.',
                  'Free manual reviews backed by server records. Approval does not change prices, payroll or stock and never transfers money.',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: action,
                isExpanded: true,
                items: evidenceTaskActions.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          ar ? e.value.$1 : e.value.$2,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: busy || pending != null
                    ? null
                    : (value) => setState(() => action = value!),
              ),
              FilledButton(
                onPressed: busy || pending != null
                    ? null
                    : () => proposeOrReview(null, 'proposed'),
                child: Text(
                  t(
                    'حفظ مقترح مع الأدلة الحالية',
                    'Save proposal with current evidence',
                  ),
                ),
              ),
              if (error != null) Text(error!),
              if (pending != null)
                FilledButton(
                  onPressed: busy ? null : dispatch,
                  child: Text(
                    t('التحقق بإعادة نفس الطلب', 'Retry the same request'),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              TextButton(
                onPressed: busy || pending != null ? null : load,
                child: Text(t('تحديث القائمة', 'Refresh list')),
              ),
              if (rows.isEmpty && !busy)
                Text(t('لا توجد مقترحات محفوظة.', 'No saved proposals.')),
              ...rows.map((row) {
                final names = evidenceTaskActions[row['action']];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          names == null
                              ? t('مقترح مراجعة', 'Review proposal')
                              : ar
                              ? names.$1
                              : names.$2,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(label(row['state'] as String)),
                        Text(
                          '${formatDate(row['from'] as String)} — ${formatDate(row['to'] as String)}',
                        ),
                        evidence(row),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (row['state'] == 'proposed')
                              OutlinedButton(
                                onPressed: busy || pending != null
                                    ? null
                                    : () => proposeOrReview(row, 'approved'),
                                child: Text(
                                  t('موافقة على المراجعة', 'Approve review'),
                                ),
                              ),
                            if (row['state'] == 'approved')
                              OutlinedButton(
                                onPressed: busy || pending != null
                                    ? null
                                    : () => proposeOrReview(row, 'completed'),
                                child: Text(
                                  t(
                                    'تسجيل إتمام المراجعة يدويًا',
                                    'Record manual review completion',
                                  ),
                                ),
                              ),
                            if (row['state'] == 'proposed' ||
                                row['state'] == 'approved')
                              TextButton(
                                onPressed: busy || pending != null
                                    ? null
                                    : () => proposeOrReview(row, 'dismissed'),
                                child: Text(t('رفض', 'Dismiss')),
                              ),
                            TextButton(
                              onPressed: busy || pending != null
                                  ? null
                                  : () => showHistory(row),
                              child: Text(
                                t('سجل القرارات', 'Decision history'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
  );
}

class _EvidenceDecisionDialog extends StatefulWidget {
  final bool arabic;
  const _EvidenceDecisionDialog({required this.arabic});
  @override
  State<_EvidenceDecisionDialog> createState() =>
      _EvidenceDecisionDialogState();
}

class _EvidenceDecisionDialogState extends State<_EvidenceDecisionDialog> {
  final controller = TextEditingController();
  String t(String ar, String en) => widget.arabic ? ar : en;
  @override
  void initState() {
    super.initState();
    controller.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('سبب القرار', 'Decision reason')),
    content: TextField(
      controller: controller,
      maxLength: 1000,
      maxLines: 3,
      decoration: InputDecoration(
        hintText: t(
          'اكتب سببًا من ثلاثة أحرف على الأقل',
          'Enter a reason of at least three characters',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('إلغاء', 'Cancel')),
      ),
      TextButton(
        onPressed: controller.text.trim().length < 3
            ? null
            : () => Navigator.pop(context, controller.text.trim()),
        child: Text(t('تأكيد', 'Confirm')),
      ),
    ],
  );
}
