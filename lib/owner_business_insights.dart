import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoice_presentation.dart' show invoiceDate;
import 'free_owner_assistant.dart';

/// Owner evidence overview. Server aggregates only; no model or mutation calls.
class OwnerBusinessInsightsScreen extends StatefulWidget {
  final SupabaseClient client;
  const OwnerBusinessInsightsScreen({super.key, required this.client});
  @override
  State<OwnerBusinessInsightsScreen> createState() => _InsightsState();
}

class _InsightsState extends State<OwnerBusinessInsightsScreen> {
  Map<String, dynamic>? report;
  String? error;
  DateTime from = DateTime.now().subtract(const Duration(days: 30)),
      to = DateTime.now();
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  // Civil accounting dates stay date-only. Explicit labels also keep the
  // chronology clear in RTL, without a bidi-sensitive numeric dash range.
  String get periodLabel {
    final local = MaterialLocalizations.of(context);
    return '${t('من', 'From')}: ${local.formatMediumDate(from)}\n${t('إلى', 'To')}: ${local.formatMediumDate(to)}';
  }

  String get snapshotLabel => invoiceDate({
    'issued_at': report?['as_of'],
    if (report?['as_of_cairo'] != null)
      'issued_at_cairo': report!['as_of_cairo'],
  }, ar);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      report = null;
      error = null;
    });
    try {
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_owner_business_insights',
          params: {'p_from': day(from), 'p_to': day(to)},
        ) as Map,
      );
      if (mounted) setState(() => report = result);
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

  Future<void> filter() async {
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

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xffeef1f5),
        appBar: AppBar(
          backgroundColor: const Color(0xff071a36),
          foregroundColor: Colors.white,
          title: Text(
            t('نظرة المالك المبنية على الأدلة', 'Owner evidence overview'),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Image.asset(
                'assets/sabiha_brand_approved.png',
                width: 60,
                fit: BoxFit.contain,
              ),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        error == 'denied'
                            ? t(
                                'هذه البيانات تتطلب صلاحية المالك',
                                'Owner access is required',
                              )
                            : t(
                                'تعذر تحميل الأدلة المسجلة',
                                'Unable to load recorded evidence',
                              ),
                      ),
                      TextButton(
                        onPressed: load,
                        child: Text(t('إعادة المحاولة', 'Retry')),
                      ),
                    ],
                  )
                : report == null
                ? const CircularProgressIndicator()
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        t(
                          'الملخص قواعد وصفية على بيانات فعلية. اقتراحات AI الاختيارية تتطلب موافقتك ولا تنفّذ قرارات آلية.',
                          'Descriptive rules over recorded data. Optional AI review actions require your consent and perform no automatic decisions.',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: filter,
                        child: Text(
                          periodLabel,
                          key: const ValueKey('owner-insights-period'),
                        ),
                      ),
                      Text(
                        t(
                          'النطاق: الفرع الافتراضي النشط فقط. الفواتير حسب الإصدار؛ النقد حسب حركة التحصيل؛ الحجوزات حسب الموعد.',
                          'Scope: active default branch only. Invoices use issue dates; cash uses event dates; bookings use appointment dates.',
                        ),
                      ),
                      Text(
                        '${t('وقت اللقطة', 'Snapshot time')}: $snapshotLabel',
                      ),
                      if (report!['billed_revenue_basis'] ==
                          'active_invoice_issue_window_net_cashier_line_refunds')
                        Text(
                          t(
                            'صافي الفواتير حسب تاريخ الإصدار وحالتها الحالية بعد استردادات البنود؛ يختلف عن التحصيل النقدي، ولا يمثل الربح.',
                            'Net invoices use issue dates and current status after line refunds; this differs from cash collections and is not profit.',
                          ),
                        ),
                      for (final raw in (report!['metrics'] as List? ?? []))
                        Builder(
                          builder: (_) {
                            final m = Map<String, dynamic>.from(raw as Map);
                            final labels = _labels['${m['code']}'];
                            final value = m['value'];
                            return Card(
                              child: ListTile(
                                title: Text(
                                  labels == null
                                      ? '${m['code']}'
                                      : t(labels.$1, labels.$2),
                                ),
                                subtitle: Text(
                                  '${t('المصدر', 'Source')}: ${m['source']} · ${t('عدد سجلات الدليل', 'Evidence records')}: ${m['count']}\n${m['basis'] == 'current_snapshot' ? t('رصيد حالي؛ ليس تاريخياً للفترة', 'Current snapshot; not historical for the selected window') : periodLabel}',
                                ),
                                trailing: Text(
                                  value == null
                                      ? t('غير متاح', 'Unavailable')
                                      : '${value is num ? value.toStringAsFixed(m['unit'] == 'count' ? 0 : 2) : value} ${m['unit'] == 'count' ? '' : m['unit']}',
                                ),
                              ),
                            );
                          },
                        ),
                      Text(
                        t('ملاحظات قواعد الأدلة', 'Evidence rule observations'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if ((report!['metrics'] as List? ?? []).every(
                        (m) => (m['count'] as num? ?? 0) == 0,
                      ))
                        Text(
                          t(
                            'لا توجد سجلات دليل في هذا النطاق. لا توجد نتائج تجريبية.',
                            'No evidence records in this scope. No sample results are supplied.',
                          ),
                        ),
                      for (final m in (report!['insights'] as List? ?? []))
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '${m[ar ? 'message_ar' : 'message_en']}\n${t('المصدر', 'Source')}: ${m['source']} · n=${m['count']} · ${m['basis'] == 'current_snapshot' ? t('اللقطة الحالية', 'Current snapshot') : periodLabel}',
                            ),
                          ),
                        ),
                      FreeOwnerAssistantPanel(
                        client: widget.client,
                        from: from,
                        to: to,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        t('حدود التحليل', 'Analysis limitations'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final key in (report!['limitations'] as List? ?? []))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            _limitations['$key'] == null
                                ? '$key'
                                : t(
                                    _limitations['$key']!.$1,
                                    _limitations['$key']!.$2,
                                  ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

const _labels = {
  'billed_revenue': ('صافي قيمة الفواتير النشطة', 'Net active invoice value'),
  'cash_net': ('صافي التحصيل النقدي', 'Net cash collections'),
  'card_terminal_net': (
    'صافي تحصيل ماكينة البطاقة المسجل',
    'Recorded net card-terminal collections',
  ),
  'recorded_expenses': ('مصروفات مسجلة', 'Recorded expenses'),
  'bookings': ('عبء الحجوزات: عدد المواعيد', 'Booking workload: appointments'),
  'completed_bookings': ('مواعيد مكتملة', 'Completed appointments'),
  'distinct_booking_customers': (
    'عملاء مختلفون لديهم موعد',
    'Distinct appointment customers',
  ),
  'active_products': ('منتجات نشطة', 'Active products'),
  'out_of_stock_products': (
    'منتجات نشطة برصيد صفر',
    'Active products with zero stock',
  ),
  'average_review_stars': ('متوسط نجوم المراجعات', 'Average review stars'),
  'loyalty_movements': (
    'حركات الولاء المرتبطة بطلبات الفرع',
    'Order-linked loyalty movements',
  ),
  'coupon_redemptions': (
    'مرات استخدام الكوبونات المسجلة',
    'Recorded coupon redemptions',
  ),
  'active_offers': ('العروض النشطة حاليًا', 'Currently active offers'),
  'complaints_received': (
    'الشكاوى المسجلة خلال الفترة',
    'Complaints recorded in the period',
  ),
  'documents_expiring_30d': (
    'المستندات التي تنتهي خلال 30 يومًا',
    'Documents expiring within 30 days',
  ),
  'pending_recruitment': (
    'طلبات التوظيف قيد المراجعة',
    'Recruitment applications awaiting review',
  ),
  'quality_pass_rate': (
    'نسبة اجتياز فحوص الجودة المسجلة',
    'Recorded service-quality check pass rate',
  ),
  'received_purchase_costs': (
    'تكلفة أوامر الشراء المستلمة والمسجلة',
    'Recorded cost of received purchase orders',
  ),
};
const _limitations = {
  'incomplete_costs_no_actual_profit': (
    'التكاليف غير مكتملة؛ الربح الفعلي غير متاح. لا تطرح المصروفات من التحصيل وتسمي الناتج ربحاً.',
    'Costs are incomplete; actual profit is unavailable. Collections minus recorded expenses is not profit.',
  ),
  'gateway_fees_unavailable': (
    'التحصيل المسجل بالبطاقة متاح، لكن عمولات بوابة الدفع الفعلية غير متاحة.',
    'Recorded card-terminal collections are available; actual gateway fees are unavailable.',
  ),
  'stock_is_current_not_historical': (
    'المخزون لقطة حالية، وليس رصيد الفترة التاريخي.',
    'Stock is a current snapshot, not historical stock for the period.',
  ),
  'workload_is_booking_count_not_employee_productivity': (
    'عدد المواعيد ليس ساعات عمل أو مقياس إنتاجية الموظفين.',
    'Appointment counts are not work hours or employee productivity.',
  ),
  'reviews_may_be_small_or_unrepresentative': (
    'قد تكون المراجعات قليلة أو غير ممثلة لجميع العملاء.',
    'Reviews may be sparse or unrepresentative of all customers.',
  ),
  'no_marketing_attribution': (
    'لا توجد نسبة موثقة للمبيعات إلى حملة تسويقية.',
    'Sales attribution to marketing campaigns is unavailable.',
  ),
  'no_forecast_or_causal_inference': (
    'لا توقع للطلب أو الإيراد ولا استنتاجات سببية.',
    'No demand or revenue forecasts and no causal conclusions.',
  ),
  'documents_are_company_wide': (
    'بيانات المستندات على مستوى الشركة وليست خاصة بفرع.',
    'Document counts are company-wide, not branch-specific.',
  ),
  'loyalty_metrics_cover_order_linked_movements': (
    'حركات الولاء تشمل السجلات المرتبطة بالطلبات فقط.',
    'Loyalty movement counts include only records linked to orders.',
  ),
  'quality_checks_are_not_employee_scores': (
    'فحوص الجودة المسجلة لا تمثل تقييم أداء كل موظف.',
    'Recorded quality checks do not score each employee.',
  ),
  'purchases_are_received_records_not_recommendations': (
    'المشتريات هي أوامر مستلمة فقط وليست توصية شراء.',
    'Purchases are received orders only, not a purchase recommendation.',
  ),
};
