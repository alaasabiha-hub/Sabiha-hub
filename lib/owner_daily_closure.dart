import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _dailyNavy = Color(0xff071a36);
const _dailyRoyal = Color(0xff174b83);
const _dailySilver = Color(0xffc5cbd5);

abstract interface class OwnerDailyClosureGateway {
  String? get currentUserId;
  Future<String> defaultBranchId();
  Future<Map<String, dynamic>?> load(String branchId, String date);
  Future<Map<String, dynamic>> prepare(
    String requestId,
    String branchId,
    String date,
  );
  Future<Map<String, dynamic>> approve(String branchId, String date);
}

class SupabaseOwnerDailyClosureGateway implements OwnerDailyClosureGateway {
  final SupabaseClient client;
  const SupabaseOwnerDailyClosureGateway(this.client);

  @override
  String? get currentUserId => client.auth.currentUser?.id;

  @override
  Future<String> defaultBranchId() async {
    final result = await client.rpc('default_branch_id');
    if (result is! String || result.isEmpty) {
      throw StateError('No default branch');
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>?> load(String branchId, String date) async {
    final result = await client.rpc(
      'get_branch_daily_close',
      params: {'p_branch': branchId, 'p_date': date},
    );
    if (result == null) return null;
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<Map<String, dynamic>> prepare(
    String requestId,
    String branchId,
    String date,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
          'prepare_branch_daily_close',
          params: {
            'p_request': requestId,
            'p_branch': branchId,
            'p_date': date,
          },
        )
        as Map,
  );

  @override
  Future<Map<String, dynamic>> approve(String branchId, String date) async =>
      Map<String, dynamic>.from(
        await client.rpc(
              'approve_branch_daily_close',
              params: {'p_branch': branchId, 'p_date': date},
            )
            as Map,
      );
}

String _newRequestId() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class OwnerDailyClosureScreen extends StatefulWidget {
  final OwnerDailyClosureGateway gateway;
  final String role;
  const OwnerDailyClosureScreen({
    super.key,
    required this.gateway,
    required this.role,
  });

  @override
  State<OwnerDailyClosureScreen> createState() =>
      _OwnerDailyClosureScreenState();
}

class _OwnerDailyClosureScreenState extends State<OwnerDailyClosureScreen> {
  late DateTime selectedDate;
  late String prepareRequestId;
  String? branchId, error;
  Map<String, dynamic>? close;
  bool loading = true, busy = false;

  bool get arabic => Localizations.localeOf(context).languageCode == 'ar';
  String tr(String ar, String en) => arabic ? ar : en;
  String get dateKey =>
      '${selectedDate.year.toString().padLeft(4, '0')}-'
      '${selectedDate.month.toString().padLeft(2, '0')}-'
      '${selectedDate.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    selectedDate = DateTime(now.year, now.month, now.day - 1);
    prepareRequestId = _newRequestId();
    load();
  }

  Future<void> load() async {
    if (widget.role != 'owner') {
      setState(() {
        loading = false;
        error = 'owner-only';
      });
      return;
    }
    final actor = widget.gateway.currentUserId;
    if (actor == null) {
      setState(() {
        loading = false;
        error = 'session-ended';
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final branch = branchId ?? await widget.gateway.defaultBranchId();
      final result = await widget.gateway.load(branch, dateKey);
      if (!mounted || widget.gateway.currentUserId != actor) {
        return;
      }
      setState(() {
        branchId = branch;
        close = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'load-failed';
      });
    }
  }

  Future<void> chooseDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: today.subtract(const Duration(days: 1)),
      helpText: tr('اختر يوم العمل', 'Select business day'),
    );
    if (selected == null || !mounted) return;
    setState(() {
      selectedDate = DateTime(selected.year, selected.month, selected.day);
      prepareRequestId = _newRequestId();
      close = null;
    });
    await load();
  }

  Future<void> prepareClose() => _perform(() async {
    if (branchId == null) throw StateError('Branch unavailable');
    close = await widget.gateway.prepare(
      prepareRequestId,
      branchId!,
      dateKey,
    );
  });

  Future<void> approveClose() => _perform(() async {
    if (branchId == null) throw StateError('Branch unavailable');
    close = await widget.gateway.approve(branchId!, dateKey);
  });

  Future<void> _perform(Future<void> Function() action) async {
    if (busy || widget.role != 'owner') return;
    final actor = widget.gateway.currentUserId;
    if (actor == null) {
      setState(() => error = 'session-ended');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (widget.gateway.currentUserId != actor) {
        setState(() {
          close = null;
          error = 'session-ended';
        });
        return;
      }
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => error = 'action-failed');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String money(dynamic value) {
    final amount = num.tryParse('$value');
    return amount == null ? '—' : '${amount.toStringAsFixed(2)} EGP';
  }

  Map<String, dynamic> _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  List<Map<String, dynamic>> _list(dynamic value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    final snapshot = _map(close?['snapshot']);
    final report = _map(snapshot['report']);
    final payments = _map(snapshot['payment_activity']);
    final expenses = _map(snapshot['expenses']);
    final shifts = _list(snapshot['shift_reconciliation']);
    final corrections = _list(close?['corrections']);
    final status = close?['status'] as String?;
    return Scaffold(
      backgroundColor: const Color(0xfff5f7fa),
      appBar: AppBar(
        backgroundColor: _dailyNavy,
        foregroundColor: Colors.white,
        title: Text(tr('تقفيل يوم العمل', 'Business day close')),
        actions: [
          IconButton(
            tooltip: tr('تحديث', 'Refresh'),
            onPressed: loading || busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error == 'owner-only'
          ? Center(
              child: Text(
                tr('هذه الشاشة متاحة للمالك فقط.', 'Owner access only.'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _datePanel(),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  _notice(_errorText()),
                ],
                const SizedBox(height: 16),
                if (close == null)
                  Card(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(
                              'لا يوجد تقفيل محفوظ لهذا اليوم.',
                              'No close snapshot exists for this day.',
                            ),
                            style: const TextStyle(
                              color: _dailyNavy,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(
                              'سيجمع النظام الفواتير وحركات التحصيل ومصروفات اليوم بعد اعتماد جميع الورديات. لا تُقدّر الأرباح عند نقص بيانات التكلفة.',
                              'The system snapshots invoices, payment events, and expenses after every shift is approved. Profit remains unknown when cost data is incomplete.',
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            key: const ValueKey('prepare-daily-close'),
                            onPressed: busy ? null : prepareClose,
                            style: FilledButton.styleFrom(
                              backgroundColor: _dailyRoyal,
                            ),
                            icon: const Icon(Icons.lock_clock),
                            label: Text(
                              tr('إعداد لقطة التقفيل', 'Prepare close snapshot'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  _statusCard(status),
                  const SizedBox(height: 12),
                  _section(
                    tr('ملخص المبيعات والفواتير', 'Sales and invoice summary'),
                    [
                      _value(tr('عدد الفواتير', 'Invoices'), report['invoice_count']),
                      _value(tr('قبل الخصم', 'Before discounts'), money(report['billed_before_discount'])),
                      _value(tr('إجمالي الفواتير', 'Net billed'), money(report['net_billed'])),
                      _value(tr('الخصومات', 'Discounts'), money(report['discounts'])),
                      _value(tr('الضرائب المسجلة', 'Recorded taxes'), money(report['taxes'])),
                      _value(tr('صافي المبيعات قبل الضريبة', 'Net sales before tax'), money(report['net_sales_ex_tax'])),
                      _value(tr('عمولات الموظفين المسجلة', 'Recorded staff commissions'), money(report['commissions'])),
                      _value(tr('غير المحصل المسجل', 'Recorded uncollected'), money(report['uncollected_recorded'])),
                      _value(tr('الربح الفعلي', 'Actual profit'), report['actual_profit'] == null ? tr('غير متاح: بيانات التكلفة غير مكتملة', 'Unavailable: cost data is incomplete') : money(report['actual_profit'])),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _hourlySection(_list(report['hourly'])),
                  const SizedBox(height: 12),
                  _section(
                    tr('التحصيل والاستردادات', 'Collections and refunds'),
                    [
                      _value(tr('نقدي محصل', 'Cash collected'), money(payments['cash_collected'])),
                      _value(tr('بطاقة/إلكتروني محصل', 'Card/electronic collected'), money(payments['card_collected'])),
                      _value(tr('نقدي مسترد', 'Cash refunded'), money(payments['cash_refunded'])),
                      _value(tr('بطاقة/إلكتروني مسترد', 'Card/electronic refunded'), money(payments['card_refunded'])),
                      _value(tr('عدد حركات التحصيل', 'Payment events'), '${payments['event_count'] ?? 0}'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _section(
                    tr('الورديات وفروق الصندوق', 'Shifts and cash differences'),
                    shifts.isEmpty
                        ? [Text(tr('لا توجد ورديات مغلقة في هذا اليوم.', 'No shifts closed on this day.'))]
                        : shifts.map((shift) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.point_of_sale, color: _dailyRoyal),
                            title: Text('${shift['cashier_id'] ?? ''}'),
                            subtitle: Text(tr('الفرق: ${money(shift['difference'])} · السبب: ${shift['difference_reason'] ?? '—'}', 'Difference: ${money(shift['difference'])} · Reason: ${shift['difference_reason'] ?? '—'}')),
                            trailing: Text(money(shift['actual_cash'])),
                          )).toList(),
                  ),
                  const SizedBox(height: 12),
                  _section(
                    tr('المصروفات', 'Expenses'),
                    [
                      _value(tr('الإجمالي', 'Total'), money(expenses['total'])),
                      for (final item in _list(expenses['by_category']))
                        _value('${item['category'] ?? ''}', money(item['amount'])),
                    ],
                  ),
                  if (corrections.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _section(
                      tr('سجل التصحيحات الإلحاقي', 'Append-only correction log'),
                      corrections.map((item) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${item['reason'] ?? ''}'),
                        subtitle: Text('${item['created_at'] ?? ''} · ${item['actor_id'] ?? ''}'),
                      )).toList(),
                    ),
                  ],
                  if (status == 'awaiting_approval') ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const ValueKey('approve-daily-close'),
                      onPressed: busy ? null : approveClose,
                      style: FilledButton.styleFrom(backgroundColor: _dailyRoyal),
                      icon: const Icon(Icons.verified_outlined),
                      label: Text(tr('اعتماد التقفيل بصفتي المالك', 'Approve close as owner')),
                    ),
                  ],
                ],
                if (busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(color: _dailyRoyal),
                ],
              ],
            ),
    );
  }

  Widget _datePanel() => Card(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            tr('تاريخ العمل', 'Business date'),
            style: const TextStyle(fontWeight: FontWeight.bold, color: _dailyNavy),
          ),
          OutlinedButton.icon(
            key: const ValueKey('daily-close-date'),
            onPressed: busy ? null : chooseDate,
            icon: const Icon(Icons.calendar_month),
            label: Text(MaterialLocalizations.of(context).formatMediumDate(selectedDate)),
          ),
          Text(dateKey, textDirection: TextDirection.ltr),
        ],
      ),
    ),
  );

  Widget _statusCard(String? status) {
    final approved = status == 'approved';
    return Card(
      color: approved ? const Color(0xffe9f4ed) : const Color(0xfffff7e6),
      child: ListTile(
        leading: Icon(approved ? Icons.verified : Icons.pending_actions, color: approved ? Colors.green.shade800 : _dailyRoyal),
        title: Text(approved ? tr('معتمد من المالك', 'Approved by owner') : tr('بانتظار اعتماد المالك', 'Awaiting owner approval')),
        subtitle: Text(tr('أُعد: ${close?['prepared_at'] ?? '—'}', 'Prepared: ${close?['prepared_at'] ?? '—'}')),
        trailing: approved ? const Icon(Icons.lock, color: _dailyNavy) : null,
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: _dailyNavy, fontWeight: FontWeight.w800, fontSize: 17)),
          const Divider(color: _dailySilver),
          ...children,
        ],
      ),
    ),
  );

  Widget _hourlySection(List<Map<String, dynamic>> hourly) => Card(
    color: Colors.white,
    child: ExpansionTile(
      key: const ValueKey('daily-close-hourly'),
      iconColor: _dailyRoyal,
      collapsedIconColor: _dailyRoyal,
      title: Text(
        tr('تفصيل الساعة', 'Hourly detail'),
        style: const TextStyle(color: _dailyNavy, fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        tr('الفواتير حسب الإصدار، والزيارات المكتملة حسب حدث الإكمال الموثق.', 'Invoices by issue time; completed visits by verified service-end event.'),
      ),
      children: hourly.isEmpty
          ? [Padding(padding: const EdgeInsets.all(16), child: Text(tr('لا تتوفر تفاصيل ساعة لهذا اليوم.', 'No hourly detail is available for this day.')))]
          : hourly.map((item) => ListTile(
              dense: true,
              title: Text('${(item['hour'] as num?)?.toInt().toString().padLeft(2, '0') ?? '—'}:00'),
              subtitle: Text(tr('زيارات مكتملة موثقة: ${item['completed_service_visits'] ?? 0}', 'Verified completed visits: ${item['completed_service_visits'] ?? 0}')),
              trailing: Text(money(item['net_billed'])),
            )).toList(),
    ),
  );

  Widget _value(String label, dynamic value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text('$value', textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
      ],
    ),
  );

  Widget _notice(String message) => Card(
    color: const Color(0xfffff4e8),
    child: Padding(padding: const EdgeInsets.all(14), child: Text(message)),
  );

  String _errorText() => switch (error) {
    'session-ended' => tr('انتهت جلسة الدخول؛ أعد فتح الشاشة.', 'Your session ended. Reopen this screen.'),
    'action-failed' => tr('تعذر تنفيذ الإجراء. تحقق من اعتماد الورديات وصلاحية المالك ثم أعد المحاولة.', 'Action failed. Check shift approvals and owner access, then retry.'),
    'owner-only' => tr('هذه الشاشة متاحة للمالك فقط.', 'Owner access only.'),
    _ => tr('تعذر تحميل تقفيل اليوم أو بيانات الفرع.', 'Could not load daily close or branch data.'),
  };
}
