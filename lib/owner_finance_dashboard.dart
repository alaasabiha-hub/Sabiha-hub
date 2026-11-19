import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'owner_finance_pdf.dart';

const _financeNavy = Color(0xff071a36);
const _financeBlue = Color(0xff174b83);

abstract interface class OwnerFinanceGateway {
  String? get currentUserId;
  Future<String> defaultBranch();
  Future<Map<String, dynamic>> dashboard(
    String branch,
    DateTime from,
    DateTime to,
  );
  Future<Map<String, dynamic>> expenseContext(
    String branch,
    DateTime from,
    DateTime to,
  );
  Future<Map<String, dynamic>> saveExpense(
    String requestId,
    Map<String, dynamic> payload,
  );
  Future<Map<String, dynamic>> setExpenseStatus({
    required String requestId,
    required String expenseId,
    required String status,
    String? method,
  });
  Future<String> uploadReceipt({
    required String branch,
    required String requestId,
    required String name,
    required Uint8List bytes,
    required String contentType,
  });
  Future<String> receiptUrl(String path);
}

class SupabaseOwnerFinanceGateway implements OwnerFinanceGateway {
  final SupabaseClient client;
  const SupabaseOwnerFinanceGateway(this.client);
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Future<String> defaultBranch() async {
    final value = await client.rpc('default_branch_id');
    if (value is! String || value.isEmpty) throw StateError('No active branch');
    return value;
  }

  @override
  Future<Map<String, dynamic>> dashboard(
    String branch,
    DateTime from,
    DateTime to,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'get_owner_finance_dashboard',
      params: {
        'p_branch': branch,
        'p_from': _dateKey(from),
        'p_to': _dateKey(to),
      },
    ) as Map,
  );

  @override
  Future<Map<String, dynamic>> expenseContext(
    String branch,
    DateTime from,
    DateTime to,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'get_owner_expense_context',
      params: {
        'p_branch': branch,
        'p_from': _dateKey(from),
        'p_to': _dateKey(to),
      },
    ) as Map,
  );

  @override
  Future<Map<String, dynamic>> saveExpense(
    String requestId,
    Map<String, dynamic> payload,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'save_owner_expense',
      params: {'p_request': requestId, 'p_data': payload},
    ) as Map,
  );

  @override
  Future<Map<String, dynamic>> setExpenseStatus({
    required String requestId,
    required String expenseId,
    required String status,
    String? method,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
      'set_owner_expense_status',
      params: {
        'p_request': requestId,
        'p_expense': expenseId,
        'p_status': status,
        'p_method': method,
      },
    ) as Map,
  );

  @override
  Future<String> uploadReceipt({
    required String branch,
    required String requestId,
    required String name,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$branch/expenses/$requestId/$safeName';
    await client.storage
        .from('owner-expense-receipts')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    return path;
  }

  @override
  Future<String> receiptUrl(String path) =>
      client.storage.from('owner-expense-receipts').createSignedUrl(path, 60);
}

String _dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _financeRequestId() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class OwnerFinanceDashboardScreen extends StatefulWidget {
  final OwnerFinanceGateway gateway;
  const OwnerFinanceDashboardScreen({super.key, required this.gateway});
  @override
  State<OwnerFinanceDashboardScreen> createState() =>
      _OwnerFinanceDashboardState();
}

class _OwnerFinanceDashboardState extends State<OwnerFinanceDashboardScreen> {
  late DateTime from;
  late DateTime to;
  String? branchId;
  Map<String, dynamic>? report;
  Map<String, dynamic>? prior;
  Map<String, dynamic>? expenseState;
  String? error;
  bool loading = true;
  bool saving = false;
  bool exporting = false;
  String language = 'ar';

  bool get ar => language == 'ar';
  String t(String a, String e) => ar ? a : e;
  Map<String, dynamic> get sales =>
      Map<String, dynamic>.from(report?['sales'] as Map? ?? {});
  Map<String, dynamic> get collections =>
      Map<String, dynamic>.from(report?['collections'] as Map? ?? {});
  Map<String, dynamic> get operations =>
      Map<String, dynamic>.from(report?['operations'] as Map? ?? {});
  Map<String, dynamic> get expenses =>
      Map<String, dynamic>.from(report?['expenses'] as Map? ?? {});
  Map<String, dynamic> get pnl =>
      Map<String, dynamic>.from(report?['pnl'] as Map? ?? {});
  Map<String, dynamic> get payroll =>
      Map<String, dynamic>.from(report?['payroll'] as Map? ?? {});
  List<Map<String, dynamic>> list(dynamic value) => (value as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  double? number(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');
  String money(dynamic value) {
    final n = number(value);
    return n == null
        ? t('غير متاح', 'Unavailable')
        : '${n.toStringAsFixed(2)} EGP';
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    from = DateTime(now.year, now.month, now.day);
    to = from;
    load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    language = Localizations.localeOf(context).languageCode;
  }

  Future<void> load() async {
    final actor = widget.gateway.currentUserId;
    if (actor == null) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'denied';
        report = null;
        prior = null;
        expenseState = null;
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final branch = branchId ?? await widget.gateway.defaultBranch();
      final current = await widget.gateway.dashboard(branch, from, to);
      final window = to.difference(from).inDays + 1;
      final previousTo = from.subtract(const Duration(days: 1));
      final previousFrom = previousTo.subtract(Duration(days: window - 1));
      Map<String, dynamic>? old;
      try {
        old = await widget.gateway.dashboard(branch, previousFrom, previousTo);
      } catch (_) {
        old = null;
      }
      Map<String, dynamic>? expenseResult;
      try {
        expenseResult = await widget.gateway.expenseContext(branch, from, to);
      } catch (_) {
        expenseResult = null;
      }
      if (!mounted || widget.gateway.currentUserId != actor) return;
      setState(() {
        branchId = branch;
        report = current;
        prior = old;
        expenseState = expenseResult;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        report = null;
        prior = null;
        expenseState = null;
        error = _permissionError(e) ? 'denied' : 'load';
        loading = false;
      });
    }
  }

  bool _permissionError(Object e) =>
      e is PostgrestException && (e.code == '42501' || e.code == 'PGRST301');

  Future<void> chooseRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: from, end: to),
    );
    if (range == null || !mounted) return;
    if (range.end.difference(range.start).inDays > 365) {
      _message(t('الفترة القصوى 366 يومًا.', 'Maximum range is 366 days.'));
      return;
    }
    setState(() {
      from = range.start;
      to = range.end;
    });
    await load();
  }

  Future<void> setPreset(String value) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      switch (value) {
        case 'yesterday':
          from = to = today.subtract(const Duration(days: 1));
          break;
        case 'week':
          from = today.subtract(Duration(days: today.weekday - 1));
          to = today;
          break;
        case 'month':
          from = DateTime(today.year, today.month);
          to = today;
          break;
        case 'year':
          from = DateTime(today.year);
          to = today;
          break;
        default:
          from = to = today;
          break;
      }
    });
    await load();
  }

  Future<void> exportPdf() async {
    final snapshot = report;
    final actor = widget.gateway.currentUserId;
    if (snapshot == null || actor == null || exporting) return;
    setState(() => exporting = true);
    try {
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildOwnerFinancePdf(
        report: snapshot,
        expenseContext: expenseState,
        branch: branchId ?? '',
        from: from,
        to: to,
        fontBytes: font.buffer.asUint8List(),
        logoBytes: logo.buffer.asUint8List(),
        arabic: ar,
      );
      if (!mounted || widget.gateway.currentUserId != actor) return;
      await FilePicker.saveFile(
        fileName: 'sabiha_owner_finance_${_dateKey(from)}_${_dateKey(to)}.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
      );
    } catch (_) {
      _message(
        t('تعذر إنشاء التقرير PDF.', 'Could not create the PDF report.'),
      );
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xfff1f3f6),
        appBar: AppBar(
          backgroundColor: _financeNavy,
          foregroundColor: Colors.white,
          title: Text(t('لوحة المالية والتشغيل', 'Finance & Operations')),
          actions: [
            IconButton(
              tooltip: ar ? 'تغيير اللغة' : 'Change language',
              onPressed: () => setState(() => language = ar ? 'en' : 'ar'),
              icon: const Icon(Icons.language),
            ),
            IconButton(
              onPressed: loading ? null : load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
            ? _errorPanel()
            : report == null
            ? const SizedBox.shrink()
            : RefreshIndicator(
                onRefresh: load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _periodControls(),
                    _kpis(),
                    _comparison(),
                    _dailyChart(),
                    _aiEvidencePanel(),
                    _commissionPanel(),
                    _payrollPanel(),
                    _expensePanel(),
                    _pnlPanel(),
                    _limitations(),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _errorPanel() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            error == 'denied' ? Icons.lock_outline : Icons.cloud_off,
            size: 42,
            color: _financeBlue,
          ),
          const SizedBox(height: 12),
          Text(
            error == 'denied'
                ? t(
                    'هذه اللوحة للمالك أو للموظف الذي مُنح صلاحية مالية صريحة.',
                    'Owner access or explicit financial permission is required.',
                  )
                : t(
                    'تعذر تحميل البيانات المالية من QA.',
                    'Could not load QA finance data.',
                  ),
          ),
          TextButton(
            onPressed: load,
            child: Text(t('إعادة المحاولة', 'Retry')),
          ),
        ],
      ),
    ),
  );

  Widget _periodControls() => Card(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if ((report?['branches'] as List? ?? []).isNotEmpty)
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                key: const ValueKey('finance-branch-picker'),
                initialValue: branchId,
                decoration: InputDecoration(
                  labelText: t('الفرع', 'Branch'),
                  isDense: true,
                ),
                items: [
                  for (final row in list(report?['branches']))
                    DropdownMenuItem<String>(
                      value: '${row['branch_id']}',
                      child: Text(
                        '${ar ? row['name_ar'] : row['name_en']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null || value == branchId) return;
                  setState(() => branchId = value);
                  load();
                },
              ),
            ),
          for (final preset in [
            ('today', 'اليوم', 'Today'),
            ('yesterday', 'أمس', 'Yesterday'),
            ('week', 'هذا الأسبوع', 'This week'),
            ('month', 'هذا الشهر', 'This month'),
            ('year', 'هذه السنة', 'This year'),
          ])
            OutlinedButton(
              onPressed: () => setPreset(preset.$1),
              child: Text(t(preset.$2, preset.$3)),
            ),
          OutlinedButton.icon(
            key: const ValueKey('finance-custom-range'),
            onPressed: chooseRange,
            icon: const Icon(Icons.date_range),
            label: Text('${_dateKey(from)} – ${_dateKey(to)}'),
          ),
          FilledButton.icon(
            key: const ValueKey('finance-export-pdf'),
            onPressed: exporting ? null : exportPdf,
            icon: exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
            label: Text(
              exporting
                  ? t('جارٍ تجهيز PDF', 'Preparing PDF')
                  : t('تصدير PDF', 'Export PDF'),
            ),
          ),
          Text(
            'EGP · ${report?['time_zone'] ?? 'Africa/Cairo'}',
            style: const TextStyle(
              color: _financeNavy,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _kpis() {
    final bookings = Map<String, dynamic>.from(
      operations['bookings_by_status'] as Map? ?? {},
    );
    final bookingCount = bookings.values.fold<int>(
      0,
      (a, v) => a + ((v as num?)?.toInt() ?? 0),
    );
    final commissionTotal = list(report?['commissions'])
        .fold<double>(0, (a, c) => a + (number(c['commission_earned']) ?? 0));
    final isToday = from == to && _dateKey(from) == _dateKey(DateTime.now());
    final items = <(String, String, String, IconData)>[
      (
        t('المبيعات', 'Sales'),
        money(sales['billed_net_after_refunds']),
        'sales',
        Icons.receipt_long,
      ),
      (
        t('السيارات المخدومة', 'Cars serviced'),
        '${operations['verified_cars_serviced'] ?? 0}',
        'cars',
        Icons.local_car_wash,
      ),
      (
        t('الفواتير والحجوزات', 'Invoices & bookings'),
        '${sales['active_invoice_count'] ?? 0} / $bookingCount',
        'operations',
        Icons.stacked_bar_chart,
      ),
      (
        t('متوسط الفاتورة', 'Average invoice'),
        money(sales['average_invoice']),
        'average',
        Icons.price_check,
      ),
      (
        t('التحصيل الفعلي', 'Collected'),
        money(collections['paid_net']),
        'collections',
        Icons.payments,
      ),
      (
        t('مبالغ معلقة', 'Pending'),
        money(collections['pending_invoice_balance']),
        'pending',
        Icons.pending_actions,
      ),
      (
        t('عمولات مكتسبة', 'Earned commissions'),
        money(commissionTotal),
        'commissions',
        Icons.groups,
      ),
      (
        t('مصروفات اليوم', isToday ? 'Today expenses' : 'Recorded expenses'),
        money(expenses['incurred_total']),
        'expenses',
        Icons.money_off,
      ),
      (
        t('صافي الربح التقديري', 'Estimated net profit'),
        money(sales['actual_profit']),
        'profit',
        Icons.query_stats,
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 980
            ? 4
            : box.maxWidth >= 620
            ? 2
            : 1;
        final width = (box.maxWidth - (columns - 1) * 10) / columns;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in items)
                SizedBox(
                  width: width,
                  child: Card(
                    child: InkWell(
                      key: ValueKey('finance-card-${item.$3}'),
                      onTap: () => _showKpiDetail(item.$3),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: _financeNavy,
                              foregroundColor: Colors.white,
                              child: Icon(item.$4),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.$1,
                                    style: const TextStyle(
                                      color: _financeNavy,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    item.$2,
                                    style: const TextStyle(
                                      color: _financeBlue,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 19,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showKpiDetail(String key) {
    final title = switch (key) {
      'sales' => t('تفاصيل المبيعات', 'Sales details'),
      'cars' => t('الزيارات المكتملة الموثقة', 'Verified completed visits'),
      'operations' => t('حالة الحجوزات', 'Booking statuses'),
      'average' => t('متوسط قيمة الفاتورة', 'Average invoice value'),
      'collections' => t('حركات التحصيل', 'Collection events'),
      'pending' => t('الأرصدة غير المحصلة', 'Uncollected invoice balances'),
      'commissions' => t('العمولات المسجلة', 'Recorded commissions'),
      'expenses' => t('المصروفات المسجلة', 'Recorded expenses'),
      _ => t('الربح غير متاح', 'Profit unavailable'),
    };
    final content = switch (key) {
      'sales' =>
        '${t('الخصومات', 'Discounts')}: ${money(sales['discounts'])}\n${t('المرتجعات', 'Refunds')}: ${money(sales['refunds'])}\n${t('صافي الإيرادات دون الضريبة', 'Revenue excluding VAT')}: ${money(sales['revenue_ex_vat'])}',
      'cars' => t(
        'العدد مصدره إكمال الخدمة الموثق في نظام العمل، لا عدد الفواتير.',
        'Count comes from verified service-completion records, not invoice count.',
      ),
      'operations' =>
        '${t('الفواتير حسب الحالة', 'Invoices by status')}\n${(sales['invoices_by_status'] as Map? ?? {}).entries.map((e) => '${e.key}: ${e.value}').join('\n')}\n\n${t('الحجوزات حسب الحالة', 'Bookings by status')}\n${(operations['bookings_by_status'] as Map? ?? {}).entries.map((e) => '${e.key}: ${e.value}').join('\n')}',
      'collections' => list(
        collections['methods'],
      ).map((e) => '${e['method']}: ${money(e['net'])}').join('\n'),
      'pending' => t(
        'المعلق محسوب من رصيد الفاتورة بعد أحداث الدفع والاسترداد المسجلة.',
        'Pending is calculated from invoice balance after recorded payment and refund events.',
      ),
      'commissions' =>
        list(report?['commissions'])
            .map((e) => '${e['full_name']}: ${money(e['commission_earned'])}')
            .join('\n'),
      'expenses' =>
        '${t('مدفوعة بسجل جديد', 'Paid in managed ledger')}: ${money(expenses['managed_paid'])}\n${t('غير مدفوعة', 'Unpaid')}: ${money(expenses['managed_unpaid'])}\n${t('سجلات قديمة بحالة دفع غير معروفة', 'Legacy rows with unknown payment state')}: ${money(expenses['legacy_payment_status_unknown'])}',
      _ =>
        '${t('لا توجد تكلفة مكتملة للمواد والخدمات ولا دفتر صرف الرواتب والعمولات.', 'Complete service/material costs and a payroll/commission payout ledger are not available.')}\n${t('لن نعرض رقم ربح مضلل.', 'A misleading profit figure is not shown.')}',
    };
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SelectableText(
          content.isEmpty
              ? t('لا توجد تفاصيل مسجلة.', 'No recorded details.')
              : content,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t('إغلاق', 'Close')),
          ),
        ],
      ),
    );
  }

  Widget _comparison() {
    if (prior == null) return const SizedBox.shrink();
    final currentSales = number(sales['billed_net_after_refunds']);
    final previousSales = number(
      (prior!['sales'] as Map?)?['billed_net_after_refunds'],
    );
    final currentCars = (operations['verified_cars_serviced'] as num?)?.toInt();
    final previousCars =
        ((prior!['operations'] as Map?)?['verified_cars_serviced'] as num?)
            ?.toInt();
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t(
                'مقارنة بالفترة السابقة المماثلة',
                'Comparison with previous equal-length period',
              ),
              style: const TextStyle(
                color: _financeNavy,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${t('المبيعات', 'Sales')}: ${money(currentSales)}  ←  ${money(previousSales)}',
            ),
            Text(
              '${t('السيارات المخدومة', 'Cars serviced')}: ${currentCars ?? 0}  ←  ${previousCars ?? 0}',
            ),
            Text(
              t(
                'الفترة السابقة وصفية وبنفس عدد الأيام؛ لا تثبت سبب التغير.',
                'Previous period has the same day count and is descriptive; it does not prove causation.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dailyChart() {
    final rows = list(report?['daily']);
    if (rows.isEmpty) return const SizedBox.shrink();
    final peak = rows.fold<double>(
      1,
      (m, r) => max(m, number(r['billed']) ?? 0),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t(
                'المبيعات والتحصيل والسيارات يوميًا',
                'Daily sales, collections & cars',
              ),
              style: const TextStyle(
                color: _financeNavy,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final row in rows)
                    Tooltip(
                      message:
                          '${row['date']} · ${money(row['billed'])} · ${money(row['collected'])} · ${row['cars']} ${t('سيارات', 'cars')}',
                      triggerMode: TooltipTriggerMode.tap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            SizedBox(
                              height: 100,
                              width: 24,
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  height:
                                      (number(row['billed']) ?? 0) / peak * 100,
                                  width: 18,
                                  decoration: const BoxDecoration(
                                    color: _financeBlue,
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${row['date']}'.substring(5),
                              style: const TextStyle(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              t(
                'الأعمدة تمثل الفواتير، والتحصيل يظهر في تفاصيل كل يوم من أحداث الدفع الفعلية.',
                'Bars show invoices; daily details include actual payment events.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commissionPanel() {
    final rows = list(report?['commissions']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(
                'عمولات الخدمات المكتملة حسب العامل',
                'Completed-service commissions by worker',
              ),
              style: const TextStyle(
                color: _financeNavy,
                fontWeight: FontWeight.w800,
                fontSize: 17,
              ),
            ),
            Text(
              t(
                'المبلغ مبني على تخصيص الخدمة المثبت عند بدء العمل، قبل الخصم ودون الضريبة. الدفع/المتبقي غير متاح لعدم وجود دفتر صرف عمولات.',
                'Amounts use the frozen service allocation at work start, before discount and excluding tax. Paid/remaining is unavailable because no commission payout ledger exists.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              Text(
                t(
                  'لا توجد عمولات خدمة مكتملة مسجلة في هذه الفترة.',
                  'No completed service commissions are recorded for this period.',
                ),
              )
            else
              for (final row in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: _financeNavy,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text('${row['full_name'] ?? t('موظف', 'Staff')}'),
                  subtitle: Text(
                    '${row['cars_serviced'] ?? 0} ${t('سيارات', 'cars')} · ${row['completed_services'] ?? 0} ${t('خدمات', 'services')} · ${t('الصرف غير مسجل', 'payout untracked')}',
                  ),
                  trailing: Text(
                    money(row['commission_earned']),
                    style: const TextStyle(
                      color: _financeNavy,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _aiEvidencePanel() {
    final currentSales = number(sales['billed_net_after_refunds']);
    final previousSales = number(
      (prior?['sales'] as Map?)?['billed_net_after_refunds'],
    );
    final currentExpense = number(expenses['incurred_total']);
    final previousExpense = number(
      (prior?['expenses'] as Map?)?['incurred_total'],
    );
    final pending = number(collections['pending_invoice_balance']);
    final observedDays = list(report?['daily'])
        .where((row) => (number(row['billed']) ?? 0) > 0)
        .length;
    final insights = <String>[];
    if (currentSales != null && previousSales != null) {
      final delta = currentSales - previousSales;
      insights.add(
        t(
          'المبيعات المسجلة تغيرت ${delta >= 0 ? 'بزيادة' : 'بانخفاض'} ${money(delta.abs())} عن الفترة المماثلة السابقة؛ هذه مقارنة وصفية.',
          'Recorded sales ${delta >= 0 ? 'increased' : 'decreased'} by ${money(delta.abs())} versus the comparable prior period; this is descriptive only.',
        ),
      );
    } else {
      insights.add(
        t(
          'لا توجد فترتان مكتملتان للمقارنة الموثوقة.',
          'Two complete periods are not available for a reliable comparison.',
        ),
      );
    }
    if (currentExpense != null && previousExpense != null) {
      final delta = currentExpense - previousExpense;
      insights.add(
        t(
          'المصروفات المسجلة ${delta >= 0 ? 'زادت' : 'انخفضت'} ${money(delta.abs())} مقارنة بالفترة السابقة.',
          'Recorded expenses ${delta >= 0 ? 'rose' : 'fell'} by ${money(delta.abs())} versus the prior period.',
        ),
      );
    }
    if ((pending ?? 0) > 0) {
      insights.add(
        t(
          'يوجد رصيد فواتير معلق قدره ${money(pending)}؛ لا يُعد تحصيلًا نقديًا.',
          '${money(pending)} remains in pending invoice balances; it is not cash collected.',
        ),
      );
    }
    if (pnl['net_profit'] == null) {
      insights.add(
        t(
          'لا يمكن تقدير صافي الربح قبل اكتمال تكلفة المخزون والمواد وتوزيع المصروفات على الفترة.',
          'Net profit cannot be estimated until inventory/material costs and period expense allocation are complete.',
        ),
      );
    }
    if (observedDays < 14) {
      insights.add(
        t(
          'لا توجد 14 يومًا على الأقل بها مبيعات مسجلة؛ لن نعرض توقع مبيعات أو تكلفة غير موثوق.',
          'Fewer than 14 days with recorded sales are available; no unreliable sales or cost forecast is shown.',
        ),
      );
    }
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t(
                'Sabiha AI - مؤشرات مالية من بيانات QA',
                'Sabiha AI - QA financial evidence',
              ),
              style: const TextStyle(
                color: _financeNavy,
                fontWeight: FontWeight.w800,
                fontSize: 17,
              ),
            ),
            Text(
              t(
                'تحليل وصفي مجاني من سجلات الفترة؛ لا يختلق تكاليف أو يقرر بدلًا عن المالك.',
                'Free descriptive analysis of recorded data; it invents no costs and makes no decisions for the owner.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
            const SizedBox(height: 6),
            for (final insight in insights)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.auto_awesome, color: _financeBlue),
                title: Text(insight),
              ),
          ],
        ),
      ),
    );
  }

  Widget _expensePanel() {
    final rows = list(expenseState?['expenses']);
    final canManage = expenseState?['can_manage_expenses'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('المصروفات', 'Expenses'),
                    style: const TextStyle(
                      color: _financeNavy,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ),
                if (canManage)
                  FilledButton.icon(
                    key: const ValueKey('finance-add-expense'),
                    onPressed: saving ? null : () => _editExpense(),
                    icon: const Icon(Icons.add),
                    label: Text(t('إضافة مصروف', 'Add expense')),
                  ),
              ],
            ),
            Text(
              t(
                'السجلات القديمة للعرض فقط وحالة دفعها غير معروفة. الإدخالات الجديدة مدققة ومقسمة مدفوعة/غير مدفوعة؛ الرواتب والعمولات لا تُنشأ تلقائيًا هنا كي لا تُخصم مرتين.',
                'Legacy entries are read-only with unknown payment state. New entries are audited and split paid/unpaid; salaries and commissions are not auto-created here to avoid double counting.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              Text(
                t(
                  'لا توجد مصروفات مسجلة لهذه الفترة.',
                  'No expenses are recorded in this period.',
                ),
              )
            else
              for (final row in rows) _expenseTile(row, canManage),
          ],
        ),
      ),
    );
  }

  Widget _payrollPanel() {
    final complete = payroll['period_complete'] != false;
    final count = (payroll['snapshot_count'] as num?)?.toInt() ?? 0;
    final rows = <(String, String)>[
      (t('الأجر الأساسي المستحق', 'Base pay earned'), 'base_earned'),
      (
        t('العمولات داخل مسير الرواتب', 'Commission in payroll snapshot'),
        'commission_earned',
      ),
      (t('المكافآت', 'Bonuses'), 'bonuses'),
      (t('السلف', 'Advances'), 'advances'),
      (t('الخصومات', 'Deductions'), 'deductions'),
      (
        t('صافي المسير المعتمد', 'Approved payroll net snapshot'),
        'net_snapshot',
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(
                'مسيرات الرواتب المعتمدة ضمن الفترة',
                'Approved payroll snapshots in period',
              ),
              style: const TextStyle(
                color: _financeNavy,
                fontWeight: FontWeight.w800,
                fontSize: 17,
              ),
            ),
            Text(
              !complete
                  ? t(
                      'الفترة تتقاطع مع مسير راتب؛ لن نوزع قيمة شهرية على الأيام دون اعتماد محاسبي.',
                      'The range intersects a payroll period; monthly totals are not prorated without an approved accounting rule.',
                    )
                  : count == 0
                  ? t(
                      'لا توجد مسيرات معتمدة تغطي الفترة بالكامل.',
                      'No approved payroll snapshots fully cover this period.',
                    )
                  : t(
                      'هذه لقطة استحقاق معتمدة وليست إثباتًا للتحويل البنكي أو الصرف.',
                      'This is an approved earning snapshot, not proof of transfer or payment.',
                    ),
              style: const TextStyle(color: _financeBlue),
            ),
            for (final row in rows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(row.$1),
                trailing: Text(money(complete ? payroll[row.$2] : null)),
              ),
            Text(
              t(
                'العمولة اليومية أعلاه تُعرض منفصلة. لا تجمع عمولة المسير مع العمولة المكتسبة مرة ثانية.',
                'Daily earned commissions above are separate; do not add payroll-snapshot commission a second time.',
              ),
              style: const TextStyle(color: _financeBlue),
            ),
          ],
        ),
      ),
    );
  }

  Widget _expenseTile(Map<String, dynamic> row, bool canManage) {
    final legacy = row['legacy'] == true;
    final status = '${row['status'] ?? ''}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        legacy ? Icons.history : Icons.receipt_long,
        color: _financeBlue,
      ),
      title: Text(
        '${row['custom_category'] ?? _categoryLabel('${row['category']}')} · ${money(row['amount'])}',
        style: const TextStyle(
          color: _financeNavy,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        '${row['expense_date']} · ${_statusLabel(status)}${row['due_date'] == null ? '' : ' · ${t('استحقاق', 'Due')} ${row['due_date']}'}',
      ),
      trailing: Wrap(
        children: [
          if (row['attachment_path'] is String &&
              '${row['attachment_path']}'.isNotEmpty)
            IconButton(
              tooltip: t('عرض الإيصال', 'View receipt'),
              onPressed: () => _openReceipt('${row['attachment_path']}'),
              icon: const Icon(Icons.attach_file),
            ),
          if (!legacy && canManage && status == 'unpaid') ...[
            IconButton(
              tooltip: t('تعديل', 'Edit'),
              onPressed: saving ? null : () => _editExpense(row),
              icon: const Icon(Icons.edit_outlined, color: _financeBlue),
            ),
            IconButton(
              tooltip: t('تسجيل الدفع', 'Record payment'),
              onPressed: saving ? null : () => _markPaid(row),
              icon: const Icon(Icons.check_circle_outline, color: Colors.green),
            ),
            IconButton(
              tooltip: t('إلغاء السجل', 'Void record'),
              onPressed: saving ? null : () => _voidExpense(row),
              icon: const Icon(Icons.block_outlined, color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  String _categoryLabel(String key) => switch (key) {
    'rent' => t('إيجار', 'Rent'),
    'electricity' => t('كهرباء', 'Electricity'),
    'water' => t('مياه', 'Water'),
    'salary' => t('رواتب', 'Salaries'),
    'commission' => t('عمولات', 'Commissions'),
    'washing_supplies' => t('مستلزمات الغسيل', 'Washing supplies'),
    'maintenance' => t('صيانة', 'Maintenance'),
    'internet_telecom' => t('إنترنت واتصالات', 'Internet & telecom'),
    'marketing' => t('تسويق وإعلانات', 'Marketing & ads'),
    _ => t('أخرى', 'Other'),
  };

  String _statusLabel(String key) => switch (key) {
    'paid' => t('مدفوع', 'Paid'),
    'unpaid' => t('غير مدفوع', 'Unpaid'),
    'void' => t('ملغى', 'Voided'),
    _ => t('حالة الدفع غير معروفة', 'Payment state unknown'),
  };

  Future<void> _openReceipt(String path) async {
    try {
      final uri = Uri.parse(await widget.gateway.receiptUrl(path));
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Open failed');
      }
    } catch (_) {
      _message(
        t(
          'تعذر فتح الإيصال أو لا توجد صلاحية.',
          'Could not open receipt or permission is missing.',
        ),
      );
    }
  }

  Future<void> _editExpense([Map<String, dynamic>? existing]) async {
    final form = await showDialog<_ExpenseFormResult>(
      context: context,
      builder: (context) => _ExpenseFormDialog(
        initial: existing,
        branch: branchId!,
        canAttach: expenseState?['can_manage_expenses'] == true,
        gateway: widget.gateway,
        arabic: ar,
        onMessage: _message,
      ),
    );
    if (form == null) return;
    final actor = widget.gateway.currentUserId;
    if (actor == null) {
      _message(
        t(
          'انتهت الجلسة؛ لم يُحفظ المصروف.',
          'Session expired; expense was not saved.',
        ),
      );
      return;
    }
    setState(() => saving = true);
    try {
      final request = _financeRequestId();
      String? attachment = existing?['attachment_path'] as String?;
      if (form.file != null) {
        attachment = await widget.gateway.uploadReceipt(
          branch: branchId!,
          requestId: request,
          name: form.file!.name,
          bytes: await form.file!.readAsBytes(),
          contentType: _mime(form.file!.extension),
        );
      }
      await widget.gateway.saveExpense(request, {
        'branch_id': branchId,
        'expense_id': existing?['expense_id'],
        'expected_revision': existing == null ? null : existing['revision'],
        'category': form.category,
        'custom_category': form.customCategory,
        'amount': form.amount,
        'expense_date': _dateKey(form.expenseDate),
        'due_date': form.dueDate == null ? null : _dateKey(form.dueDate!),
        'external_reference': form.reference,
        'note': form.note,
        'attachment_path': attachment,
        'recurrence_rule': existing == null ? form.recurrence : 'none',
        'recurrence_until': existing == null && form.recurrenceUntil != null
            ? _dateKey(form.recurrenceUntil!)
            : null,
      });
      if (widget.gateway.currentUserId != actor) {
        throw StateError('Session changed');
      }
      _message(t('تم حفظ المصروف في QA.', 'Expense saved in QA.'));
      await load();
    } catch (e) {
      _message(
        _permissionError(e)
            ? t(
                'لا تملك صلاحية إدارة المصروفات لهذا الفرع.',
                'You cannot manage expenses for this branch.',
              )
            : t(
                'تعذر الحفظ؛ راجع المرجع المكرر أو يومًا معتمدًا.',
                'Save failed; check duplicate reference or an approved day.',
              ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _mime(String? ext) => switch ((ext ?? '').toLowerCase()) {
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => 'application/octet-stream',
  };

  Future<void> _markPaid(Map<String, dynamic> row) async {
    final method = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('تسجيل دفع المصروف', 'Record expense payment')),
        content: DropdownButtonFormField<String>(
          initialValue: 'cash',
          items: [
            DropdownMenuItem(value: 'cash', child: Text(t('نقدي', 'Cash'))),
            DropdownMenuItem(
              value: 'card_terminal',
              child: Text(t('بطاقة على الماكينة', 'Card terminal')),
            ),
            DropdownMenuItem(
              value: 'bank_transfer',
              child: Text(t('تحويل بنكي', 'Bank transfer')),
            ),
            DropdownMenuItem(value: 'other', child: Text(t('أخرى', 'Other'))),
          ],
          onChanged: (value) => Navigator.pop(c, value),
          decoration: InputDecoration(
            labelText: t('طريقة الدفع', 'Payment method'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t('إلغاء', 'Cancel')),
          ),
        ],
      ),
    );
    if (method == null) return;
    await _changeExpenseStatus(row, 'paid', method);
  }

  Future<void> _voidExpense(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('إلغاء سجل المصروف؟', 'Void this expense?')),
        content: Text(
          t(
            'سيبقى السجل في التدقيق، ولن يُحذف.',
            'The audit record will remain; the entry will not be deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('إلغاء السجل', 'Void')),
          ),
        ],
      ),
    );
    if (ok == true) await _changeExpenseStatus(row, 'void', null);
  }

  Future<void> _changeExpenseStatus(
    Map<String, dynamic> row,
    String status,
    String? method,
  ) async {
    final actor = widget.gateway.currentUserId;
    if (actor == null) return;
    setState(() => saving = true);
    try {
      await widget.gateway.setExpenseStatus(
        requestId: _financeRequestId(),
        expenseId: '${row['expense_id']}',
        status: status,
        method: method,
      );
      if (widget.gateway.currentUserId != actor) {
        throw StateError('Session changed');
      }
      await load();
    } catch (_) {
      _message(
        t(
          'تعذر تحديث المصروف. قد يكون اليوم معتمدًا أو تغير السجل.',
          'Could not update expense. The day may be approved or the record changed.',
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _pnlPanel() => Card(
    color: const Color(0xffeaf0f5),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('قائمة الأرباح والخسائر', 'Profit & Loss'),
            style: const TextStyle(
              color: _financeNavy,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          _pnlRow(
            t(
              'صافي الإيرادات دون ضريبة القيمة المضافة',
              'Net revenue excluding VAT',
            ),
            money(pnl['revenue_ex_vat']),
          ),
          _pnlRow(
            t(
              'تكلفة المواد والخدمات المباعة',
              'Cost of goods and services sold',
            ),
            money(pnl['inventory_cogs']),
          ),
          _pnlRow(t('مجمل الربح', 'Gross profit'), money(pnl['gross_profit'])),
          _pnlRow(
            t('تكلفة الرواتب', 'Payroll cost'),
            money(pnl['payroll_cost']),
          ),
          _pnlRow(
            t('المصروفات التشغيلية', 'Operating expenses'),
            money(pnl['operating_expenses']),
          ),
          const Divider(),
          _pnlRow(
            t('صافي الربح أو الخسارة', 'Net profit or loss'),
            money(pnl['net_profit']),
            strong: true,
          ),
          Text(
            t(
              'الحالة: غير مكتملة التكلفة والفترة. المتاح هو بيانات مسجلة فقط؛ التحصيل النقدي لا يُعامل كربح.',
              'Status: cost and period coverage is incomplete. Only recorded evidence is shown; cash collections are not treated as profit.',
            ),
            style: const TextStyle(color: _financeBlue),
          ),
        ],
      ),
    ),
  );

  Widget _pnlRow(String label, String value, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: _financeNavy,
              fontWeight: strong ? FontWeight.w900 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: _financeNavy,
            fontWeight: strong ? FontWeight.w900 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _limitations() {
    final rows = (report?['limitations'] as List? ?? []).cast<String>();
    return Card(
      child: ExpansionTile(
        title: Text(
          t('مصادر البيانات والفجوات', 'Data sources & gaps'),
          style: const TextStyle(
            color: _financeNavy,
            fontWeight: FontWeight.w800,
          ),
        ),
        children: [
          for (final key in rows)
            ListTile(
              leading: const Icon(Icons.info_outline, color: _financeBlue),
              title: Text(_limitation(key)),
            ),
          ListTile(
            leading: const Icon(Icons.info_outline, color: _financeBlue),
            title: Text(
              t(
                '14% ضريبة لا تُفترض تلقائيًا؛ التقرير يقرأ الضريبة المحفوظة مع الفاتورة ويخفي صافي الإيرادات إذا كانت ناقصة.',
                '14% VAT is not assumed; the report reads tax stored with the invoice and withholds net revenue when missing.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _limitation(String key) => switch (key) {
    'inventory_cost_of_goods_not_allocated_to_sold_units' => t(
      'تكلفة الشراء غير موزعة على الوحدات المباعة؛ تكلفة البضاعة المباعة غير متاحة.',
      'Purchase costs are not allocated to sold units; COGS is unavailable.',
    ),
    'service_material_cost_not_recorded' => t(
      'تكلفة مواد كل خدمة غير مسجلة بالكامل.',
      'Per-service materials costs are not fully recorded.',
    ),
    'commission_payout_ledger_unavailable' => t(
      'سجل صرف العمولات غير موجود؛ المستحق معروف والصرف/المتبقي غير معروف.',
      'No commission payout ledger; earned is known, paid/remaining are not.',
    ),
    'legacy_expense_payment_status_unknown' => t(
      'سجلات المصروف القديمة لا تحدد حالة الدفع.',
      'Legacy expense rows do not specify payment status.',
    ),
    _ => t(
      'لا توجد تسوية شهرية معتمدة للمصروفات المتكررة.',
      'Recurring expenses do not yet have an approved monthly accrual close.',
    ),
  };
}

class _ExpenseFormResult {
  final String category, customCategory, reference, note, recurrence;
  final double amount;
  final DateTime expenseDate;
  final DateTime? dueDate, recurrenceUntil;
  final PlatformFile? file;
  const _ExpenseFormResult({
    required this.category,
    required this.customCategory,
    required this.reference,
    required this.note,
    required this.recurrence,
    required this.amount,
    required this.expenseDate,
    this.dueDate,
    this.recurrenceUntil,
    this.file,
  });
}

class _ExpenseFormDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final String branch;
  final bool canAttach, arabic;
  final OwnerFinanceGateway gateway;
  final ValueChanged<String> onMessage;
  const _ExpenseFormDialog({
    required this.initial,
    required this.branch,
    required this.canAttach,
    required this.gateway,
    required this.arabic,
    required this.onMessage,
  });
  @override
  State<_ExpenseFormDialog> createState() => _ExpenseFormDialogState();
}

class _ExpenseFormDialogState extends State<_ExpenseFormDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController amount;
  late final TextEditingController custom;
  late final TextEditingController note;
  late final TextEditingController reference;
  late DateTime expenseDate;
  DateTime? dueDate, repeatUntil;
  String category = 'rent', recurrence = 'none';
  PlatformFile? file;
  bool get ar => widget.arabic;
  String t(String a, String e) => ar ? a : e;

  @override
  void initState() {
    super.initState();
    final row = widget.initial ?? {};
    category = '${row['category'] ?? category}';
    expenseDate = DateTime.tryParse('${row['expense_date']}') ?? DateTime.now();
    dueDate = DateTime.tryParse('${row['due_date']}');
    recurrence = '${row['recurrence_rule'] ?? 'none'}';
    repeatUntil = DateTime.tryParse('${row['recurrence_until']}');
    amount = TextEditingController(text: '${row['amount'] ?? ''}');
    custom = TextEditingController(text: '${row['custom_category'] ?? ''}');
    note = TextEditingController(text: '${row['note'] ?? ''}');
    reference = TextEditingController(
      text: '${row['external_reference'] ?? ''}',
    );
  }

  @override
  void dispose() {
    amount.dispose();
    custom.dispose();
    note.dispose();
    reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initial == null
          ? t('مصروف جديد', 'New expense')
          : t('تعديل مصروف غير مدفوع', 'Edit unpaid expense'),
    ),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: InputDecoration(
                  labelText: t('التصنيف', 'Category'),
                ),
                items: [
                  for (final key in [
                    'rent',
                    'electricity',
                    'water',
                    'salary',
                    'commission',
                    'washing_supplies',
                    'maintenance',
                    'internet_telecom',
                    'marketing',
                    'other',
                  ])
                    DropdownMenuItem(
                      value: key,
                      child: Text(_categoryLabelLocal(key)),
                    ),
                ],
                onChanged: (v) => setState(() => category = v ?? category),
              ),
              if (category == 'other')
                TextFormField(
                  controller: custom,
                  decoration: InputDecoration(
                    labelText: t('اسم التصنيف', 'Custom category'),
                  ),
                  validator: (v) => (v?.trim().length ?? 0) < 2
                      ? t('اكتب تصنيفًا واضحًا.', 'Enter a category.')
                      : null,
                ),
              TextFormField(
                key: const ValueKey('finance-expense-amount'),
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: t('المبلغ EGP', 'Amount EGP'),
                ),
                validator: (v) {
                  final n = double.tryParse(v ?? '');
                  return n == null || !n.isFinite || n <= 0 || n > 999999999999
                      ? t('أدخل مبلغًا صالحًا.', 'Enter a valid amount.')
                      : null;
                },
              ),
              ListTile(
                title: Text(t('تاريخ المصروف', 'Expense date')),
                subtitle: Text(_dateKey(expenseDate)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: expenseDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) setState(() => expenseDate = d);
                },
              ),
              ListTile(
                title: Text(
                  t('تاريخ الاستحقاق (اختياري)', 'Due date (optional)'),
                ),
                subtitle: Text(
                  dueDate == null
                      ? t('غير محدد', 'Not set')
                      : _dateKey(dueDate!),
                ),
                trailing: const Icon(Icons.event),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: dueDate ?? expenseDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) setState(() => dueDate = d);
                },
              ),
              TextFormField(
                key: const ValueKey('finance-expense-reference'),
                controller: reference,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: t(
                    'رقم إيصال/مرجع لمنع التكرار (اختياري)',
                    'Receipt/reference to prevent duplicates (optional)',
                  ),
                ),
              ),
              TextFormField(
                key: const ValueKey('finance-expense-note'),
                controller: note,
                maxLines: 2,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: t('بيان المصروف', 'Expense description'),
                ),
              ),
              if (widget.initial == null)
                DropdownButtonFormField<String>(
                  initialValue: recurrence,
                  decoration: InputDecoration(
                    labelText: t('التكرار', 'Recurrence'),
                  ),
                  items: [
                    for (final p in [
                      ('none', 'بدون', 'None'),
                      ('daily', 'يومي', 'Daily'),
                      ('weekly', 'أسبوعي', 'Weekly'),
                      ('monthly', 'شهري', 'Monthly'),
                      ('yearly', 'سنوي', 'Yearly'),
                    ])
                      DropdownMenuItem(value: p.$1, child: Text(t(p.$2, p.$3))),
                  ],
                  onChanged: (v) => setState(() => recurrence = v ?? 'none'),
                ),
              if (widget.initial == null && recurrence != 'none')
                ListTile(
                  title: Text(t('تكرار حتى', 'Repeat until')),
                  subtitle: Text(
                    repeatUntil == null
                        ? t('اختر تاريخ النهاية', 'Choose end date')
                        : _dateKey(repeatUntil!),
                  ),
                  trailing: const Icon(Icons.event_repeat),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate:
                          repeatUntil ??
                          expenseDate.add(const Duration(days: 30)),
                      firstDate: expenseDate,
                      lastDate: expenseDate.add(const Duration(days: 365)),
                    );
                    if (d != null) setState(() => repeatUntil = d);
                  },
                ),
              if (widget.canAttach)
                OutlinedButton.icon(
                  onPressed: pickFile,
                  icon: const Icon(Icons.attach_file),
                  label: Text(
                    file?.name ??
                        (widget.initial?['attachment_path'] != null
                            ? t(
                                'الإيصال الحالي محفوظ',
                                'Current receipt stored',
                              )
                            : t(
                                'إرفاق إيصال PDF/صورة (حتى 5MB)',
                                'Attach PDF/image receipt (up to 5MB)',
                              )),
                  ),
                ),
              Text(
                t(
                  'الرواتب والعمولات المسجلة هنا لا تُرحّل آليًا إلى الرواتب؛ راجع مصدرًا واحدًا فقط لتجنب التكرار.',
                  'Salary/commission entries here are not auto-posted to payroll; use one source to avoid double counting.',
                ),
                style: const TextStyle(color: _financeBlue),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('إلغاء', 'Cancel')),
      ),
      FilledButton(onPressed: submit, child: Text(t('حفظ', 'Save'))),
    ],
  );

  String _categoryLabelLocal(String key) => switch (key) {
    'rent' => t('إيجار', 'Rent'),
    'electricity' => t('كهرباء', 'Electricity'),
    'water' => t('مياه', 'Water'),
    'salary' => t('رواتب', 'Salaries'),
    'commission' => t('عمولات', 'Commissions'),
    'washing_supplies' => t('مستلزمات الغسيل', 'Washing supplies'),
    'maintenance' => t('صيانة', 'Maintenance'),
    'internet_telecom' => t('إنترنت واتصالات', 'Internet & telecom'),
    'marketing' => t('تسويق وإعلانات', 'Marketing & ads'),
    _ => t('أخرى', 'Other'),
  };

  Future<void> pickFile() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
    );
    final picked = selected;
    if (picked == null) return;
    final size = await picked.length();
    if (size == null || size < 1 || size > 5 * 1024 * 1024) {
      widget.onMessage(
        t('الملف يجب ألا يتجاوز 5MB.', 'File must be 5MB or smaller.'),
      );
      return;
    }
    if (mounted) setState(() => file = picked);
  }

  void submit() {
    if (!formKey.currentState!.validate()) return;
    final parsed = double.parse(amount.text.trim());
    if (parsed * 100 != (parsed * 100).roundToDouble()) {
      widget.onMessage(
        t(
          'المبلغ يقبل منزلتين عشريتين فقط.',
          'Amount supports at most two decimal places.',
        ),
      );
      return;
    }
    if (recurrence != 'none' && repeatUntil == null) {
      widget.onMessage(
        t('اختر نهاية للتكرار.', 'Choose a recurrence end date.'),
      );
      return;
    }
    if (recurrence != 'none' &&
        repeatUntil!.difference(expenseDate).inDays > 365) {
      widget.onMessage(
        t(
          'حد التكرار سنة واحدة في كل طلب.',
          'Recurrence is limited to one year per request.',
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      _ExpenseFormResult(
        category: category,
        customCategory: custom.text.trim(),
        reference: reference.text.trim(),
        note: note.text.trim(),
        recurrence: recurrence,
        amount: parsed,
        expenseDate: expenseDate,
        dueDate: dueDate,
        recurrenceUntil: repeatUntil,
        file: file,
      ),
    );
  }
}
