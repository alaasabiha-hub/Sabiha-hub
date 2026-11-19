import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';

const _navy = Color(0xff071a36), _royal = Color(0xff174b83);
String _money(dynamic v) => v == null ? '—' : (v as num).toStringAsFixed(2);
List<Map<String, dynamic>> _rows(dynamic v) =>
    (v as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
String _requestId() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

String _date(DateTime d) => d.toIso8601String().substring(0, 10);

class PaymentPolicyScreen extends StatefulWidget {
  final SupabaseClient client;
  const PaymentPolicyScreen({super.key, required this.client});
  @override
  State<PaymentPolicyScreen> createState() => _PaymentPolicyState();
}

class _PaymentPolicyState extends State<PaymentPolicyScreen> {
  Map<String, dynamic>? data;
  String? error, service;
  String method = 'cash', mode = 'equal', request = _requestId();
  bool busy = false;
  final percent = TextEditingController(),
      fixed = TextEditingController(),
      value = TextEditingController(),
      price = TextEditingController();
  final Map<String, num> prices = {};
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  Map<String, dynamic> get current =>
      _rows(data?['policies'])
          .firstWhere((p) => p['method'] == method, orElse: () => {});
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [percent, fixed, value, price]) {
      c.dispose();
    }
    super.dispose();
  }

  void fill() {
    final c = current;
    percent.text = '${c['gateway_percent'] ?? ''}';
    fixed.text = '${c['gateway_fixed'] ?? ''}';
    value.text = '${c['proposed_value'] ?? 0}';
    mode = c['proposed_mode'] as String? ?? 'equal';
    prices.clear();
    final p = c['service_prices'] as Map? ?? {};
    p.forEach((k, v) {
      if (v is num) prices['$k'] = v;
    });
    price.text = '${prices[service] ?? ''}';
    request = _requestId();
  }

  Future<void> load() async {
    try {
      final d = Map<String, dynamic>.from(
        await widget.client.rpc('get_payment_policy_context') as Map,
      );
      if (!mounted) return;
      setState(() {
        data = d;
        error = null;
        service ??= _rows(d['services']).firstOrNull?['item_id']?.toString();
        fill();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is PostgrestException && e.code == '42501'
              ? 'denied'
              : 'load';
        });
      }
    }
  }

  num? number(String s) {
    var normalized = s.trim().replaceAll('٫', '.').replaceAll('٬', '');
    for (var i = 0; i < 10; i++) {
      normalized = normalized
          .replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i')
          .replaceAll('۰۱۲۳۴۵۶۷۸۹'[i], '$i');
    }
    final parsed = num.tryParse(normalized);
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  Future<void> save() async {
    final nums = [percent.text, fixed.text, value.text, price.text];
    if (nums.any(
          (s) => s.trim().isNotEmpty && (number(s) == null || number(s)! < 0),
        ) ||
        (number(percent.text) ?? 0) > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'أدخل قيماً رقمية غير سالبة؛ النسبة حتى 100',
              'Enter nonnegative numbers; percentage at most 100',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => busy = true);
    try {
      if (service != null && number(price.text) != null) {
        prices[service!] = number(price.text)!;
      }
      await widget.client.rpc(
        'save_payment_policy',
        params: {
          'p_request': request,
          'p_method': method,
          'p_previous': current['version_id'],
          'p_policy': {
            'gateway_percent': number(percent.text),
            'gateway_fixed': number(fixed.text),
            'proposed_mode': mode,
            'proposed_value': number(value.text) ?? 0,
            'service_prices': prices,
          },
        },
      );
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'حُفظ إصدار مستقبلي؛ رسوم العميل لم تتغير',
                'Future version saved; customer charges unchanged',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'تعذر الحفظ. أعد المحاولة؛ تعارض الإصدار يعيد تحميل أحدث نسخة',
                'Save failed. Retry; a version conflict reloads the latest version',
              ),
            ),
          ),
        );
        if (e is PostgrestException &&
            (e.code == '40001' ||
                e.code == 'P0001' ||
                e.code == '23505' ||
                e.message.toLowerCase().contains('stale'))) {
          await load();
        }
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = _rows(data?['services']);
    final selected = services.firstWhere(
      (s) => '${s['item_id']}' == service,
      orElse: () => {},
    );
    final base = (selected['price'] as num? ?? 0).toDouble();
    final proposed = mode == 'percent'
        ? base * (1 + (number(value.text) ?? 0) / 100)
        : mode == 'fixed'
        ? base + (number(value.text) ?? 0)
        : mode == 'service'
        ? (number(price.text) ?? prices[service] ?? base).toDouble()
        : base;
    final history = _rows(data?['history']);
    return _frame(
      context,
      t(
        'الإعدادات المالية · سياسة الدفع والعمولات',
        'Financial settings · Payment policy & commissions',
      ),
      error != null
          ? _failure(t, error!, load)
          : data == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  t(
                    'الأسعار الفعلية نقداً وبالبطاقة متساوية. لا رسوم إضافية على العميل؛ المنشأة تتحمل تكاليف البوابة.',
                    'Actual cash and card prices are equal. Customer surcharge is zero; merchant absorbs gateway costs.',
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'cash',
                      label: Text(t('نقدي', 'Cash')),
                    ),
                    ButtonSegment(
                      value: 'card',
                      label: Text(t('بطاقة', 'Card')),
                    ),
                  ],
                  selected: {method},
                  onSelectionChanged: busy
                      ? null
                      : (s) => setState(() {
                          method = s.first;
                          fill();
                        }),
                ),
                const SizedBox(height: 16),
                Text(
                  t(
                    'تقديرات تكلفة البوابة — ليست رسوماً فعلية مسجلة',
                    'Gateway cost estimates — not recorded actual fees',
                  ),
                ),
                _field(
                  percent,
                  t(
                    'نسبة البوابة التقديرية % (اختياري)',
                    'Estimated gateway % (optional)',
                  ),
                ),
                _field(
                  fixed,
                  t(
                    'تكلفة البوابة الثابتة التقديرية EGP (اختياري)',
                    'Estimated fixed gateway cost EGP (optional)',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: service,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('الخدمة الفعلية', 'Actual service'),
                  ),
                  items: services
                      .map(
                        (s) => DropdownMenuItem(
                          value: '${s['item_id']}',
                          child: Text(
                            '${s['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (service != null && number(price.text) != null) {
                      prices[service!] = number(price.text)!;
                    }
                    service = v;
                    price.text = '${prices[v] ?? ''}';
                  }),
                ),
                if (selected.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '${t('السعر الأساسي', 'Base price')}: ${_money(base)} EGP\n${t('النقدي الفعلي', 'Actual cash')}: ${_money(base)} EGP\n${t('البطاقة الفعلية', 'Actual card')}: ${_money(base)} EGP\n${t('رسوم العميل', 'Customer surcharge')}: 0.00 EGP',
                      ),
                    ),
                  ),
                Text(
                  t(
                    'مسودة مستقبلية معطلة — تتطلب الموافقات القانونية وموافقات الشبكة والبنك المستحوذ. الحفظ لا يفعّل الرسوم.',
                    'Disabled future draft — requires legal, network and acquirer approval. Saving does not activate surcharges.',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  key: ValueKey('$method-$mode'),
                  initialValue: mode,
                  decoration: InputDecoration(
                    labelText: t('نوع المسودة', 'Draft type'),
                  ),
                  items:
                      [
                            ('equal', t('متساوٍ', 'Equal')),
                            ('percent', t('نسبة', 'Percentage')),
                            ('fixed', t('مبلغ ثابت', 'Fixed amount')),
                            ('service', t('سعر لكل خدمة', 'Per-service price')),
                          ]
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.$1,
                              child: Text(p.$2),
                            ),
                          )
                          .toList(),
                  onChanged: (v) => setState(() => mode = v!),
                ),
                _field(value, t('قيمة المسودة', 'Draft value')),
                _field(
                  price,
                  t('سعر الخدمة المقترح EGP', 'Proposed service price EGP'),
                ),
                Text(
                  selected.isEmpty
                      ? t(
                          'لا توجد خدمة متاحة للمعاينة',
                          'No service is available for preview',
                        )
                      : '${t('معاينة مسودة معطلة', 'Disabled draft preview')}: ${_money(proposed)} EGP',
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(t('حفظ إصدار مستقبلي', 'Save future version')),
                ),
                const SizedBox(height: 24),
                Text(
                  t(
                    'سجل الإصدارات — لا تتغير الحجوزات السابقة',
                    'Version history — prior bookings unchanged',
                  ),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final h in history)
                  Builder(
                    builder: (_) {
                      final prior =
                          history
                              .where(
                                (p) =>
                                    p['method'] == h['method'] &&
                                    '${p['created_at']}'.compareTo(
                                          '${h['created_at']}',
                                        ) <
                                        0,
                              )
                              .toList()
                            ..sort(
                              (a, b) => '${b['created_at']}'.compareTo(
                                '${a['created_at']}',
                              ),
                            );
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '${h['owner_name'] ?? h['created_by']} · ${h['created_at']} · ${h['method']}\n${t('سابق', 'Previous')}: ${prior.isEmpty ? '—' : _policyDescription(prior.first)}\n${t('جديد', 'New')}: ${_policyDescription(h)}',
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }

  Widget _field(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    ),
  );
}

String _policyDescription(Map p) =>
    'gateway estimate ${p['gateway_percent'] ?? '—'}% + ${p['gateway_fixed'] ?? '—'}; draft ${p['proposed_mode']} ${p['proposed_value']}; services ${p['service_prices'] ?? {}}';
Widget _frame(BuildContext context, String title, Widget body) =>
    Directionality(
      textDirection: Localizations.localeOf(context).languageCode == 'ar'
          ? TextDirection.rtl
          : TextDirection.ltr,
      child: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.fromSeed(seedColor: _royal, primary: _royal),
          scaffoldBackgroundColor: const Color(0xffeef1f5),
        ),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: _navy,
            foregroundColor: Colors.white,
            title: Text(title),
            actions: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Image.asset(
                  'assets/sabiha_brand_approved.png',
                  width: 65,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: body,
            ),
          ),
        ),
      ),
    );
Widget _failure(
  String Function(String, String) t,
  String error,
  VoidCallback retry,
) => Center(
  child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          error == 'denied'
              ? t(
                  'هذه البيانات تتطلب صلاحية المالك',
                  'Owner access is required for this data',
                )
              : t(
                  'تعذر تحميل البيانات الفعلية',
                  'Unable to load recorded data',
                ),
        ),
        TextButton(onPressed: retry, child: Text(t('إعادة المحاولة', 'Retry'))),
      ],
    ),
  ),
);

class AiPaymentAnalyticsScreen extends StatefulWidget {
  final SupabaseClient client;
  const AiPaymentAnalyticsScreen({super.key, required this.client});
  @override
  State<AiPaymentAnalyticsScreen> createState() => _AnalyticsState();
}

class _AnalyticsState extends State<AiPaymentAnalyticsScreen> {
  Map<String, dynamic>? data;
  String? error;
  String period = 'day';
  DateTime from = DateTime.now().subtract(const Duration(days: 30)),
      to = DateTime.now();
  bool exporting = false;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => data = null);
    try {
      final d = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_ai_payment_analytics',
          params: {'p_from': _date(from), 'p_to': _date(to)},
        ) as Map,
      );
      if (mounted) {
        setState(() {
          data = d;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PostgrestException && e.code == '42501'
              ? 'denied'
              : 'load',
        );
      }
    }
  }

  Future<void> dates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: from, end: to),
    );
    if (range != null) {
      from = range.start;
      to = range.end;
      await load();
    }
  }

  Future<void> export() async {
    setState(() => exporting = true);
    try {
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildPaymentAnalyticsPdf(
        data!,
        font.buffer.asUint8List(),
        logo.buffer.asUint8List(),
        arabic: ar,
      );
      await FilePicker.saveFile(
        dialogTitle: t('تصدير التحليل', 'Export analytics'),
        fileName: 'payment-analytics-${_date(from)}.pdf',
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('تعذر تصدير الملف', 'Unable to export PDF')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Map<String, dynamic>.from(data?['summary'] as Map? ?? {});
    final series = _rows(data?['series'])
        .where((r) => r['period'] == period)
        .toList();
    return _frame(
      context,
      t('تحليلات الدفع الذكية', 'AI payment analytics'),
      error != null
          ? _failure(t, error!, load)
          : data == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: dates,
                      child: Text('${_date(from)} — ${_date(to)}'),
                    ),
                    FilledButton.icon(
                      onPressed: exporting ? null : export,
                      icon: const Icon(Icons.picture_as_pdf),
                      label: Text(t('تصدير PDF', 'Export PDF')),
                    ),
                  ],
                ),
                Text(
                  t(
                    'تحليل قائم على قواعد الأدلة؛ لا يوجد اتصال بنموذج ذكاء اصطناعي. بيانات الاختبار مستبعدة.',
                    'Evidence-based rules analysis; no AI model connection. Sandbox data excluded.',
                  ),
                ),
                if (data!['sufficient_data'] != true)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        t(
                          'البيانات غير كافية لاستنتاجات موثوقة. لا تثبت المقارنات سببية تغيّر السياسة.',
                          'Insufficient data for reliable conclusions. Comparisons do not establish that policy changes caused outcomes.',
                        ),
                      ),
                    ),
                  ),
                for (final m in _metrics)
                  ListTile(
                    title: Text(t(m.$2, m.$3)),
                    trailing: Text(
                      s[m.$1] == null
                          ? t('غير متاح', 'Unavailable')
                          : _money(s[m.$1]),
                    ),
                  ),
                Text(
                  t(
                    'المبيعات المفوترة تختلف عن التحصيل. الربح يتطلب تكاليف كاملة؛ التقديرات ليست رسوم بوابة فعلية.',
                    'Billed revenue differs from collections. Profit requires complete costs; estimates are not actual gateway fees.',
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'day',
                      label: Text(t('يومي', 'Daily')),
                    ),
                    ButtonSegment(
                      value: 'week',
                      label: Text(t('أسبوعي', 'Weekly')),
                    ),
                    ButtonSegment(
                      value: 'month',
                      label: Text(t('شهري', 'Monthly')),
                    ),
                  ],
                  selected: {period},
                  onSelectionChanged: (v) => setState(() => period = v.first),
                ),
                for (var i = 0; i < series.length; i++)
                  ListTile(
                    title: Text(
                      '${series[i]['date']} · ${series[i]['transactions']} ${t('عملية', 'transactions')}',
                    ),
                    subtitle: Text(
                      '${t('تحصيل / مسترد / صافي', 'Collected / refunded / net')}: ${_money(series[i]['cash_collections'])} / ${_money(series[i]['cash_refunds'])} / ${_money(series[i]['cash_net'])}${i == 0 ? '' : '\n${t('التغير عن الفترة السابقة', 'Change from prior period')}: ${_money((series[i]['cash_net'] as num? ?? 0) - (series[i - 1]['cash_net'] as num? ?? 0))}'}',
                    ),
                  ),
                if (data!['terminal_report_scope'] != null) ...[
                  Text(
                    t(
                      'ماكينة الكاشير — سجل التحصيل الموثق',
                      'Card terminal — verified collection ledger',
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    t(
                      'صافي التحصيل هنا قبل رسوم البنك. التسويات والرسوم والأرباح الفعلية غير مؤكدة حتى توافر مستنداتها.',
                      'Net collections here exclude bank fees. Settlements, actual fees and profit remain unverified until supporting records are available.',
                    ),
                  ),
                  for (final row in _rows(
                    data!['terminal_series'],
                  ).where((row) => row['period'] == period))
                    ListTile(
                      title: Text(
                        '${row['date']} · ${row['transactions']} ${t('عملية', 'transactions')}',
                      ),
                      subtitle: Text(
                        '${t('تحصيل / مسترد / صافي', 'Collected / refunded / net')}: ${_money(row['terminal_collections'])} / ${_money(row['terminal_refunds'])} / ${_money(row['terminal_net'])}',
                      ),
                    ),
                ],
                Text(
                  t('الخدمات', 'Services'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final r in _rows(data!['services']))
                  ListTile(
                    title: Text('${r['service_name']}'),
                    subtitle: Text(
                      '${t('صافي نقدي', 'Cash net')}: ${_money(r['cash_net'])} · ${t('فواتير', 'Invoices')}: ${r['invoices']} · ${t('الربح الفعلي غير متاح', 'Actual profit unavailable')}',
                    ),
                  ),
                Text(
                  t(
                    'مجموعات إصدارات السياسة — ارتباطات وصفية',
                    'Policy version cohorts — descriptive associations',
                  ),
                ),
                for (final r in _rows(data!['policy_cohorts']))
                  ListTile(
                    title: Text('${r['version_id']}'),
                    subtitle: Text(
                      '${t('حجوزات / مكتملة / تحويل', 'Bookings / completed / conversion')}: ${r['bookings']} / ${r['completed']} / ${_money(r['conversion_percent'])}%',
                    ),
                  ),
                for (final key in ['recommendations', 'alerts']) ...[
                  Text(
                    key == 'alerts'
                        ? t('تنبيهات', 'Alerts')
                        : t(
                            'توصيات قائمة على القواعد',
                            'Rules-based recommendations',
                          ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final r in _rows(data![key]))
                    ListTile(
                      leading: Icon(
                        key == 'alerts'
                            ? Icons.info_outline
                            : Icons.lightbulb_outline,
                      ),
                      title: Text(
                        '${r[ar ? 'message_ar' : 'message_en'] ?? r['code']}',
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}

const _metrics = [
  ('cash_collections', 'تحصيل نقدي EGP', 'Cash collections EGP'),
  ('cash_refunds', 'مسترد نقدي EGP', 'Cash refunds EGP'),
  ('cash_net', 'صافي نقدي EGP', 'Cash net EGP'),
  ('cash_count', 'عدد العمليات النقدية', 'Cash transaction count'),
  (
    'terminal_collections',
    'تحصيل ماكينة الكاشير EGP',
    'Card terminal collections EGP',
  ),
  ('terminal_refunds', 'مسترد ماكينة الكاشير EGP', 'Card terminal refunds EGP'),
  (
    'terminal_net',
    'صافي تحصيل الماكينة قبل رسوم البنك EGP',
    'Terminal net before bank fees EGP',
  ),
  ('terminal_count', 'عدد مدفوعات الماكينة', 'Card terminal payment count'),
  (
    'known_cash_terminal_net',
    'صافي النقدي والماكينة المسجل EGP',
    'Recorded cash and terminal net EGP',
  ),
  (
    'terminal_fees_actual',
    'رسوم الماكينة الفعلية غير المتاحة EGP',
    'Actual terminal fees unavailable EGP',
  ),
  ('card_collections', 'تحصيل البطاقة EGP', 'Card collections EGP'),
  (
    'gateway_fees_actual',
    'رسوم البوابة الفعلية EGP',
    'Actual gateway fees EGP',
  ),
  ('net_collections', 'صافي التحصيل EGP', 'Net collections EGP'),
  ('revenue_billed', 'الإيرادات المفوترة EGP', 'Billed revenue EGP'),
  ('expenses_recorded', 'المصروفات المسجلة EGP', 'Recorded expenses EGP'),
  ('actual_profit', 'الربح الفعلي EGP', 'Actual profit EGP'),
  ('cash_share_percent', 'حصة النقدي %', 'Cash share %'),
];

/// Exports only the supplied server snapshot; never estimates missing amounts.
Future<Uint8List> buildPaymentAnalyticsPdf(
  Map<String, dynamic> data,
  Uint8List fontBytes,
  Uint8List logo, {
  bool arabic = true,
}) async {
  final font = pw.Font.ttf(fontBytes.buffer.asByteData());
  final doc = pw.Document(title: 'Sabiha payment analytics');
  String t(String a, String e) => arabic ? a : e;
  final latin = pw.Font.helvetica();
  pw.Widget line(String text, {bool? rtl}) {
    final isRtl = rtl ?? arabic;
    return pw.Container(
      width: double.infinity,
      alignment: isRtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      child: pw.Text(
        text,
        textDirection: isRtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        style: pw.TextStyle(
          font: isRtl ? font : latin,
          fontFallback: [isRtl ? latin : font],
          fontSize: 10,
        ),
      ),
    );
  }

  pw.Widget metric(String label, dynamic value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(
            value == null ? t('غير متاح', 'Unavailable') : _money(value),
            textDirection: value == null && arabic
                ? pw.TextDirection.rtl
                : pw.TextDirection.ltr,
            style: pw.TextStyle(
              font: value == null && arabic ? font : latin,
              fontFallback: [font],
              fontSize: 10,
            ),
          ),
        ),
        pw.Expanded(
          flex: 2,
          child: pw.Text(
            label,
            textAlign: pw.TextAlign.right,
            textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
            style: pw.TextStyle(
              font: arabic ? font : latin,
              fontFallback: [latin, font],
              fontSize: 10,
            ),
          ),
        ),
      ],
    ),
  );
  final summary = Map<String, dynamic>.from(data['summary'] as Map? ?? {});
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        pw.Center(
          child: pw.Image(
            pw.MemoryImage(logo),
            width: 120,
            height: 80,
            fit: pw.BoxFit.contain,
          ),
        ),
        line(t('تحليلات الدفع', 'Payment analytics')),
        line(
          '${(data['period'] as Map?)?['from'] ?? '—'} - ${(data['period'] as Map?)?['to'] ?? '—'} · EGP',
          rtl: false,
        ),
        line(
          t(
            'قواعد أدلة؛ ليست استنتاجات سببية. بيانات الاختبار مستبعدة.',
            'Evidence rules; no causal conclusions. Sandbox excluded.',
          ),
        ),
        if (data['sufficient_data'] != true)
          line(
            t(
              'البيانات غير كافية لاستنتاجات موثوقة',
              'Insufficient data for reliable conclusions',
            ),
          ),
        for (final m in _metrics)
          if (arabic)
            metric(m.$2.replaceAll(' EGP', ''), summary[m.$1])
          else
            line(
              '${m.$3}: ${summary[m.$1] == null ? 'Unavailable' : _money(summary[m.$1])}',
            ),
        for (final r in _rows(data['series']))
          line(
            '${r['period']} ${r['date']} · ${t('تحصيل / مسترد / صافي / عدد', 'Collected / refunded / net / count')}: ${_money(r['cash_collections'])} / ${_money(r['cash_refunds'])} / ${_money(r['cash_net'])} / ${r['transactions']}',
          ),
        if (data['terminal_report_scope'] != null)
          line(
            t(
              'ماكينة الكاشير — صافي التحصيل قبل رسوم البنك، وليس ربحًا أو تسوية مصرفية.',
              'Card terminal — net collections before bank fees; not profit or a verified bank settlement.',
            ),
          ),
        for (final r in _rows(data['terminal_series']))
          line(
            '${r['period']} ${r['date']} · ${t('ماكينة الكاشير: تحصيل / مسترد / صافي', 'Terminal: collected / refunded / net')}: ${_money(r['terminal_collections'])} / ${_money(r['terminal_refunds'])} / ${_money(r['terminal_net'])}',
          ),
        for (final r in _rows(data['services']))
          line(
            '${r['service_name']} · ${t('صافي نقدي', 'Cash net')}: ${_money(r['cash_net'])} · ${t('فواتير', 'Invoices')}: ${r['invoices']} · ${t('الربح الفعلي غير متاح', 'Actual profit unavailable')}',
          ),
        for (final r in _rows(data['policy_cohorts']))
          line(
            '${r['version_id']} · ${r['bookings']} / ${r['completed']} / ${_money(r['conversion_percent'])}%',
          ),
        for (final key in ['recommendations', 'alerts']) ...[
          line(
            key == 'alerts'
                ? t('تنبيهات', 'Alerts')
                : t('توصيات قائمة على القواعد', 'Rules-based recommendations'),
          ),
          for (final r in _rows(data[key]))
            line('${r[arabic ? 'message_ar' : 'message_en'] ?? r['code']}'),
        ],
      ],
    ),
  );
  return doc.save();
}
