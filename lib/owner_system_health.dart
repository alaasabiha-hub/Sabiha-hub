import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;

abstract class OwnerSystemHealthGateway {
  Future<Map<String, dynamic>> read(String? branchId);
}

class SupabaseOwnerSystemHealthGateway implements OwnerSystemHealthGateway {
  SupabaseOwnerSystemHealthGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  @override
  Future<Map<String, dynamic>> read(String? branchId) async {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return Map<String, dynamic>.from(
      await client.rpc(
        'get_owner_system_health',
        params: {'p_branch': branchId},
      ) as Map,
    );
  }
}

class OwnerSystemHealthScreen extends StatefulWidget {
  const OwnerSystemHealthScreen({
    super.key,
    required this.client,
    this.branchId,
    this.gateway,
  });
  final SupabaseClient client;
  final String? branchId;
  final OwnerSystemHealthGateway? gateway;
  @override
  State<OwnerSystemHealthScreen> createState() =>
      _OwnerSystemHealthScreenState();
}

class _OwnerSystemHealthScreenState extends State<OwnerSystemHealthScreen> {
  late OwnerSystemHealthGateway gateway;
  StreamSubscription<AuthState>? subscription;
  Map<String, dynamic>? evidence;
  bool busy = false, identityChanged = false;
  String? error;
  int epoch = 0;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    gateway = widget.gateway ?? SupabaseOwnerSystemHealthGateway(widget.client);
    final initial = widget.client.auth.currentSession;
    var first = true;
    subscription = widget.client.auth.onAuthStateChange.listen((event) {
      final same = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (same) return;
      if (event.event != AuthChangeEvent.initialSession) {
        epoch++;
        if (mounted) {
          setState(() {
            evidence = null;
            busy = false;
            identityChanged = true;
            error = 'identity';
          });
        }
      }
    });
    load();
  }

  @override
  void didUpdateWidget(covariant OwnerSystemHealthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      epoch++;
      evidence = null;
      busy = false;
      identityChanged = true;
      error = 'identity';
      return;
    }
    if (oldWidget.branchId != widget.branchId ||
        oldWidget.gateway != widget.gateway) {
      epoch++;
      evidence = null;
      gateway =
          widget.gateway ?? SupabaseOwnerSystemHealthGateway(widget.client);
      load();
    }
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (identityChanged) return;
    final generation = ++epoch, actor = widget.client.auth.currentUser?.id;
    setState(() {
      evidence = null;
      busy = true;
      error = null;
    });
    try {
      final value = await gateway.read(widget.branchId);
      if (!mounted ||
          generation != epoch ||
          widget.client.auth.currentUser?.id != actor) {
        return;
      }
      final worker = value['background_worker'];
      final probe = value['database_probe'];
      if (DateTime.tryParse(value['checked_at']?.toString() ?? '') == null ||
          worker is! Map ||
          probe is! Map ||
          worker['source'] != 'canonical_loyalty_cron_and_outbox' ||
          worker['scope'] != 'execution_observation_only' ||
          !const [
            'working',
            'failed',
            'not_checked',
          ].contains(worker['state']) ||
          probe['scope'] != 'this_request_only' ||
          probe['source'] != 'authenticated_database_round_trip' ||
          probe['state'] != 'working' ||
          worker['checked_at'] != value['checked_at'] ||
          value['other_checks'] is! Map) {
        throw StateError('Unverified response');
      }
      final other = Map<String, dynamic>.from(value['other_checks'] as Map);
      if (other.values.any(
        (check) => check is! Map || check['state'] != 'not_checked',
      )) {
        throw StateError('Unsupported independent evidence');
      }
      setState(() => evidence = value);
    } catch (_) {
      if (mounted &&
          generation == epoch &&
          widget.client.auth.currentUser?.id == actor) {
        setState(() {
          evidence = null;
          error = 'unavailable';
        });
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  String status(dynamic state) => state == 'working'
      ? t('لوحظ التنفيذ', 'Execution observed')
      : state == 'failed'
      ? t('لوحظ تعثر يحتاج مراجعة', 'Observed failure needs review')
      : t('لم يتم التحقق', 'Not checked');
  String reason(dynamic value) {
    return switch (value) {
      'scheduler_not_configured' => t(
        'المجدول غير مهيأ لهذا الفحص',
        'Scheduler is not configured for this check',
      ),
      'observed_failed_run' => t(
        'سُجل تشغيل فاشل بعد آخر نجاح',
        'A failed run was recorded after the last success',
      ),
      'pending_failed_attempts' => t(
        'توجد محاولات متعثرة تنتظر المراجعة أو إعادة المحاولة',
        'Recorded failed attempts await review or retry',
      ),
      'no_success_observed' => t(
        'لم يُرصد نجاح فعلي',
        'No actual success has been observed',
      ),
      'success_observation_stale' => t(
        'رصد النجاح أقدم من نافذة التحقق',
        'Observed success is older than the verification window',
      ),
      'unresolved_queue_scope' => t(
        'توجد أحداث لا يمكن تحديد نطاقها',
        'Some queued events have unresolved scope',
      ),
      'recent_execution_observed' => t(
        'لوحظ تشغيل فعلي حديث',
        'Recent actual execution was observed',
      ),
      _ => t(
        'الأدلة غير كافية للتحقق',
        'Evidence is insufficient for verification',
      ),
    };
  }

  Widget field(String label, dynamic value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Text('$label: ${value ?? t('غير متاح', 'Unavailable')}'),
  );
  Widget section(String title, List<Widget> children) => Card(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xff174b83),
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
  Widget observed() {
    final worker = Map<String, dynamic>.from(
          evidence!['background_worker'] as Map,
        ),
        other = Map<String, dynamic>.from(evidence!['other_checks'] as Map);
    final names = <String, String>{
      'booking_success': t('نجاح الحجوزات', 'Booking success'),
      'invoice_success': t('نجاح الفواتير', 'Invoice success'),
      'payments_and_integrations': t(
        'المدفوعات والتكاملات',
        'Payments and integrations',
      ),
      'device_sync': t('مزامنة الأجهزة', 'Device sync'),
      'in_app_notifications': t('إشعارات التطبيق', 'In-app notifications'),
      'pdf_generation': t('ملفات PDF', 'PDF generation'),
      'backup_restore': t('النسخ والاستعادة', 'Backup and restore'),
      'global_security': t('الأمان الشامل', 'Global security'),
      'financial_correctness': t('الدقة المالية', 'Financial correctness'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(
          t('وقت الفحص من الخادم', 'Server checked at'),
          evidence!['checked_at'],
        ),
        section(t('اتصال قاعدة البيانات', 'Database connection'), [
          Text(
            t(
              'نجحت هذه الاستجابة المصرح بها فقط؛ ليست ضماناً للاستمرارية.',
              'This authorized response succeeded; it is not an uptime guarantee.',
            ),
          ),
          field(
            t('المصدر', 'Source'),
            t('استجابة قاعدة البيانات الحالية', 'Current database round trip'),
          ),
        ]),
        section(t('عامل الزيارات في الخلفية', 'Background visit worker'), [
          Text(status(worker['state']), key: const ValueKey('worker_state')),
          Text(reason(worker['reason'])),
          field(
            t('المصدر', 'Source'),
            t(
              'مجدول الزيارات والطابور الفعلي',
              'Actual visit scheduler and queue',
            ),
          ),
          field(
            t('نطاق الدليل', 'Evidence scope'),
            t('رصد التنفيذ فقط', 'Observed execution only'),
          ),
          field(
            t('آخر تشغيل ناجح', 'Last successful run'),
            worker['last_success_at'],
          ),
          field(
            t('عمر رصد النجاح بالثواني', 'Observed success age in seconds'),
            worker['success_age_seconds'],
          ),
          field(
            t('آخر تشغيل فاشل', 'Last failed run'),
            worker['last_failed_run_at'],
          ),
          field(t('أحداث معلقة', 'Pending events'), worker['pending_events']),
          field(t('جاهزة للمحاولة', 'Due events'), worker['due_events']),
          field(
            t('أحداث أعيدت محاولتها', 'Retried events'),
            worker['retrying_events'],
          ),
          field(
            t('محاولات متعثرة معلقة', 'Pending failed attempts'),
            worker['pending_failed_attempts'],
          ),
          field(
            t(
              'أحداث بنطاق مجهول لكل الفروع',
              'Unresolved events across all branches',
            ),
            worker['unresolved_pending_events'],
          ),
          Text(
            t(
              'هذا لا يثبت صحة الحسابات أو جميع مهام النظام.',
              'This does not prove financial correctness or all system tasks.',
            ),
          ),
        ]),
        section(t('فحوص مستقلة', 'Independent checks'), [
          for (final entry in names.entries)
            field(
              entry.value,
              status(
                (other[entry.key] is Map) ? other[entry.key]['state'] : null,
              ),
            ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f6f8),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(t('حالة النظام', 'System health')),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              t(
                'نعرض ما تم فحصه فعلياً؛ غياب الأخطاء ليس دليلاً على السلامة.',
                'Only actual observations are shown; no error reports does not prove health.',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('health_refresh'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff174b83),
                ),
                onPressed: busy || identityChanged ? null : load,
                child: Text(t('تحديث الفحص', 'Refresh check')),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error == 'identity'
                    ? t(
                        'تغيرت الجلسة. أعد فتح الشاشة بحساب المالك.',
                        'Session changed. Reopen with the owner account.',
                      )
                    : t(
                        'تعذر التحقق الآن. لا توجد نتيجة حالية مؤكدة.',
                        'Unable to check now. No current result is confirmed.',
                      ),
                key: const ValueKey('health_error'),
              ),
            if (evidence != null) observed(),
          ],
        ),
      ),
    ),
  );
}
