import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class HrGateway {
  Future<Map<String, dynamic>> action(String action, Map<String, dynamic> data);
}

class SupabaseHrGateway implements HrGateway {
  SupabaseHrGateway(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async => Map<String, dynamic>.from(
    await client.rpc('hr_action', params: {'p_action': action, 'p_data': data})
        as Map,
  );
}

String hrCommissionExplanation(Map line, {required bool arabic}) {
  if (line['model'] == 'owner_service_policy') {
    final base = line['before_discount'];
    final share = line['allocation_share_percent'];
    final amount = line['commission'];
    final version = line['service_policy_version'];
    return arabic
        ? 'توزيع عمولة الخدمة المجمد (إصدار $version) · أساس قبل الخصم دون الضريبة: $base · حصة العامل: $share% · المستحق: $amount EGP'
        : 'Frozen service commission allocation (version $version) · Pretax, pre-discount base: $base · Worker share: $share% · Earned: $amount EGP';
  }
  return '${line['before_discount']} × ${line['rate_percent']}% ÷ ${line['assigned_count']} = ${line['commission']}';
}

String hrRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class HrPayrollScreen extends StatefulWidget {
  const HrPayrollScreen({
    super.key,
    required this.client,
    this.owner = false,
    this.gateway,
  });
  final SupabaseClient client;
  final bool owner;
  final HrGateway? gateway;
  @override
  State<HrPayrollScreen> createState() => _HrPayrollScreenState();
}

class _HrPayrollScreenState extends State<HrPayrollScreen> {
  late final HrGateway api = widget.gateway ?? SupabaseHrGateway(widget.client);
  Map<String, dynamic>? data;
  String? staffId;
  String? error;
  bool busy = false;
  String? pendingSignature;
  String? pendingRequest;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String tr(String en, String arabic) => ar ? arabic : en;
  String label(String value) => tr(
    value,
    {
          'pending': 'بانتظار الموافقة',
          'approved': 'موافق عليه',
          'rejected': 'مرفوض',
          'bonus': 'مكافأة',
          'deduction': 'خصم',
          'advance': 'سلفة',
        }[value] ??
        value,
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await api.action('read', {
        if (staffId != null) 'staff_id': staffId,
      });
      if (mounted) {
        setState(() {
          data = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _act(String action, Map<String, dynamic> payload) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final inputs = {if (staffId != null) 'staff_id': staffId, ...payload};
      final signature = '$action:${jsonEncode(inputs)}';
      if (pendingSignature != signature) {
        pendingSignature = signature;
        pendingRequest = hrRequestId();
      }
      await api.action(action, {'request_id': pendingRequest, ...inputs});
      pendingSignature = null;
      pendingRequest = null;
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  List<Map<String, dynamic>> rows(String key) => ((data?[key] as List?) ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  Future<void> _form(
    String title,
    String action,
    List<(String, String)> fields, {
    Map<String, dynamic> defaults = const {},
    Map<String, dynamic> fixed = const {},
  }) async {
    final controllers = {
      for (final field in fields)
        field.$1: TextEditingController(
          text: defaults[field.$1]?.toString() ?? '',
        ),
    };
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: TextField(
                      controller: controllers[field.$1],
                      decoration: InputDecoration(
                        labelText: field.$2,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancel', 'إلغاء')),
          ),
          FilledButton(
            onPressed: () {
              if (controllers.entries.any(
                (e) => e.key != 'ends_on' && e.value.text.trim().isEmpty,
              )) {
                return;
              }
              Navigator.pop(ctx, {
                for (final entry in controllers.entries)
                  entry.key: entry.value.text.trim().isEmpty
                      ? null
                      : entry.value.text.trim(),
              });
            },
            child: Text(tr('Save', 'حفظ')),
          ),
        ],
      ),
    );
    // Controllers remain alive until the closing dialog animation has finished.
    if (result != null && mounted) await _act(action, {...fixed, ...result});
  }

  Widget _button(String label, VoidCallback onPressed) => FilledButton.tonal(
    onPressed: busy ? null : onPressed,
    child: Text(label),
  );
  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final employment = data?['employment'] as Map?;
    final attendance = rows('attendance');
    final own =
        staffId == null || staffId == widget.client.auth.currentUser?.id;
    return Scaffold(
      backgroundColor: const Color(0xffeef1f6),
      appBar: AppBar(
        backgroundColor: const Color(0xff102342),
        foregroundColor: Colors.white,
        title: Text(tr('Staff & payroll', 'الموظفون والرواتب')),
        actions: [
          IconButton(
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: data == null && error == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (error != null)
                      Card(
                        color: Colors.red.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(error!, key: const Key('hr-error')),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(),
                    if (widget.owner)
                      _section(tr('Employee', 'الموظف'), [
                        DropdownButtonFormField<String>(
                          initialValue: staffId,
                          isExpanded: true,
                          hint: Text(tr('My records', 'سجلاتي')),
                          items: [
                            for (final s in rows('staff'))
                              DropdownMenuItem(
                                value: s['user_id'] as String,
                                child: Text(s['full_name'] as String),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) {
                                  setState(() {
                                    staffId = v;
                                    data = null;
                                  });
                                  _load();
                                },
                        ),
                      ]),
                    _section(tr('Employment', 'بيانات التوظيف'), [
                      Text(
                        employment == null
                            ? tr(
                                'No compensation configured. Payroll is blocked.',
                                'لم يتم تحديد الأجر. حساب الراتب غير متاح.',
                              )
                            : '${tr('Base salary', 'الراتب الأساسي')}: ${employment['salary']} ${employment['currency']} • ${tr('Commission', 'العمولة')}: ${employment['commission_percent']}%\n${employment['starts_on']} — ${employment['ends_on'] ?? ''}',
                      ),
                      if (widget.owner)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _button(
                            tr('Configure employment', 'تحديد الأجر والتوظيف'),
                            () => _form(
                              tr('Employment terms', 'شروط التوظيف'),
                              'employment',
                              [
                                (
                                  'salary',
                                  tr(
                                    'Base per payroll period',
                                    'الراتب الأساسي لكل فترة',
                                  ),
                                ),
                                (
                                  'commission_percent',
                                  tr(
                                    'Service commission % (split across assigned staff)',
                                    'نسبة عمولة الخدمة (تقسم على الموظفين المكلفين)',
                                  ),
                                ),
                                (
                                  'currency',
                                  tr('Currency: EGP', 'العملة: EGP'),
                                ),
                                (
                                  'starts_on',
                                  tr(
                                    'Employment start YYYY-MM-DD',
                                    'بداية التوظيف YYYY-MM-DD',
                                  ),
                                ),
                                (
                                  'ends_on',
                                  tr(
                                    'Employment end YYYY-MM-DD (optional)',
                                    'نهاية التوظيف YYYY-MM-DD (اختياري)',
                                  ),
                                ),
                              ],
                              defaults: employment == null
                                  ? {}
                                  : Map<String, dynamic>.from(employment),
                            ),
                          ),
                        ),
                    ]),
                    _section(tr('Attendance · UTC', 'الحضور · UTC'), [
                      if (own)
                        Wrap(
                          spacing: 8,
                          children: [
                            _button(
                              tr('Clock in now', 'تسجيل الحضور الآن'),
                              () => _act('clock_in', {}),
                            ),
                            for (final a in attendance.where(
                              (a) => a['clock_out'] == null,
                            ))
                              _button(
                                tr('Clock out now', 'تسجيل الانصراف الآن'),
                                () => _act('clock_out', {'id': a['id']}),
                              ),
                          ],
                        ),
                      for (final a in attendance.take(20))
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.schedule),
                          title: Text('${a['clock_in']}'),
                          subtitle: Text(
                            '${a['clock_out'] ?? tr('Open shift', 'دوام مفتوح')}',
                          ),
                        ),
                    ]),
                    _section(tr('Leave requests', 'طلبات الإجازة'), [
                      Text(
                        tr(
                          'Approval records leave only. Payroll uses actual attendance; no paid leave rule is assumed.',
                          'الموافقة تسجل الإجازة فقط. يحتسب الراتب من الحضور الفعلي دون افتراض قواعد إجازة مدفوعة.',
                        ),
                      ),
                      if (own)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _button(
                            tr('Request leave', 'طلب إجازة'),
                            () => _form(
                              tr('Request leave', 'طلب إجازة'),
                              'leave',
                              [
                                (
                                  'from_date',
                                  tr('From YYYY-MM-DD', 'من YYYY-MM-DD'),
                                ),
                                (
                                  'to_date',
                                  tr('To YYYY-MM-DD', 'إلى YYYY-MM-DD'),
                                ),
                                ('reason', tr('Reason', 'السبب')),
                              ],
                            ),
                          ),
                        ),
                      for (final l in rows('leave'))
                        ListTile(
                          title: Text(
                            '${l['from_date']} → ${l['to_date']} · ${label(l['status'].toString())}',
                          ),
                          subtitle: Text('${l['reason']}'),
                          trailing: widget.owner && l['status'] == 'pending'
                              ? Wrap(
                                  children: [
                                    IconButton(
                                      tooltip: tr('Approve', 'موافقة'),
                                      onPressed: busy
                                          ? null
                                          : () => _act('decide_leave', {
                                              'id': l['id'],
                                              'status': 'approved',
                                            }),
                                      icon: const Icon(Icons.check),
                                    ),
                                    IconButton(
                                      tooltip: tr('Reject', 'رفض'),
                                      onPressed: busy
                                          ? null
                                          : () => _act('decide_leave', {
                                              'id': l['id'],
                                              'status': 'rejected',
                                            }),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                    ]),
                    _section(tr('Adjustments ledger', 'سجل التسويات'), [
                      if (widget.owner)
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final kind in [
                              'bonus',
                              'deduction',
                              'advance',
                            ])
                              _button(
                                tr(
                                  kind,
                                  {
                                    'bonus': 'مكافأة',
                                    'deduction': 'خصم',
                                    'advance': 'سلفة',
                                  }[kind]!,
                                ),
                                () => _form(
                                  tr(
                                    'Record $kind',
                                    'تسجيل ${{'bonus': 'مكافأة', 'deduction': 'خصم', 'advance': 'سلفة'}[kind]}',
                                  ),
                                  'adjustment',
                                  [
                                    (
                                      'on_date',
                                      tr(
                                        'Date YYYY-MM-DD',
                                        'التاريخ YYYY-MM-DD',
                                      ),
                                    ),
                                    ('amount', tr('Amount', 'المبلغ')),
                                    ('reason', tr('Reason', 'السبب')),
                                  ],
                                  fixed: {'kind': kind},
                                ),
                              ),
                          ],
                        ),
                      for (final a in rows('adjustments'))
                        ListTile(
                          title: Text(
                            '${a['on_date']} · ${label(a['kind'].toString())} · ${a['amount']} ${a['currency']}',
                          ),
                          subtitle: Text('${a['reason']}'),
                        ),
                    ]),
                    _section(tr('Approved payroll', 'الرواتب المعتمدة'), [
                      Text(
                        tr(
                          'Base earned = configured base × actual minutes / scheduled minutes, capped at base. Commission uses completed service invoices before discounts, split equally across assigned staff. Approval creates an immutable record and does not transfer money.',
                          'الأجر المستحق = الأساسي × دقائق الحضور الفعلي ÷ الدقائق المقررة، بحد أقصى الأساسي. العمولة من فواتير الخدمات المكتملة قبل الخصم وتقسم بالتساوي على الموظفين المكلفين. الاعتماد ينشئ سجلاً ثابتاً دون تحويل أموال.',
                        ),
                      ),
                      if (widget.owner)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _button(
                            tr(
                              'Approve closed payroll period',
                              'اعتماد راتب فترة منتهية',
                            ),
                            () => _form(
                              tr(
                                'Approve immutable payroll',
                                'اعتماد راتب غير قابل للتعديل',
                              ),
                              'approve_payroll',
                              [
                                (
                                  'from_date',
                                  tr(
                                    'From YYYY-MM-DD (UTC)',
                                    'من YYYY-MM-DD (UTC)',
                                  ),
                                ),
                                (
                                  'to_date',
                                  tr(
                                    'To YYYY-MM-DD (UTC)',
                                    'إلى YYYY-MM-DD (UTC)',
                                  ),
                                ),
                                (
                                  'scheduled_minutes',
                                  tr(
                                    'Scheduled working minutes for this period',
                                    'دقائق العمل المقررة لهذه الفترة',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      for (final p in rows('payroll'))
                        Builder(
                          builder: (context) {
                            final s = p['snapshot'] as Map;
                            return ExpansionTile(
                              title: Text(
                                '${p['from_date']} → ${p['to_date']} · ${s['net']} ${s['currency']}',
                              ),
                              subtitle: Text(
                                tr(
                                  'Approved · no money transferred',
                                  'معتمد · لم يتم تحويل أموال',
                                ),
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    '${tr('Attendance minutes', 'دقائق الحضور')}: ${s['actual_minutes']} / ${s['scheduled_minutes']}\n${tr('Base earned', 'الأجر المستحق')}: ${s['base_earned']}\n${tr('Commission', 'العمولة')}: ${s['commission']}\n${tr('Adjustments', 'التسويات')}: ${s['adjustments']}',
                                  ),
                                ),
                                for (final line
                                    in s['commission_lines'] as List)
                                  ListTile(
                                    title: Text('${line['invoice_id']}'),
                                    subtitle: Text(
                                      hrCommissionExplanation(line, arabic: ar),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                    ]),
                  ],
                ),
        ),
      ),
    );
  }
}
