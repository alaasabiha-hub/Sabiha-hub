import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hr_payroll.dart' show hrRequestId;
import 'invoice_presentation.dart' show invoiceDate;

class OwnerRewardReviewPanel extends StatefulWidget {
  const OwnerRewardReviewPanel({
    super.key,
    required this.client,
    required this.branch,
  });
  final SupabaseClient client;
  final String? branch;
  @override
  State<OwnerRewardReviewPanel> createState() => _ReviewState();
}

class _ReviewState extends State<OwnerRewardReviewPanel> {
  List<Map<String, dynamic>>? rows;
  bool busy = false;
  String? error;
  final requests = <String, String>{};
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  Future<void> load() async {
    setState(() => busy = true);
    try {
      final result = await widget.client.rpc(
        'list_reward_refund_reviews',
        params: {'p_branch': widget.branch},
      );
      if (mounted) {
        setState(() {
          rows = (result as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList();
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'تعذر تحميل مراجعات الاسترداد المصرح بها.',
            'Unable to load authorized refund reviews.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> acknowledge(Map row) async {
    final note = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('إقرار مراجعة الاسترداد', 'Acknowledge refund review')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(
                'هذا إقرار مراجعة فقط: لا يُعفي من أثر الاسترداد ولا يُنشئ زيارات ولا يفرض مالاً بأثر رجعي.',
                'This acknowledges review only: no debt waiver, new visits or retroactive money charge.',
              ),
            ),
            TextField(
              controller: note,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: t('ملاحظة تدقيق صريحة', 'Explicit audit note'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('إقرار دون إعفاء', 'Acknowledge without waiver')),
          ),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (accepted != true || text.length < 2 || !mounted) return;
    final signature = '${row['review_id']}:$text';
    final request = requests.putIfAbsent(signature, hrRequestId);
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'resolve_reward_refund_review',
        params: {
          'p_request': request,
          'p_review': row['review_id'],
          'p_note': text,
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'الإقرار غير مؤكد. أعد المحاولة بنفس الملاحظة أو حدّث الحالة.',
            'Acknowledgment is unconfirmed. Retry with the same note or refresh status.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      title: Text(
        t('مراجعات أثر استرداد الزيارات', 'Visit refund-effect reviews'),
      ),
      onExpansionChanged: (open) {
        if (open && rows == null && !busy) load();
      },
      childrenPadding: const EdgeInsets.all(16),
      children: [
        Text(
          t(
            'الإقرار لا يمحو الالتزام. تبقى تسوية الأثر من الزيارات المستقبلية المؤهلة وفق الشروط المحفوظة.',
            'Acknowledgment does not waive the obligation. Eligible future visits offset it according to the frozen terms.',
          ),
        ),
        if (error != null) Text(error!),
        if (busy) const LinearProgressIndicator(),
        if (rows != null && rows!.isEmpty)
          Text(
            t(
              'لا توجد مراجعات فعلية في هذا النطاق.',
              'No actual reviews exist in this scope.',
            ),
          ),
        for (final row in rows ?? <Map<String, dynamic>>[])
          ListTile(
            title: Text(
              '${t('مرجع مراجعة فعلي', 'Actual review reference')}: ${row['booking_number'] ?? row['invoice_number'] ?? row['review_id']}',
            ),
            subtitle: Text(
              '${row['mode'] == 'freeze_for_owner_review' ? t('تجميد للمراجعة', 'Frozen for review') : t('خصم الأثر من الزيارات المستقبلية', 'Offset against future visits')}\n${row['debt_outstanding'] == true ? t('ما زال أثر الاسترداد قائماً', 'Refund obligation remains outstanding') : t('لا يوجد أثر مستحق وفق الخادم', 'No outstanding obligation according to the server')}\n${row['acknowledged_at'] == null ? t('لم يُقر بعد', 'Not acknowledged') : invoiceDate({'issued_at': row['acknowledged_at']}, ar)}',
            ),
            trailing: row['acknowledged_at'] == null
                ? TextButton(
                    onPressed: busy ? null : () => acknowledge(row),
                    child: Text(t('مراجعة', 'Review')),
                  )
                : null,
          ),
        TextButton(
          onPressed: busy ? null : load,
          child: Text(t('تحديث المراجعات', 'Refresh reviews')),
        ),
      ],
    ),
  );
}
