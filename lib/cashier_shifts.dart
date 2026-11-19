import 'app_config.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'branch_settings.dart';
import 'delivery_support.dart';
import 'shift_pdf.dart';
import 'invoices.dart';
import 'offline_customer_registration.dart';
import 'offline_walk_in.dart';
import 'safe_route_replacement.dart';

String cashierShiftStatusLabel(String status, Locale locale) {
  final arabic = locale.languageCode == 'ar';
  return switch (status) {
    'open' => arabic ? 'مفتوحة' : 'Open',
    'awaiting_approval' =>
      arabic ? 'بانتظار اعتماد المالك' : 'Awaiting owner approval',
    'closed' => arabic ? 'مغلقة ومعتمدة' : 'Closed and approved',
    _ => arabic ? 'حالة غير معروفة' : 'Unknown status',
  };
}

class CashierShiftsScreen extends StatefulWidget {
  final SupabaseClient client;
  final String role;
  final String? initialWalkInPriority;
  const CashierShiftsScreen({
    super.key,
    required this.client,
    required this.role,
    this.initialWalkInPriority,
  }) : assert(
         initialWalkInPriority == null ||
             initialWalkInPriority == 'normal' ||
             initialWalkInPriority == 'vip',
       );
  @override
  State<CashierShiftsScreen> createState() => _CashierShiftsScreenState();
}

class _CashierShiftsScreenState extends State<CashierShiftsScreen> {
  List<Map<String, dynamic>> branches = [],
      shifts = [],
      invoices = [],
      staff = [];
  String? branch, error;
  bool loading = true, busy = false;
  bool initialIntakeOpened = false;
  String openRequest = newOrderRequestId();
  final opening = TextEditingController(text: '0');
  String tr(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    opening.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      branches = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branches')
            .select()
            .eq('is_active', true),
      );
      if (!AppConfig.multiBranchEnabled) {
        branch = branches.firstWhere(
          (b) => b['is_default'] == true,
        )['branch_id'];
      }
      branch ??=
          BranchSelection.current ??
          branches.firstWhere(
            (b) => b['is_default'] == true,
            orElse: () => branches.first,
          )['branch_id'];
      shifts = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_cashier_shifts')
            .select()
            .eq('branch_id', branch!)
            .order('opened_at', ascending: false)
            .limit(50),
      );
      if (widget.role == 'owner') {
        staff = List<Map<String, dynamic>>.from(
          await widget.client
              .from('staff_profiles')
              .select('user_id,full_name,permissions')
              .eq('is_active', true),
        );
      }
      if (shifts.any(
        (s) => s['shift_id'] == openRequest && s['status'] == 'closed',
      )) {
        openRequest = newOrderRequestId();
      }
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
        if (widget.initialWalkInPriority != null && !initialIntakeOpened) {
          initialIntakeOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || branch == null) return;
            Navigator.of(context).push(
              registrationRoute(
                branch!,
                priority: widget.initialWalkInPriority!,
              ),
            );
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = tr(
            'تعذر تحميل الورديات. تحقق من صلاحية الكاشير والفرع.',
            'Could not load shifts. Check cashier and branch access.',
          );
        });
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      await load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'تعذر التنفيذ. تحقق من الصلاحية وحالة الوردية والبيانات.',
                'Could not complete the action. Check access, shift status, and data.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> report(Map<String, dynamic> s) async {
    await run(() async {
      final t = Map<String, dynamic>.from(
        await widget.client.rpc(
          'cashier_shift_totals',
          params: {'p_shift': s['shift_id']},
        ),
      );
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildShiftPdf(
        t,
        branches.firstWhere((b) => b['branch_id'] == s['branch_id'])['name_ar'],
        font.buffer.asUint8List(),
        logo.buffer.asUint8List(),
      );
      await FilePicker.saveFile(
        fileName: 'Sabiha-shift-${s['shift_id']}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
    });
  }

  Future<void> inspect(Map<String, dynamic> shift) async {
    try {
      final t = Map<String, dynamic>.from(
        await widget.client.rpc(
          'cashier_shift_totals',
          params: {'p_shift': shift['shift_id']},
        ),
      );
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('ملخص الوردية', 'Shift summary')),
          content: Text(
            tr(
              'الافتتاحية: ${t['opening_cash']} EGP\nصافي النقدي: ${t['cash_payments_net']}\nصافي الإلكتروني: ${t['electronic_payments_net']}\nحركات النقدية: ${t['cash_movements_net']}\nالمتوقع: ${t['expected_cash']}\nالفعلي: ${t['actual_cash'] ?? '—'}\nالفرق: ${t['difference'] ?? '—'}\nالسبب: ${t['difference_reason'] ?? '—'}',
              'Opening cash: ${t['opening_cash']} EGP\nNet cash payments: ${t['cash_payments_net']}\nNet card payments: ${t['electronic_payments_net']}\nCash movements: ${t['cash_movements_net']}\nExpected: ${t['expected_cash']}\nCounted: ${t['actual_cash'] ?? '—'}\nDifference: ${t['difference'] ?? '—'}\nReason: ${t['difference_reason'] ?? '—'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr('إغلاق', 'Close')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('تعذر تحميل الملخص.', 'Could not load shift summary.'),
            ),
          ),
        );
      }
    }
  }

  Future<void> payment(Map<String, dynamic> shift) async {
    try {
      final options = List<Map<String, dynamic>>.from(
        await widget.client.rpc(
          'shift_invoice_options',
          params: {'p_branch': shift['branch_id']},
        ),
      );
      if (options.isEmpty || !mounted) return;
      String invoice = options.first['invoice_id'];
      String method = 'cash', event = 'sale';
      final request = newOrderRequestId();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, update) => AlertDialog(
            title: Text(
              tr(
                'تسجيل تحصيل أو استرداد محلي',
                'Record a local collection or refund',
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: invoice,
                  isExpanded: true,
                  items: options
                      .map(
                        (i) => DropdownMenuItem(
                          value: i['invoice_id'] as String,
                          child: Text(
                            '${i['invoice_number'] ?? i['invoice_id']} · ${i['total']} EGP',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => update(() => invoice = v!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: event,
                  items: [
                    DropdownMenuItem(
                      value: 'sale',
                      child: Text(tr('تحصيل', 'Collection')),
                    ),
                    DropdownMenuItem(
                      value: 'refund',
                      child: Text(
                        tr('استرداد دفعة مسجلة', 'Refund a recorded payment'),
                      ),
                    ),
                  ],
                  onChanged: (v) => update(() => event = v!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  items: [
                    DropdownMenuItem(
                      value: 'cash',
                      child: Text(tr('نقدي', 'Cash')),
                    ),
                    DropdownMenuItem(
                      value: 'electronic',
                      child: Text(tr('بطاقة مسجلة', 'Recorded card payment')),
                    ),
                  ],
                  onChanged: (v) => update(() => method = v!),
                ),
                Text(
                  tr(
                    'المبلغ من الفاتورة على الخادم. لا يُنفّذ دفع حقيقي.',
                    'The server supplies the invoice amount. No real payment is processed.',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(tr('إلغاء', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr('تسجيل مرة واحدة', 'Record once')),
              ),
            ],
          ),
        ),
      );
      if (ok == true) {
        await run(() async {
          final paymentId = await widget.client.rpc(
            'record_shift_payment',
            params: {
              'p_request': request,
              'p_shift': shift['shift_id'],
              'p_invoice': invoice,
              'p_event': event,
              'p_method': method,
            },
          );
          await autoPrintCommittedPayment(widget.client, paymentId.toString());
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'تعذر تحميل الفواتير المصرح بها.',
                'Could not load invoices available to this cashier.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> movement(Map<String, dynamic> shift) async {
    String type = 'expense';
    final amount = TextEditingController(), reason = TextEditingController();
    final request = newOrderRequestId();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(tr('حركة نقدية موثقة', 'Recorded cash movement')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: type,
                items: [
                  DropdownMenuItem(
                    value: 'expense',
                    child: Text(tr('مصروف', 'Expense')),
                  ),
                  DropdownMenuItem(
                    value: 'withdrawal',
                    child: Text(tr('سحب', 'Withdrawal')),
                  ),
                  DropdownMenuItem(
                    value: 'deposit',
                    child: Text(tr('إيداع', 'Deposit')),
                  ),
                ],
                onChanged: (v) => update(() => type = v!),
              ),
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('المبلغ EGP', 'Amount EGP'),
                ),
              ),
              TextField(
                controller: reason,
                maxLength: 500,
                decoration: InputDecoration(labelText: tr('السبب', 'Reason')),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('حفظ الحركة', 'Save movement')),
            ),
          ],
        ),
      ),
    );
    final value = double.tryParse(amount.text), note = reason.text;
    amount.dispose();
    reason.dispose();
    if (ok == true) {
      await run(() async {
        await widget.client.rpc(
          'record_shift_movement',
          params: {
            'p_request': request,
            'p_shift': shift['shift_id'],
            'p_type': type,
            'p_amount': value,
            'p_reason': note,
          },
        );
      });
    }
  }

  Future<void> close(Map<String, dynamic> shift) async {
    final amount = TextEditingController(), reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          tr('إغلاق الوردية للمراجعة', 'Submit shift close for review'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr('النقدية الفعلية EGP', 'Counted cash EGP'),
              ),
            ),
            TextField(
              controller: reason,
              decoration: InputDecoration(
                labelText: tr(
                  'تفسير العجز أو الزيادة',
                  'Explain any cash difference',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              tr('إغلاق وإرسال للاعتماد', 'Seal and submit for approval'),
            ),
          ),
        ],
      ),
    );
    final actual = double.tryParse(amount.text), note = reason.text;
    amount.dispose();
    reason.dispose();
    if (ok == true) {
      await run(() async {
        await widget.client.rpc(
          'close_cashier_shift',
          params: {
            'p_shift': shift['shift_id'],
            'p_actual': actual,
            'p_reason': note,
          },
        );
      });
    }
  }

  Route<void> registrationRoute(String branchId, {String priority = 'normal'}) {
    final handoff = SharedOfflineWalkInHandoffStore(widget.client, branchId);
    // Resolve the navigator while the cashier screen is active. Do not retain a
    // BuildContext owned by the registration route across its async handoff.
    final navigator = Navigator.of(context);
    final handoffReplacement = SafeRouteReplacement();
    return MaterialPageRoute<void>(
      builder: (_) => OfflineCustomerRegistrationScreen(
        client: widget.client,
        branchId: branchId,
        role: widget.role,
        onStageReceiveWork: handoff.stage,
        onDiscardReceiveWork: handoff.discardSource,
        intakePriority: priority,
        onReceiveWork: (registrationRequest) {
          handoffReplacement.replaceOnce(
            navigator,
            walkInRoute(
              branchId,
              registrationRequest: registrationRequest,
              priority: priority,
            ),
          );
        },
      ),
    );
  }

  Route<void> walkInRoute(
    String branchId, {
    String? registrationRequest,
    String priority = 'normal',
  }) {
    // The navigator belongs to the still-mounted cashier route, so callbacks
    // remain safe when the walk-in route is being removed/replaced.
    final navigator = Navigator.of(context);
    final resumeReplacement = SafeRouteReplacement();
    var ledgerOpened = false;
    return MaterialPageRoute<void>(
      builder: (_) => OfflineWalkInScreen(
        client: widget.client,
        role: widget.role,
        priority: priority,
        initialRegistrationRequestId: registrationRequest,
        handoff: SharedOfflineWalkInHandoffStore(widget.client, branchId),
        onResumeRegistration: () {
          resumeReplacement.replaceOnce(navigator, registrationRoute(branchId));
        },
        onOpenCashierLedger: () {
          if (ledgerOpened || !navigator.mounted) return;
          ledgerOpened = true;
          navigator.pop();
          load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        tr('ورديات الكاشير والمدفوعات', 'Cashier shifts and payments'),
      ),
      actions: [
        IconButton(
          tooltip: Localizations.localeOf(context).languageCode == 'ar'
              ? 'تسجيل عميل بدون تطبيق'
              : 'Register customer without the app',
          onPressed: loading || busy || branch == null
              ? null
              : () => Navigator.of(context).push(registrationRoute(branch!)),
          icon: const Icon(Icons.person_add_alt_1),
        ),
        IconButton(
          tooltip: Localizations.localeOf(context).languageCode == 'ar'
              ? 'استقبال خدمة مباشرة'
              : 'Walk-in reception',
          onPressed: loading || busy || branch == null
              ? null
              : () => Navigator.of(context).push(walkInRoute(branch!)),
          icon: const Icon(Icons.local_car_wash_outlined),
        ),
        IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (error != null) Text(error!),
              if (busy) const LinearProgressIndicator(),
              if (AppConfig.multiBranchEnabled && branches.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(branch),
                  isExpanded: true,
                  initialValue: branch,
                  items: branches
                      .map(
                        (b) => DropdownMenuItem(
                          value: b['branch_id'] as String,
                          child: Text(
                            branchName(b, context),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    branch = v;
                    openRequest = newOrderRequestId();
                    load();
                  },
                ),
              TextField(
                controller: opening,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('النقدية الافتتاحية EGP', 'Opening cash EGP'),
                ),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await widget.client.rpc(
                          'open_cashier_shift',
                          params: {
                            'p_request': openRequest,
                            'p_branch': branch,
                            'p_opening': double.tryParse(opening.text),
                          },
                        );
                      }),
                child: Text(
                  tr('فتح ورديتي في هذا الفرع', 'Open my shift at this branch'),
                ),
              ),
              ...shifts.map(
                (s) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s['opened_at']} · ${cashierShiftStatusLabel('${s['status']}', Localizations.localeOf(context))}',
                        ),
                        if (s['difference'] != null)
                          Text(
                            tr(
                              'العجز أو الزيادة: ${s['difference']} EGP',
                              'Cash difference: ${s['difference']} EGP',
                            ),
                            style: TextStyle(
                              color: (s['difference'] as num).abs() >= 100
                                  ? Colors.red
                                  : null,
                            ),
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: () => inspect(s),
                              child: Text(tr('الملخص', 'Summary')),
                            ),
                            TextButton(
                              onPressed: () => report(s),
                              child: Text(tr('تقرير PDF', 'PDF report')),
                            ),
                            if (s['status'] == 'open') ...[
                              TextButton(
                                onPressed: busy ? null : () => payment(s),
                                child: Text(
                                  tr('تحصيل / استرداد', 'Collect / refund'),
                                ),
                              ),
                              TextButton(
                                onPressed: busy ? null : () => movement(s),
                                child: Text(tr('حركة نقدية', 'Cash movement')),
                              ),
                              TextButton(
                                onPressed: busy ? null : () => close(s),
                                child: Text(tr('إغلاق الوردية', 'Close shift')),
                              ),
                            ],
                            if (s['status'] == 'awaiting_approval' &&
                                widget.role == 'owner')
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => run(() async {
                                        await widget.client.rpc(
                                          'approve_cashier_shift',
                                          params: {'p_shift': s['shift_id']},
                                        );
                                      }),
                                child: Text(
                                  tr('اعتماد المالك', 'Owner approval'),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.role == 'owner') ...[
                const Divider(),
                Text(tr('تفويض صلاحية الكاشير', 'Cashier access delegation')),
                ...staff.map(
                  (s) => SwitchListTile(
                    title: Text(s['full_name']),
                    value:
                        s['permissions'] is Map &&
                        (s['permissions'] as Map)['cashier'] == true,
                    onChanged: busy
                        ? null
                        : (v) => run(() async {
                            await widget.client.rpc(
                              'set_cashier_permission',
                              params: {'p_user': s['user_id'], 'p_enabled': v},
                            );
                          }),
                  ),
                ),
              ],
            ],
          ),
  );
}
