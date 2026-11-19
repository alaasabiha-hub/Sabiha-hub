import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hr_payroll.dart' show hrRequestId;
import 'invoice_presentation.dart' show invoiceDate;

abstract class VisitLifecycleGateway {
  Future<Map<String, dynamic>> ownerContext(String? branch);
  Future<void> activate(String request, String policy);
}

class SupabaseVisitLifecycleGateway implements VisitLifecycleGateway {
  SupabaseVisitLifecycleGateway(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> ownerContext(String? branch) async =>
      Map<String, dynamic>.from(
        await client.rpc(
          'get_loyalty_visit_lifecycle',
          params: {'p_branch': branch},
        ) as Map,
      );
  @override
  Future<void> activate(String request, String policy) async {
    await client.rpc(
      'activate_loyalty_visits',
      params: {'p_request': request, 'p_policy_version': policy},
    );
  }
}

/// Separate from legacy points and redemption. All eligibility stays server-side.
class OwnerVisitLifecyclePanel extends StatefulWidget {
  const OwnerVisitLifecyclePanel({
    super.key,
    required this.gateway,
    this.branch,
  });
  final VisitLifecycleGateway gateway;
  final String? branch;
  @override
  State<OwnerVisitLifecyclePanel> createState() =>
      _OwnerVisitLifecyclePanelState();
}

class _OwnerVisitLifecyclePanelState extends State<OwnerVisitLifecyclePanel> {
  Map<String, dynamic>? data;
  bool busy = false;
  String? error, request, requestedPolicy;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant OwnerVisitLifecyclePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branch != widget.branch) {
      data = null;
      request = requestedPolicy = null;
      load();
    }
  }

  Future<void> load() async {
    final branch = widget.branch;
    try {
      final result = await widget.gateway.ownerContext(branch);
      if (mounted && widget.branch == branch) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted && widget.branch == branch) {
        setState(
          () => error = t(
            'تعذر التحقق من احتساب الزيارات.',
            'Unable to verify service-visit earning.',
          ),
        );
      }
    }
  }

  Future<void> _activateVisits() async {
    final policy = data?['policy_version_id'] as String?;
    if (policy == null || busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          t(
            'تفعيل احتساب الزيارات المستقبلية',
            'Activate future visit earning',
          ),
        ),
        content: Text(
          t(
            'يشمل الحجوزات الجديدة بعد التفعيل فقط، بعد اكتمال الخدمة والتحصيل النقدي المؤكد. الاسترداد يعكس الزيارة. لا يستبدل نقاطًا ولا يعدّل فاتورة قائمة.',
            'Only new bookings after activation qualify, after completed service and confirmed cash collection. Refunds reverse the visit. This does not redeem points or change issued invoices.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(
              t('تفعيل للمستقبل فقط', 'Activate for future bookings'),
            ),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    if (requestedPolicy != policy) {
      requestedPolicy = policy;
      request = hrRequestId();
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.activate(request!, policy);
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'لم يتأكد التفعيل. حدّث الحالة أو أعد نفس الطلب.',
            'Activation is unconfirmed. Refresh the status or retry the same request.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String count(String key) =>
      data?[key] is num ? '${data![key]}' : t('غير متاح', 'Unavailable');
  @override
  Widget build(BuildContext context) {
    final activation = data?['activation'] as Map?;
    final ready =
        data?['scheduler_ready'] == true &&
        data?['actual_cron_run_observed'] == true;
    final canActivate =
        error == null &&
        ready &&
        data?['current_policy_enabled'] == true &&
        data?['policy_version_id'] != null &&
        activation == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('احتساب زيارات الخدمات', 'Service-visit earning'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (data == null && error == null) const LinearProgressIndicator(),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (data != null) ...[
              Text(
                ready
                    ? t(
                        'رُصد تشغيل ناجح للمعالج المجدول.',
                        'A successful scheduled worker run was observed.',
                      )
                    : t(
                        'الاحتساب غير جاهز للتفعيل حتى يُتحقق من تشغيل المعالج المجدول.',
                        'Earning cannot be activated until the scheduled worker is verified.',
                      ),
              ),
              if (activation != null)
                Text(
                  '${t('تاريخ بدء الأهلية', 'Eligibility starts')}: ${invoiceDate({'issued_at': activation['activated_at']}, ar)}',
                ),
              Text(
                '${t('زيارات مكتسبة', 'Earned visits')}: ${count('earned_visits')} · ${t('معكوسة باسترداد', 'Refund reversals')}: ${count('reversed_visits')}',
              ),
              Text(
                '${t('صافي الزيارات', 'Net visits')}: ${count('net_visits')} · ${t('أحداث قيد المعالجة', 'Pending events')}: ${count('pending_events')}',
              ),
              Text(
                t(
                  'الاستبدال غير مفعّل. الزيارات منفصلة عن رصيد النقاط القديم ولا تُحوّل إلى أموال.',
                  'Redemption is disabled. Visits remain separate from legacy points and cannot be converted into money.',
                ),
              ),
              if (activation == null)
                FilledButton(
                  onPressed: canActivate && !busy ? _activateVisits : null,
                  child: Text(
                    t(
                      'تفعيل احتساب الإصدار المحفوظ',
                      'Activate saved policy earning',
                    ),
                  ),
                ),
            ],
            TextButton(
              onPressed: busy ? null : load,
              child: Text(t('تحديث الحالة', 'Refresh status')),
            ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

/// Own-account server summary; never substituted for the existing points balance.
class CanonicalServiceVisitsCard extends StatelessWidget {
  const CanonicalServiceVisitsCard({super.key, required this.summary});
  final Map<String, dynamic>? summary;
  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    String t(String a, String e) => ar ? a : e;
    final visits = summary?['net_visits'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('زيارات الخدمات المؤهلة', 'Eligible service visits'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              visits is num
                  ? '$visits'
                  : t('غير متاح حاليًا', 'Currently unavailable'),
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            Text(
              t(
                'إجمالي الزيارات المكتسبة ناقص الزيارات المعكوسة بالاسترداد عبر التاريخ؛ ليس رصيداً متاحاً للاستبدال ولا يدمج بالنقاط القديمة.',
                'Lifetime earned visits minus refunded visits; this is not an available redemption balance and is separate from legacy points.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
