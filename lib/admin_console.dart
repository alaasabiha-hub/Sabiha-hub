import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'report_exports.dart';
import 'inventory_purchasing.dart';
import 'app_config.dart';
import 'welcome_ui.dart' show approvedBrandAsset;

const adminNavy = Color(0xff071a36),
    adminRoyal = Color(0xff174b83),
    adminSilver = Color(0xffc5cbd5),
    adminAccent = Color(0xffd4af37),
    adminInk = Color(0xff101820);
String adminText(BuildContext c, String ar, String en) =>
    Localizations.localeOf(c).languageCode == 'ar' ? ar : en;
const adminSections = [
  ('overview', 'نظرة عامة', 'Overview', Icons.speed),
  ('cashier', 'الكاشير', 'Cashier POS', Icons.point_of_sale),
  ('finance', 'المالية', 'Finance', Icons.account_balance_wallet_outlined),
  ('intelligence', 'Sabiha AI', 'Sabiha AI', Icons.auto_awesome),
  (
    'promotions',
    'العروض والولاء',
    'Offers & Loyalty',
    Icons.local_offer_outlined,
  ),
  ('reports', 'التقارير', 'Reports', Icons.analytics_outlined),
  ('products', 'المنتجات والخدمات', 'Products', Icons.shopping_cart_outlined),
  ('inventory', 'المخزون', 'Inventory', Icons.inventory_outlined),
  ('employees', 'الموظفون', 'Employees', Icons.groups_outlined),
  (
    'schedules',
    'الجداول والمواعيد',
    'Schedules',
    Icons.event_available_outlined,
  ),
  ('crm', 'إدارة العملاء', 'CRM', Icons.handshake_outlined),
  (
    'establishment',
    'الفروع والمنشآت',
    'Establishment',
    Icons.storefront_outlined,
  ),
  ('security', 'الأمان والصلاحيات', 'Security', Icons.shield_outlined),
  ('settings', 'الإعدادات', 'Settings', Icons.settings_outlined),
];
const adminReportTabs = [
  ('summary', 'ملخص المبيعات', 'Sales Summary'),
  ('operations', 'التشغيل', 'Operations'),
  ('hourly', 'المبيعات بالساعة', 'Hourly Sales'),
  ('mix', 'مزيج المبيعات', 'Product Mix'),
  ('history', 'سجل الطلبات', 'Order History'),
  ('payments', 'ملخص المدفوعات', 'Payment Summary'),
  ('other', 'تقارير أخرى', 'Other Reports'),
];

class AdminAction {
  final String section, ar, en;
  final IconData icon;
  final VoidCallback onTap;
  const AdminAction(this.section, this.ar, this.en, this.icon, this.onTap);
}

class AdminConsole extends StatefulWidget {
  final SupabaseClient client;
  final String initialSection, fullName;
  final String? profileAvatarUrl;
  final List<AdminAction> actions;
  final VoidCallback? onLogout;
  final Widget? notificationAction;
  final ValueChanged<String>? onLanguageChanged;
  const AdminConsole({
    super.key,
    required this.client,
    this.initialSection = 'overview',
    this.fullName = '',
    this.profileAvatarUrl,
    this.actions = const [],
    this.onLogout,
    this.notificationAction,
    this.onLanguageChanged,
  });
  @override
  State<AdminConsole> createState() => _AdminConsoleState();
}

class _AdminConsoleState extends State<AdminConsole> {
  Map<String, dynamic>? data;
  Map<String, dynamic>? previousPeriodData;
  String? error, branch, employee, service, method;
  String section = 'overview', tab = 'summary';
  bool busy = true,
      exporting = false,
      filters = false,
      expanded = false,
      comparing = false;
  String? language;
  bool _initialWindowChecked = false;
  late DateTime start, end;
  final search = TextEditingController();
  List<Map<String, dynamic>> branchOptions = [], staffOptions = [];
  List<String> serviceOptions = [];
  List<Map<String, dynamic>> rows(String key) =>
      List<Map<String, dynamic>>.from(data?[key] ?? []);
  Map<String, dynamic> get report =>
      Map<String, dynamic>.from(data?['report'] ?? {});
  String t(String ar, String en) => language == 'ar' ? ar : en;
  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String money(dynamic v) {
    final number = num.tryParse('$v');
    if (number == null || !number.isFinite) {
      return t('غير مسجل / غير مكتمل', 'Not recorded / incomplete');
    }
    return '${number.toStringAsFixed(2)} EGP';
  }

  @override
  void initState() {
    super.initState();
    section = widget.initialSection;
    final now = DateTime.now();
    start = DateTime(now.year, now.month, 1);
    end = DateTime(now.year, now.month, now.day + 1);
    load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    language ??= Localizations.localeOf(context).languageCode;
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
      data = null;
      previousPeriodData = null;
    });
    try {
      if (!AppConfig.multiBranchEnabled && branch == null) {
        branch = await widget.client.rpc('default_branch_id') as String?;
        if (branch == null) throw StateError('Default branch unavailable');
      }
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_admin_console',
          params: {
            'p_from_local': '${day(start)}T00:00:00',
            'p_to_local': '${day(end)}T00:00:00',
            'p_branch': branch,
            'p_employee': employee,
            'p_service': service,
            'p_method': method,
            'p_search': search.text.trim(),
          },
        ),
      );
      if (!mounted) return;
      final accountingDay = DateTime.tryParse('${result['today_cairo']}');
      if (!_initialWindowChecked && accountingDay != null) {
        _initialWindowChecked = true;
        final first = DateTime(accountingDay.year, accountingDay.month, 1);
        final until = DateTime(
          accountingDay.year,
          accountingDay.month,
          accountingDay.day + 1,
        );
        if (start != first || end != until) {
          setState(() {
            start = first;
            end = until;
          });
          await load();
          return;
        }
      }
      setState(() {
        data = result;
        if (branch == null) {
          branchOptions = List<Map<String, dynamic>>.from(result['branches']);
        }
        staffOptions = List<Map<String, dynamic>>.from(result['staff']);
        if (service == null) {
          serviceOptions = List<Map<String, dynamic>>.from(result['catalog'])
              .map((s) => '${s['name']}')
              .toSet()
              .toList();
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          data = null;
          error = 'denied';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dates() async {
    final range = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: start, end: end),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (range == null || !mounted) return;
    if (range.end.difference(range.start).inDays > 366 ||
        !range.end.isAfter(range.start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'اختر فترة من يوم إلى 366 يومًا؛ تاريخ النهاية غير مشمول.',
              'Choose 1–366 days; end date is exclusive.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() {
      start = range.start;
      end = range.end;
    });
    await load();
  }

  Future<void> preset(int offset) async {
    final now = DateTime.tryParse('${data?['today_cairo']}');
    if (now == null) return;
    setState(() {
      start = DateTime(now.year, now.month, now.day + offset);
      end = start.add(const Duration(days: 1));
    });
    await load();
  }

  Future<void> presetPeriod(String period) async {
    final now = DateTime.tryParse('${data?['today_cairo']}');
    if (now == null) return;
    final today = DateTime(now.year, now.month, now.day);
    final from = switch (period) {
      'week' => today.subtract(Duration(days: today.weekday - 1)),
      'month' => DateTime(today.year, today.month),
      'year' => DateTime(today.year),
      _ => today,
    };
    setState(() {
      start = from;
      end = today.add(const Duration(days: 1));
    });
    await load();
  }

  Future<void> comparePreviousPeriod() async {
    if (busy || comparing || data?['financial'] != true) return;
    final spanDays = end.difference(start).inDays;
    if (spanDays < 1 || spanDays > 366) return;
    setState(() => comparing = true);
    try {
      final previousStart = start.subtract(Duration(days: spanDays));
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_admin_console',
          params: {
            'p_from_local': '${day(previousStart)}T00:00:00',
            'p_to_local': '${day(start)}T00:00:00',
            'p_branch': branch,
            'p_employee': employee,
            'p_service': service,
            'p_method': method,
            'p_search': search.text.trim(),
          },
        ),
      );
      if (mounted && result['financial'] == true) {
        setState(() => previousPeriodData = result);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'تعذرت مقارنة الفترة السابقة.',
                'Could not load the previous period for comparison.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => comparing = false);
    }
  }

  Future<void> export(String kind) async {
    if (data == null || data!['financial'] != true || busy || exporting) return;
    setState(() => exporting = true);
    try {
      final snapshot = {
        ...report,
        ...{
          for (final k in [
            'from_local',
            'to_local',
            'branch_id',
            'as_of',
            'currency',
            'time_zone',
          ])
            k: data![k],
        },
        'filters': {
          'employee': employee,
          'service': service,
          'method': method,
          'search': search.text.trim(),
        },
        'invoices': rows('invoices'),
        'payment_events': rows('payments'),
        'shifts': rows('shifts'),
        'bookings': rows('bookings'),
        if (previousPeriodData != null && data?['role'] == 'owner')
          'period_comparison': {
            'from_local': previousPeriodData!['from_local'],
            'to_local': previousPeriodData!['to_local'],
            'metrics': [
              for (final metric in ownerPeriodComparison(
                data!,
                previousPeriodData!,
              ))
                {
                  'key': metric.key,
                  'current': metric.current,
                  'previous': metric.previous,
                  'change': metric.change,
                  'change_percent': metric.changePercent,
                },
            ],
          },
      };
      if (kind == 'xlsx') {
        final bytes = buildSalesReportWorkbook(snapshot, rtl: language == 'ar');
        await FilePicker.saveFile(
          fileName: 'sabiha_admin_${day(start)}.xlsx',
          bytes: bytes,
          mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
      } else {
        final bytes = await buildSalesReportPdf(
          snapshot,
          (await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf')).buffer
              .asUint8List(),
          (await rootBundle.load('assets/sabiha_brand_approved.png')).buffer
              .asUint8List(),
        );
        if (kind == 'print') {
          await Printing.layoutPdf(onLayout: (_) => bytes);
        } else {
          await FilePicker.saveFile(
            fileName: 'sabiha_admin_${day(start)}.pdf',
            bytes: bytes,
            mimeType: 'application/pdf',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('تعذر التصدير. حاول مجددًا.', 'Export failed. Please retry.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Widget choice(
    String label,
    String? value,
    List<(String, String)> options,
    ValueChanged<String?> change,
  ) => SizedBox(
    width: 220,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(t('الكل', 'All'))),
        for (final o in options)
          DropdownMenuItem(
            value: o.$1,
            child: Text(o.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy ? null : change,
    ),
  );
  Widget languageControl(bool compact) => TextButton(
    style: compact
        ? TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          )
        : null,
    onPressed: () {
      setState(() => language = language == 'ar' ? 'en' : 'ar');
      widget.onLanguageChanged?.call(language!);
    },
    child: Text(
      language == 'ar' ? 'English' : 'العربية',
      style: const TextStyle(color: Colors.white),
    ),
  );
  Widget logoutControl() => IconButton(
    tooltip: t('تسجيل الخروج', 'Log out'),
    onPressed: widget.onLogout,
    icon: const Icon(Icons.logout, color: Colors.white),
  );
  Widget header() => LayoutBuilder(
    builder: (c, box) => Column(
      children: [
        Container(
          color: adminNavy,
          padding: EdgeInsets.symmetric(
            horizontal: box.maxWidth < 600 ? 12 : 24,
            vertical: 12,
          ),
          child: Row(
            textDirection: TextDirection.ltr,
            children: [
              Container(
                key: const ValueKey('admin-full-original-logo'),
                width: box.maxWidth < 600 ? 110 : 160,
                height: box.maxWidth < 600 ? 94 : 136,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: adminSilver),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Image.asset(
                  approvedBrandAsset,
                  fit: BoxFit.contain,
                  semanticLabel: 'Sabiha Hub original complete logo',
                ),
              ),
              SizedBox(width: box.maxWidth < 600 ? 8 : 12),
              Expanded(
                child: Column(
                  textDirection: TextDirection.ltr,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      key: const ValueKey('admin-brand-name-fit'),
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Sabiha Hub',
                        key: const ValueKey('admin-brand-name'),
                        maxLines: 1,
                        softWrap: false,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: box.maxWidth < 600 ? 20 : 26,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (box.maxWidth >= 600)
                      const Text(
                        'A New Concept in Total Care',
                        style: TextStyle(fontSize: 11, color: Colors.white),
                      ),
                    if (box.maxWidth < 600)
                      Wrap(
                        textDirection: TextDirection.ltr,
                        children: [
                          languageControl(true),
                          if (widget.notificationAction != null)
                            widget.notificationAction!,
                          if (widget.onLogout != null) logoutControl(),
                        ],
                      ),
                  ],
                ),
              ),
              if (box.maxWidth >
                  (widget.notificationAction == null ? 650 : 820))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.profileAvatarUrl != null) ...[
                      CircleAvatar(
                        radius: 19,
                        backgroundColor: adminRoyal,
                        foregroundImage: NetworkImage(widget.profileAvatarUrl!),
                        child: const Icon(
                          Icons.person_outline,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Tooltip(
                        message: widget.fullName,
                        child: Text(
                          '${widget.fullName}\n${data?['role'] ?? ''}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              if (box.maxWidth >= 600) ...[
                const SizedBox(width: 16),
                languageControl(false),
                if (widget.notificationAction != null)
                  widget.notificationAction!,
                if (widget.onLogout != null) logoutControl(),
              ],
            ],
          ),
        ),
        Container(
          color: adminInk,
          child: LayoutBuilder(
            builder: (c, b) {
              if (b.maxWidth < 600) {
                final selected = adminSections.firstWhere(
                  (s) => s.$1 == section,
                );
                return SizedBox(
                  height: 64,
                  child: Builder(
                    builder: (navContext) => Row(
                      children: [
                        IconButton(
                          key: const ValueKey('admin-mobile-menu'),
                          tooltip: t(
                            'فتح أقسام لوحة المالك',
                            'Open owner menu',
                          ),
                          onPressed: () => Scaffold.of(navContext).openDrawer(),
                          icon: const Icon(Icons.menu, color: Colors.white),
                        ),
                        Icon(selected.$4, color: adminAccent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t(selected.$2, selected.$3),
                            key: const ValueKey('admin-mobile-current-section'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                );
              }
              final w = math.max(110.0, b.maxWidth / adminSections.length);
              return SizedBox(
                height: 108,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: SingleChildScrollView(
                    key: const ValueKey('admin-section-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      textDirection: TextDirection.ltr,
                      children: [
                        for (final s in adminSections)
                          SizedBox(
                            width: w,
                            height: 108,
                            child: Material(
                              color: section == s.$1 ? adminNavy : adminInk,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: section == s.$1
                                          ? adminAccent
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                child: InkWell(
                                  key: ValueKey('admin-nav-${s.$1}'),
                                  onTap: () => setState(() => section = s.$1),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        s.$4,
                                        size: 32,
                                        color: section == s.$1
                                            ? adminAccent
                                            : adminSilver,
                                      ),
                                      const SizedBox(height: 9),
                                      Text(
                                        t(s.$2, s.$3),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: section == s.$1
                                              ? adminAccent
                                              : Colors.white,
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
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          color: Colors.white,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 18,
            runSpacing: 8,
            children: [
              if (AppConfig.multiBranchEnabled)
                choice(
                  t('الفرع', 'Establishment'),
                  branch,
                  [
                    for (final b in branchOptions)
                      (
                        '${b['branch_id']}',
                        '${b[language == 'ar' ? 'name_ar' : 'name_en']}',
                      ),
                  ],
                  (v) {
                    setState(() {
                      branch = v;
                      employee = null;
                      service = null;
                    });
                    load();
                  },
                ),
              Text(
                t(
                  'EGP · توقيت القاهرة · بيانات حسب الصلاحيات',
                  'EGP · Cairo time · Authorized data only',
                ),
                style: const TextStyle(color: Colors.blueGrey),
              ),
              IconButton(
                tooltip: t('تحديث', 'Refresh'),
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if ({
          'localhost',
          '127.0.0.1',
          '10.0.2.2',
          '::1',
        }.contains(Uri.parse(AppConfig.supabaseUrl).host))
          Container(
            width: double.infinity,
            color: const Color(0xfffff2cc),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Text(
              t(
                'بيئة تطوير محلية — السجلات للاختبار وليست تقارير أعمال معتمدة.',
                'Local development — test records, not approved business reports.',
              ),
              style: const TextStyle(fontSize: 12, color: Color(0xff725514)),
            ),
          ),
      ],
    ),
  );
  Widget band(String title, {Widget? trailing}) => Container(
    color: adminNavy,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 24,
      runSpacing: 12,
      children: [
        Text(title, style: const TextStyle(fontSize: 22, color: Colors.white)),
        ?trailing,
      ],
    ),
  );
  Widget panel(String title, Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffd7dee3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: const Color(0xffeef1f5),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Text(
            title,
            style: const TextStyle(fontSize: 20, color: adminRoyal),
          ),
        ),
        child,
      ],
    ),
  );
  Widget notice(String ar, String en) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      t(ar, en),
      style: const TextStyle(color: Colors.blueGrey, height: 1.5),
    ),
  );
  Widget period() => Wrap(
    spacing: 10,
    runSpacing: 8,
    children: [
      OutlinedButton(
        onPressed: busy ? null : () => preset(0),
        child: Text(t('اليوم', 'Today')),
      ),
      OutlinedButton(
        onPressed: busy ? null : () => preset(-1),
        child: Text(t('أمس', 'Yesterday')),
      ),
      OutlinedButton(
        key: const ValueKey('period-this-week'),
        onPressed: busy ? null : () => presetPeriod('week'),
        child: Text(t('هذا الأسبوع', 'This week')),
      ),
      OutlinedButton(
        key: const ValueKey('period-this-month'),
        onPressed: busy ? null : () => presetPeriod('month'),
        child: Text(t('هذا الشهر', 'This month')),
      ),
      OutlinedButton(
        key: const ValueKey('period-this-year'),
        onPressed: busy ? null : () => presetPeriod('year'),
        child: Text(t('هذه السنة', 'This year')),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : dates,
        icon: const Icon(Icons.date_range),
        label: Text('${t('مخصص', 'Custom')} · ${day(start)} — ${day(end)}'),
      ),
    ],
  );
  Widget filterBar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => setState(() => filters = !filters),
              icon: const Icon(Icons.tune),
              label: Text(t('التصفية', 'Filters')),
            ),
            Text(
              t('تاريخ النهاية غير مشمول', 'End date is exclusive'),
              style: const TextStyle(color: Colors.blueGrey),
            ),
            if (data?['financial'] == true) ...[
              OutlinedButton.icon(
                onPressed: exporting ? null : () => export('pdf'),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF'),
              ),
              OutlinedButton.icon(
                onPressed: exporting ? null : () => export('xlsx'),
                icon: const Icon(Icons.table_view_outlined),
                label: const Text('Excel'),
              ),
              IconButton(
                tooltip: t('نسخ CSV', 'Copy CSV'),
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  final lines = [
                    'hour_cairo,active_invoice_value_egp,refunded_invoice_value_egp,verified_completed_service_visits',
                    for (final r in report['hourly'] as List? ?? [])
                      '${r['hour']},${r['net_billed']},${r['refunded_invoice_value']},${r['completed_service_visits'] ?? 0}',
                  ];
                  await Clipboard.setData(
                    ClipboardData(text: lines.join('\n')),
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t('تم نسخ CSV', 'CSV copied'))),
                    );
                  }
                },
              ),
              OutlinedButton.icon(
                onPressed: exporting ? null : () => export('print'),
                icon: const Icon(Icons.print_outlined),
                label: Text(t('طباعة A4', 'Print A4')),
              ),
              Tooltip(
                message: t(
                  'خدمة البريد للتقارير غير مهيأة بعد',
                  'Report email delivery is not configured',
                ),
                child: TextButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.mail_outline),
                  label: Text(t('بريد إلكتروني', 'Email')),
                ),
              ),
            ],
          ],
        ),
      ),
      if (filters)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              choice(
                t('الموظف', 'Employee'),
                employee,
                [
                  for (final s in staffOptions)
                    ('${s['user_id']}', '${s['full_name']}'),
                ],
                (v) {
                  setState(() => employee = v);
                  load();
                },
              ),
              choice(
                t('الخدمة', 'Service'),
                service,
                [for (final s in serviceOptions) (s, s)],
                (v) {
                  setState(() => service = v);
                  load();
                },
              ),
              choice(
                t('وسيلة الدفع', 'Payment method'),
                method,
                [
                  ('cash', t('نقدي', 'Cash')),
                  (
                    'electronic',
                    t('إلكتروني غير مفصل', 'Electronic, unclassified'),
                  ),
                ],
                (v) {
                  setState(() => method = v);
                  load();
                },
              ),
              SizedBox(
                width: 300,
                child: TextField(
                  controller: search,
                  onSubmitted: (_) => load(),
                  decoration: InputDecoration(
                    labelText: t(
                      'رقم الفاتورة أو الخدمة',
                      'Invoice or service',
                    ),
                    suffixIcon: IconButton(
                      onPressed: load,
                      icon: const Icon(Icons.search),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
  Widget metric(String label, String value) => Padding(
    padding: const EdgeInsets.all(18),
    child: Column(
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.blueGrey),
        ),
        const SizedBox(height: 12),
        Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 27, color: adminInk),
        ),
      ],
    ),
  );
  num paymentTotal(String method, {String event = 'sale'}) =>
      rows('payments')
          .where((p) => p['method'] == method && p['event_type'] == event)
          .fold<num>(0, (s, p) => s + (p['amount'] as num));
  Widget overview() {
    final cash = report['cash_activity'] as Map? ?? {};
    final shortcuts = widget.actions
        .where(
          (action) => const {
            'cashier',
            'finance',
            'intelligence',
            'promotions',
          }.contains(action.section),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shortcuts.isNotEmpty)
          panel(
            t('وصول سريع للمالك', 'Owner quick access'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final action in shortcuts)
                  FilledButton.icon(
                    key: ValueKey('owner-quick-${action.en}'),
                    onPressed: action.onTap,
                    icon: Icon(action.icon),
                    label: Text(t(action.ar, action.en)),
                    style: FilledButton.styleFrom(
                      backgroundColor: adminNavy,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(180, 52),
                    ),
                  ),
              ],
            ),
          ),
        band(
          t('نظرة عامة على المدفوعات', 'Payments Overview'),
          trailing: Theme(
            data: Theme.of(context).copyWith(
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xffeef1f5),
                  foregroundColor: adminRoyal,
                ),
              ),
            ),
            child: period(),
          ),
        ),
        if (data?['financial'] != true)
          notice(
            'حسابك يعرض المهام المعينة فقط؛ التقارير المالية غير مصرح بها.',
            'Your account shows assigned work only; financial reports are not authorized.',
          )
        else ...[
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(22),
            child: LayoutBuilder(
              builder: (c, b) {
                final total = metric(
                  t('إجمالي المدفوعات', 'Total Payments'),
                  money(cash['collections']),
                );
                final chart = AdminTrendChart(
                  payments: rows('payments'),
                  arabic: language == 'ar',
                );
                return b.maxWidth > 800
                    ? Row(
                        textDirection: TextDirection.ltr,
                        children: [
                          SizedBox(width: 240, child: total),
                          Expanded(child: chart),
                        ],
                      )
                    : Column(children: [total, chart]);
              },
            ),
          ),
          Container(
            color: Colors.white,
            child: Wrap(
              alignment: WrapAlignment.spaceAround,
              children: [
                metric(t('النقدي', 'Cash'), money(paymentTotal('cash'))),
                metric(
                  t('إلكتروني غير مفصل', 'Electronic, unclassified'),
                  money(paymentTotal('electronic')),
                ),
                metric(
                  t('إجمالي الخصومات', 'Total Discounts'),
                  money(report['discounts']),
                ),
                metric(
                  t('الضرائب المسجلة', 'Recorded Sales Tax'),
                  money(report['taxes']),
                ),
                metric(
                  t('صافي المبيعات', 'Net Sales'),
                  money(report['net_sales_ex_tax']),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          panel(
            t('مؤشرات العملاء والمعاملات', 'Customer & Transaction Insights'),
            Wrap(
              alignment: WrapAlignment.spaceAround,
              children: [
                metric(
                  t('العملاء المرتبطون بالفروع', 'Branch-linked customers'),
                  '${rows('customers').length}',
                ),
                metric(
                  t('حركات الدفع', 'Payment events'),
                  '${cash['transaction_count'] ?? 0}',
                ),
                metric(
                  t('متوسط الفاتورة', 'Average Invoice'),
                  money(report['average_invoice']),
                ),
              ],
            ),
          ),
          notice(
            'الفواتير حسب وقت الإصدار، والمدفوعات حسب وقت التحصيل. لا تُصنف المدفوعات الإلكترونية كبطاقات ائتمان أو خصم دون سجل موثوق.',
            'Invoices use issue time; payments use collection time. Electronic payments are not classified as credit/debit without a reliable record.',
          ),
        ],
        panel(
          t('التشغيل', 'Operations'),
          table(rows('bookings'), [
            ('service_name', 'الخدمة', 'Service'),
            ('booking_date', 'التاريخ', 'Date'),
            ('status', 'الحالة', 'Status'),
          ]),
        ),
      ],
    );
  }

  Widget detailRow(
    String ar,
    String en,
    String value,
    List<Widget> children, {
    bool highlight = false,
  }) => Material(
    color: highlight ? const Color(0xffedf1f4) : Colors.white,
    child: ExpansionTile(
      key: ValueKey('$en-$expanded'),
      initiallyExpanded: expanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(
        t(ar, en),
        style: TextStyle(
          fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: Text(
        value,
        style: TextStyle(
          fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      children: children.isEmpty
          ? [
              notice(
                'لا توجد تفاصيل مسجلة لهذه الفترة.',
                'No details recorded in this period.',
              ),
            ]
          : children,
    ),
  );
  Widget periodComparison() {
    final prior = previousPeriodData;
    final current = data;
    final metrics = prior == null || current == null
        ? const <ReportComparisonMetric>[]
        : ownerPeriodComparison(current, prior);
    String label(String key) => switch (key) {
      'net_billed' => t('صافي الفواتير', 'Net billed'),
      'discounts' => t('الخصومات', 'Discounts'),
      'refunded_invoice_value' => t(
        'قيمة الفواتير المستردة',
        'Refunded invoice value',
      ),
      'expenses' => t('المصروفات المسجلة', 'Recorded expenses'),
      _ => t('الربح الفعلي', 'Actual profit'),
    };
    String changeLabel(ReportComparisonMetric metric) {
      final change = metric.change;
      if (change == null) return money(null);
      final sign = change > 0 ? '+' : '';
      final percent = metric.changePercent;
      return percent == null
          ? '$sign${change.toStringAsFixed(2)} EGP'
          : '$sign${change.toStringAsFixed(2)} EGP · $sign${percent.toStringAsFixed(1)}%';
    }

    return panel(
      t('مقارنة بالفترة السابقة', 'Previous period comparison'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('compare-previous-period'),
              onPressed: comparing || busy ? null : comparePreviousPeriod,
              icon: comparing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.compare_arrows),
              label: Text(
                t('مقارنة بعدد أيام مماثل', 'Compare equal-length periods'),
              ),
            ),
          ),
          if (prior != null) ...[
            Text(
              t(
                'الحالية ${day(start)} — ${day(end)} · السابقة ${prior['from_local']} — ${prior['to_local']}',
                'Current ${day(start)} — ${day(end)} · Previous ${prior['from_local']} — ${prior['to_local']}',
              ),
            ),
            for (final metric in metrics)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      label(metric.key),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${t('الحالية', 'Current')}: ${money(metric.current)}',
                        ),
                        Text(
                          '${t('السابقة', 'Previous')}: ${money(metric.previous)}',
                        ),
                        Text(
                          '${t('التغير', 'Change')}: ${changeLabel(metric)}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            Text(
              t(
                'المقارنة وصفية؛ القيم غير المسجلة لا تُعامل كصفر، والربح لا يظهر دون بيانات تكلفة ورواتب مكتملة.',
                'Comparison is descriptive. Missing values are not zero; profit requires complete cost and payroll data.',
              ),
              style: const TextStyle(color: Colors.blueGrey),
            ),
          ],
        ],
      ),
    );
  }

  Widget summary() => LayoutBuilder(
    builder: (c, b) {
      final main = panel(
        t('تقرير ملخص المبيعات', 'Sales Summary Report'),
        Column(
          children: [
            detailRow(
              'صافي المبيعات',
              'Net Sales',
              money(report['net_sales_ex_tax']),
              [
                kv(
                  t('قبل الخصم', 'Before discount'),
                  money(report['billed_before_discount']),
                ),
                kv(t('الخصومات', 'Discounts'), money(report['discounts'])),
                if (report['contains_reviewed_cashier'] == true) ...[
                  kv(
                    t('أثر الخصم على الضريبة', 'Discount tax effect'),
                    money(report['discount_tax_effect_recorded']),
                  ),
                  kv(
                    t('استردادات الفواتير النشطة', 'Active invoice refunds'),
                    money(report['cashier_refunds_on_active_invoices']),
                  ),
                  if (report['unpaid_credits_are_not_cash_refunds'] ==
                      true) ...[
                    kv(
                      t(
                        'تسويات الخدمات غير المدفوعة',
                        'Unpaid service credits',
                      ),
                      money(report['unpaid_service_credits']),
                    ),
                    kv(
                      t('الضريبة ضمن التسويات', 'Tax included in credits'),
                      money(report['unpaid_credit_tax']),
                    ),
                  ],
                  if (report['commissions'] is num)
                    kv(
                      t(
                        'عمولات الخدمات المكتملة',
                        'Earned service commissions',
                      ),
                      money(report['commissions']),
                    ),
                  if (report['cashier_commissions_earned_in_period'] is num)
                    kv(
                      t(
                        'عمولات حسب وقت الإكمال خلال الفترة',
                        'Commissions earned by completion time in period',
                      ),
                      money(report['cashier_commissions_earned_in_period']),
                    ),
                ],
                kv(
                  t('قيمة الفواتير النشطة', 'Net active invoice value'),
                  money(report['net_billed']),
                ),
              ],
            ),
            detailRow(
              'الضرائب والرسوم',
              'Total Tax and Surcharges',
              report['taxes'] == null || report['fees'] == null
                  ? money(null)
                  : money((report['taxes'] as num) + (report['fees'] as num)),
              [
                kv(t('الضرائب', 'Tax'), money(report['taxes'])),
                kv(t('الرسوم', 'Fees'), money(report['fees'])),
              ],
            ),
            detailRow('الالتزامات', 'Liabilities', money(null), [
              notice(
                'دفتر الالتزامات غير مكتمل؛ لا يُفترض أن القيمة صفر.',
                'The liabilities ledger is incomplete; zero is not assumed.',
              ),
            ]),
            detailRow(
              'صافي المبلغ المطلوب تسويته',
              'Net to Account For',
              money(null),
              [
                notice(
                  'يحتاج إلى دفتر التزامات وتسويات مكتمل.',
                  'Requires complete liabilities and settlement records.',
                ),
              ],
              highlight: true,
            ),
            detailRow('النقدي', 'Cash', money(paymentTotal('cash')), [
              paymentTable('cash'),
            ]),
            detailRow('بطاقات ائتمانية', 'Credit', money(null), [
              notice(
                'الوسيلة الإلكترونية الحالية لا تتضمن نوع البطاقة.',
                'Current electronic records do not specify card type.',
              ),
            ]),
            detailRow('بطاقات خصم', 'Debit', money(null), [
              notice(
                'لا يوجد تفصيل موثوق لبطاقات الخصم.',
                'A reliable debit-card breakdown is unavailable.',
              ),
            ]),
            detailRow(
              'مدفوعات إلكترونية غير مفصلة',
              'Custom / Unclassified Electronic',
              money(paymentTotal('electronic')),
              [paymentTable('electronic')],
            ),
            detailRow(
              'إجمالي المدفوعات',
              'Total Payments',
              money((report['cash_activity'] as Map?)?['collections']),
              [
                kv(
                  t('استردادات مسجلة', 'Recorded refunds'),
                  money((report['cash_activity'] as Map?)?['refunds']),
                ),
              ],
              highlight: true,
            ),
          ],
        ),
      );
      final analytics = analyticsPanel();
      final reportLayout = b.maxWidth >= 1050
          ? Row(
              textDirection: TextDirection.ltr,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: main),
                const SizedBox(width: 28),
                Expanded(flex: 4, child: analytics),
              ],
            )
          : Column(children: [main, analytics]);
      return Column(
        children: [
          if (data?['role'] == 'owner' && data?['financial'] == true)
            periodComparison(),
          reportLayout,
        ],
      );
    },
  );
  Widget kv(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    child: Row(
      children: [
        Expanded(child: Text(key)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
  Widget analyticsPanel() => panel(
    t('التحليلات', 'Analytics'),
    Column(
      children: [
        kv(
          t('عدد حركات الدفع', 'Payment Transaction Count'),
          '${(report['cash_activity'] as Map?)?['transaction_count'] ?? 0}',
        ),
        kv(
          t('عدد الفواتير النشطة', 'Active Invoice Count'),
          '${report['invoice_count'] ?? 0}',
        ),
        kv(
          t('متوسط قيمة الفاتورة', 'Average Check'),
          money(report['average_invoice']),
        ),
        detailRow('المبيعات حسب الخدمة والمنتج', 'Order Type Breakdown', '', [
          table(List<Map<String, dynamic>>.from(report['product_mix'] ?? []), [
            ('service_name', 'الخدمة / المنتج', 'Service / product'),
            ('invoices', 'العدد', 'Count'),
            ('total', 'EGP', 'EGP'),
          ]),
        ]),
        detailRow(
          'المدفوعات حسب الوسيلة والحالة',
          'Payments by Method and Status',
          '',
          [paymentTable(null)],
        ),
        detailRow('تفصيل الخصومات', 'Counted Discounts', '', [
          table(
            rows('invoices')
                .where((i) => (i['discount'] as num) > 0)
                .map(
                  (i) => {
                    ...i,
                    'discount_type': t(
                      'خصم مسجل؛ النوع غير محفوظ',
                      'Recorded discount; type not stored',
                    ),
                  },
                )
                .toList(),
            [
              ('invoice_id', 'الفاتورة', 'Invoice'),
              ('discount_type', 'نوع الخصم', 'Discount type'),
              ('discount', 'EGP', 'EGP'),
            ],
          ),
        ]),
        detailRow('تسويات الكاشير', 'Cashier Settlements', '', [
          table(rows('shifts'), [
            ('status', 'الحالة', 'Status'),
            ('expected_cash', 'المتوقع', 'Expected'),
            ('actual_cash', 'الفعلي', 'Actual'),
            ('difference', 'الفرق', 'Difference'),
          ]),
        ]),
        detailRow(
          'المبالغ المستحقة',
          'Amounts Due',
          money(report['uncollected_recorded']),
          [
            notice(
              'حسب سجل التحصيل، وليس إثباتًا مستقلًا للديون.',
              'Based on recorded collections, not independent confirmation of debt.',
            ),
          ],
        ),
      ],
    ),
  );
  Widget paymentTable(String? method) => table(
    rows('payments')
        .where((p) => method == null || p['method'] == method)
        .toList(),
    [
      ('invoice_id', 'الفاتورة', 'Invoice'),
      ('method', 'الوسيلة', 'Method'),
      ('event_type', 'الحركة', 'Event'),
      ('amount', 'EGP', 'EGP'),
    ],
  );
  Widget table(
    List<Map<String, dynamic>> list,
    List<(String, String, String)> columns,
  ) {
    if (list.isEmpty) {
      return notice(
        'لا توجد سجلات مطابقة في النطاق المصرح به.',
        'No matching records in the authorized scope.',
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(const Color(0xfff1f5f7)),
        columnSpacing: 24,
        columns: [
          for (final c in columns)
            DataColumn(
              label: Text(
                t(c.$2, c.$3),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
        ],
        rows: [
          for (final r in list)
            DataRow(
              cells: [
                for (final c in columns)
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: SelectableText(
                        (c.$1 == 'invoice_id'
                                    ? r['invoice_number'] ?? r[c.$1]
                                    : r[c.$1])
                                ?.toString() ??
                            '—',
                        maxLines: 3,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget reports() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            textDirection: TextDirection.ltr,
            children: [
              for (final x in adminReportTabs)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 5, bottom: 16),
                  child: TextButton.icon(
                    key: ValueKey('report-${x.$1}'),
                    style: TextButton.styleFrom(
                      backgroundColor: tab == x.$1 ? adminAccent : Colors.white,
                      foregroundColor: tab == x.$1
                          ? adminNavy
                          : Colors.blueGrey,
                      padding: const EdgeInsets.all(16),
                      shape: const RoundedRectangleBorder(),
                    ),
                    onPressed: () => setState(() => tab = x.$1),
                    icon: const Icon(Icons.description_outlined, size: 20),
                    label: Text(t(x.$2, x.$3)),
                  ),
                ),
            ],
          ),
        ),
        band(
          t('التقارير', 'Reports'),
          trailing: Theme(
            data: Theme.of(context).copyWith(
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xffeef1f5),
                  foregroundColor: adminRoyal,
                ),
              ),
            ),
            child: period(),
          ),
        ),
        filterBar(),
        if (report['filter_notice_required'] == true)
          notice(
            'يعرض الفلتر الفواتير التي شارك فيها الموظف أو تضمنت الخدمة؛ الإجماليات ليست مبيعات بند واحد أو كشف راتب.',
            'Filters show invoices involving the employee or service; totals are not single-line sales or a payslip.',
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final a in widget.actions.where((a) => a.section == 'reports'))
              OutlinedButton.icon(
                onPressed: a.onTap,
                icon: Icon(a.icon),
                label: Text(t(a.ar, a.en)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (data?['financial'] != true)
          notice(
            'التقارير المالية غير مصرح بها لهذا الحساب.',
            'Financial reports are not authorized for this account.',
          )
        else
          switch (tab) {
            'summary' => Column(
              children: [
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () => setState(() => expanded = !expanded),
                    child: Text(
                      expanded
                          ? t('إغلاق الكل', 'Collapse all')
                          : t('توسيع الكل', 'Expand all'),
                    ),
                  ),
                ),
                AdminTrendChart(
                  payments: rows('payments'),
                  arabic: language == 'ar',
                ),
                const SizedBox(height: 20),
                summary(),
              ],
            ),
            'operations' => panel(
              t('التشغيل والحجوزات', 'Operations & bookings'),
              table(rows('bookings'), [
                ('id', 'الحجز', 'Booking'),
                ('service_name', 'الخدمة', 'Service'),
                ('booking_date', 'التاريخ', 'Date'),
                ('status', 'الحالة', 'Status'),
              ]),
            ),
            'hourly' => panel(
              t(
                'قيمة الفواتير حسب ساعة الإصدار · الزيارات المكتملة حسب وقت انتهاء الخدمة الموثق',
                'Invoice value by issue hour · completed visits by verified service end time',
              ),
              Column(
                children: [
                  AdminTrendChart(
                    payments: rows('payments'),
                    arabic: language == 'ar',
                  ),
                  table(
                    List<Map<String, dynamic>>.from(report['hourly'] ?? []),
                    [
                      ('hour', 'ساعة القاهرة', 'Cairo hour'),
                      (
                        'completed_service_visits',
                        'زيارات مكتملة موثقة',
                        'Verified completed visits',
                      ),
                      (
                        'net_billed',
                        'قيمة الفواتير النشطة',
                        'Active invoice value',
                      ),
                      (
                        'refunded_invoice_value',
                        'فواتير مستردة',
                        'Refunded invoice value',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            'mix' => panel(
              t('مزيج المبيعات', 'Product Mix'),
              table(
                List<Map<String, dynamic>>.from(report['product_mix'] ?? []),
                [
                  ('service_name', 'الخدمة / المنتج', 'Service / product'),
                  ('sale_type', 'النوع', 'Type'),
                  ('invoices', 'الفواتير', 'Invoices'),
                  ('total', 'EGP', 'EGP'),
                ],
              ),
            ),
            'history' => panel(
              t('سجل الطلبات والفواتير', 'Order & invoice history'),
              table(rows('invoices'), [
                ('invoice_id', 'الفاتورة', 'Invoice'),
                ('service_name', 'الخدمة', 'Service'),
                ('issued_at', 'الإصدار', 'Issued'),
                ('status', 'الحالة', 'Status'),
                ('total', 'EGP', 'EGP'),
              ]),
            ),
            'payments' => panel(
              t('ملخص المدفوعات', 'Payment Summary'),
              paymentTable(null),
            ),
            _ => Column(
              children: [
                analyticsPanel(),
                panel(
                  t(
                    'مصروفات الفرع والفترة — مستقلة عن تصفية الخدمة والدفع',
                    'Branch/window expenses — independent of service/payment filters',
                  ),
                  table(
                    List<Map<String, dynamic>>.from(
                      (data?['extra'] as Map?)?['expenses'] ?? [],
                    ),
                    [
                      ('category', 'الفئة', 'Category'),
                      ('expense_date', 'التاريخ', 'Date'),
                      ('amount', 'EGP', 'EGP'),
                    ],
                  ),
                ),
                notice(
                  'الربح والرواتب والالتزامات تحتاج دفاتر مكتملة ومعتمدة؛ لا يتم احتساب أرقام افتراضية.',
                  'Profit, payroll and liabilities require complete approved ledgers; no assumed figures are calculated.',
                ),
              ],
            ),
          },
      ],
    );
  }

  Widget module() {
    final extra = data?['extra'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        band(
          t(
            adminSections.firstWhere((s) => s.$1 == section).$2,
            adminSections.firstWhere((s) => s.$1 == section).$3,
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final action in widget.actions.where(
              (a) => a.section == section,
            ))
              OutlinedButton.icon(
                onPressed: action.onTap,
                icon: Icon(action.icon),
                label: Text(t(action.ar, action.en)),
              ),
          ],
        ),
        const SizedBox(height: 18),
        switch (section) {
          'cashier' => panel(
            t('نقطة البيع والتحصيل', 'Point of sale & collections'),
            Text(
              t(
                'اختر نقطة البيع للزيارات المباشرة والحجوزات، أو افتح المستندات والورديات. تأكيد الدفع الفعلي مطلوب قبل اعتماد الفاتورة.',
                'Open POS for walk-in visits and bookings, or review invoices and shifts. Payment must be confirmed before an invoice is finalized.',
              ),
              style: const TextStyle(color: adminInk, height: 1.45),
            ),
          ),
          'intelligence' => panel(
            t('التحليل المبني على الأدلة', 'Evidence-based analysis'),
            Text(
              t(
                'تعرض Sabiha AI مؤشرات مستخرجة من سجلات الفرع وتوضح البيانات الناقصة. لا تُنشأ أرباح أو توقعات افتراضية ولا تُتخذ قرارات آلية.',
                'Sabiha AI presents metrics from branch records and identifies missing data. It does not invent profit or forecasts, or make automated decisions.',
              ),
              style: const TextStyle(color: adminInk, height: 1.45),
            ),
          ),
          'promotions' => panel(
            t('الأسعار والعروض والولاء', 'Pricing, offers & loyalty'),
            Text(
              t(
                'تُراجع أهلية الخدمات والكوبونات والولاء على الخادم عند الحجز أو التحصيل. إعداد السياسة لا يعني تفعيل الصرف إذا كانت دورة الصرف غير متاحة.',
                'Service, coupon and loyalty eligibility is checked by the server at booking or checkout. Saving a policy does not activate reward spending when the issuance flow is unavailable.',
              ),
              style: const TextStyle(color: adminInk, height: 1.45),
            ),
          ),
          'products' => panel(
            t('كتالوج الفروع', 'Branch catalog'),
            table(rows('catalog'), [
              ('name', 'الاسم', 'Name'),
              ('item_type', 'النوع', 'Type'),
              ('price', 'السعر EGP', 'Price EGP'),
              ('duration_minutes', 'دقيقة', 'Minutes'),
              ('is_active', 'نشط', 'Active'),
            ]),
          ),
          'inventory' => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              panel(
                t('المخزون المسجل', 'Recorded Inventory'),
                table(
                  rows('catalog')
                      .where((c) => c['item_type'] == 'product')
                      .toList(),
                  [
                    ('name', 'المنتج', 'Product'),
                    ('stock_quantity', 'الكمية', 'Quantity'),
                    ('price', 'EGP', 'EGP'),
                    ('is_active', 'نشط', 'Active'),
                  ],
                ),
              ),
              if (data?['role'] == 'owner' || data?['role'] == 'manager')
                InventoryPurchasingPanel(
                  client: widget.client,
                  branchId: branch,
                  onStockChanged: load,
                  onBranchSelected: (v) {
                    setState(() => branch = v);
                    load();
                  },
                ),
            ],
          ),
          'employees' => Column(
            children: [
              panel(
                t(
                  'الموظفون حسب صلاحية الفروع',
                  'Authorized Employee Directory',
                ),
                table(rows('staff'), [
                  ('full_name', 'الاسم', 'Name'),
                  ('role', 'الدور', 'Role'),
                  ('is_active', 'نشط', 'Active'),
                ]),
              ),
              if (data?['role'] == 'owner')
                panel(
                  t('أرصدة السلف المسجلة', 'Recorded Worker Advances'),
                  table(
                    List<Map<String, dynamic>>.from(
                      extra['worker_advances'] ?? [],
                    ),
                    [
                      ('name', 'الاسم', 'Name'),
                      (
                        'advance_balance',
                        'رصيد السلفة EGP',
                        'Advance balance EGP',
                      ),
                    ],
                  ),
                ),
              notice(
                'أرصدة السلف القديمة مرتبطة بسجل العامل وليست توزيعًا موثقًا حسب الفرع. دورة الرواتب والخصومات والمكافآت الكاملة غير متاحة في الدفتر المشترك الحالي.',
                'Legacy advances belong to worker records and are not an audited branch allocation. A complete payroll, deductions and bonuses cycle is unavailable in the current shared ledger.',
              ),
            ],
          ),
          'schedules' => panel(
            t('الجداول والحجوزات', 'Schedules & Bookings'),
            table(rows('bookings'), [
              ('service_name', 'الخدمة', 'Service'),
              ('booking_date', 'التاريخ', 'Date'),
              ('booking_time', 'الوقت', 'Time'),
              ('status', 'الحالة', 'Status'),
            ]),
          ),
          'crm' => Column(
            children: [
              panel(
                t('عملاء الفروع المصرح بها', 'Authorized Branch Customers'),
                table(rows('customers'), [
                  ('full_name', 'الاسم', 'Name'),
                  ('phone', 'الهاتف', 'Phone'),
                ]),
              ),
              panel(
                t('العروض المسجلة', 'Recorded Offers'),
                table(List<Map<String, dynamic>>.from(extra['offers'] ?? []), [
                  ('name', 'العرض', 'Offer'),
                  ('offer_type', 'النوع', 'Type'),
                  ('is_active', 'نشط', 'Active'),
                ]),
              ),
            ],
          ),
          'establishment' => panel(
            t('الفروع والمنشآت', 'Establishments'),
            table(rows('branches'), [
              ('name_ar', 'الاسم العربي', 'Arabic name'),
              ('name_en', 'الاسم الإنجليزي', 'English name'),
              ('address_ar', 'العنوان', 'Address'),
              ('currency', 'العملة', 'Currency'),
              ('is_active', 'نشط', 'Active'),
            ]),
          ),
          'security' => panel(
            t('الأمان والصلاحيات', 'Security & Access'),
            Column(
              children: [
                kv(
                  t('الدور الفعلي من الخادم', 'Live server role'),
                  '${data?['role']}',
                ),
                kv(
                  t('الوصول المالي', 'Financial access'),
                  '${data?['financial']}',
                ),
                notice(
                  'تُراجع هوية الموظف وحالته وعضوية الفرع في قاعدة البيانات عند كل طلب. حساب الموظف يعرض المهام المعينة؛ الكاشير يعرض تحصيل وردياته فقط.',
                  'The database checks live staff identity, activation and branch membership on every request. Employees see assigned tasks; cashiers see their own shift collections.',
                ),
              ],
            ),
          ),
          _ => panel(
            t('إعدادات المنشأة', 'Business Settings'),
            Column(
              children: [
                kv(t('العملة', 'Currency'), 'EGP'),
                kv(
                  t('التوقيت المحاسبي', 'Accounting time zone'),
                  'Africa/Cairo',
                ),
                kv(
                  t('لغة العرض', 'Display language'),
                  language == 'ar' ? 'العربية' : 'English',
                ),
                notice(
                  'الضرائب تؤخذ من بيانات الفاتورة المعتمدة. لا يتم افتراض نسبة ضريبة عند غياب السجل. إرسال التقارير بالبريد يحتاج إعداد الخدمة.',
                  'Taxes use approved invoice records. No tax rate is assumed when missing. Report email delivery requires service configuration.',
                ),
              ],
            ),
          ),
        },
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: adminRoyal,
            brightness: Brightness.light,
          ).copyWith(
            primary: adminRoyal,
            secondary: adminAccent,
            onSurface: adminInk,
          ),
      scaffoldBackgroundColor: const Color(0xfff1f3f5),
      fontFamily: 'Arial',
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
      ),
    );
    return Localizations.override(
      context: context,
      locale: Locale(language ?? 'en'),
      child: Directionality(
        textDirection: language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        child: Theme(
          data: theme,
          child: Scaffold(
            drawer: Drawer(
              child: SafeArea(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    DrawerHeader(
                      decoration: const BoxDecoration(color: adminNavy),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          t('إدارة Sabiha Hub', 'Sabiha Hub Management'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    for (final s in adminSections)
                      ListTile(
                        key: ValueKey('admin-drawer-${s.$1}'),
                        selected: section == s.$1,
                        selectedTileColor: const Color(0xFFE8EEF5),
                        leading: Icon(
                          s.$4,
                          color: section == s.$1 ? adminRoyal : adminInk,
                        ),
                        title: Text(
                          t(s.$2, s.$3),
                          style: TextStyle(
                            color: section == s.$1 ? adminRoyal : adminInk,
                            fontWeight: section == s.$1
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        onTap: () {
                          setState(() => section = s.$1);
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              ),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  header(),
                  if (busy) const LinearProgressIndicator(),
                  Expanded(
                    child: error != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  t(
                                    'تعذر تحميل البيانات. تحقق من الاتصال والصلاحيات.',
                                    'Could not load data. Check connection and permissions.',
                                  ),
                                ),
                                TextButton(
                                  onPressed: load,
                                  child: Text(t('إعادة المحاولة', 'Retry')),
                                ),
                              ],
                            ),
                          )
                        : data == null
                        ? const SizedBox()
                        : SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: section == 'overview'
                                  ? overview()
                                  : section == 'reports'
                                  ? reports()
                                  : module(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Native, interactive payment-event chart. Never uses invoice value as cash received.
class AdminTrendChart extends StatefulWidget {
  final List<Map<String, dynamic>> payments;
  final bool arabic;
  const AdminTrendChart({
    super.key,
    required this.payments,
    required this.arabic,
  });
  @override
  State<AdminTrendChart> createState() => _AdminTrendChartState();
}

class _AdminTrendChartState extends State<AdminTrendChart> {
  int? hour;
  @override
  Widget build(BuildContext context) {
    final amounts = List<double>.filled(24, 0);
    for (final p in widget.payments) {
      final stamp = DateTime.tryParse('${p['created_at']}');
      if (stamp != null) {
        // Use the server-computed Cairo hour; never infer accounting time from the device.
        final h = p['cairo_hour'] as int?;
        if (h != null && h >= 0 && h < 24) {
          amounts[h] +=
              (p['event_type'] == 'sale' ? 1 : -1) *
              (p['amount'] as num).toDouble();
        }
      }
    }
    return LayoutBuilder(
      builder: (c, b) => Column(
        children: [
          Text(
            widget.arabic
                ? 'حركة المدفوعات · القاهرة'
                : 'Payment activity · Cairo',
            style: const TextStyle(color: Colors.blueGrey),
          ),
          SizedBox(
            height: 230,
            child: GestureDetector(
              onTapDown: (d) => setState(
                () =>
                    hour = ((d.localPosition.dx - 36) / (b.maxWidth - 52) * 23)
                        .round()
                        .clamp(0, 23),
              ),
              onPanUpdate: (d) => setState(
                () =>
                    hour = ((d.localPosition.dx - 36) / (b.maxWidth - 52) * 23)
                        .round()
                        .clamp(0, 23),
              ),
              child: MouseRegion(
                onHover: (e) => setState(
                  () => hour =
                      ((e.localPosition.dx - 36) / (b.maxWidth - 52) * 23)
                          .round()
                          .clamp(0, 23),
                ),
                child: CustomPaint(
                  size: Size(b.maxWidth, 230),
                  painter: _TrendPainter(amounts, hour),
                ),
              ),
            ),
          ),
          Text(
            hour == null
                ? (widget.arabic
                      ? 'مرر أو اضغط لعرض القيمة الدقيقة'
                      : 'Hover or tap for exact value')
                : '${hour.toString().padLeft(2, '0')}:00 · ${amounts[hour!].toStringAsFixed(2)} EGP',
            style: const TextStyle(color: adminRoyal),
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<double> values;
  final int? selected;
  _TrendPainter(this.values, this.selected);
  @override
  void paint(Canvas canvas, Size size) {
    const left = 36.0;
    final width = size.width - 52, height = size.height - 42;
    final upper = values.fold<double>(1, math.max);
    final lower = values.fold<double>(0, math.min);
    final span = upper - lower;
    final pen = Paint()
      ..color = const Color(0xffdde3e7)
      ..strokeWidth = 1;
    void label(String s, Offset o) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: const TextStyle(color: Colors.blueGrey, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o);
    }

    for (var i = 0; i < 5; i++) {
      final y = 12 + height * i / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width - 16, y), pen);
      label((upper - span * i / 4).toStringAsFixed(0), Offset(0, y));
    }
    final path = Path();
    for (var h = 0; h < 24; h++) {
      final point = Offset(
        left + width * h / 23,
        12 + height - ((values[h] - lower) / span) * height,
      );
      if (h == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawCircle(
        point,
        selected == h ? 5 : 3,
        Paint()..color = adminAccent,
      );
      if (h % 3 == 0) label('$h', Offset(point.dx - 4, size.height - 20));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = adminRoyal
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}
