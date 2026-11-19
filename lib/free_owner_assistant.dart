import 'dart:async';

import 'owner_evidence_tasks.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class FreeOwnerAssistantGateway {
  String? get currentUserId;
  Stream<void> get authChanges;
  Future<Map<String, dynamic>> ask({
    required String topic,
    required String language,
    required String from,
    required String to,
  });
}

/// Uses the existing authenticated Edge endpoint; never a model/provider client.
class SupabaseFreeOwnerAssistantGateway implements FreeOwnerAssistantGateway {
  final SupabaseClient client;
  SupabaseFreeOwnerAssistantGateway(this.client);
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Stream<void> get authChanges => client.auth.onAuthStateChange.map((_) {});
  @override
  Future<Map<String, dynamic>> ask({
    required String topic,
    required String language,
    required String from,
    required String to,
  }) async {
    final response = await client.functions.invoke(
      'owner-evidence-advisor',
      body: {
        'action': 'ask',
        'question': topic,
        'language': language,
        'from': from,
        'to': to,
      },
    );
    if (response.status != 200 || response.data is! Map) {
      throw const FormatException('Unavailable evidence');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }
}

const _topics = <String, (String, String)>{
  'summary': ('ملخص النشاط', 'Business summary'),
  'billing': ('إجمالي الفواتير', 'Invoice totals'),
  'collections': ('التحصيل النقدي', 'Cash collections'),
  'expenses': ('المصروفات المسجلة', 'Recorded expenses'),
  'stock': ('المخزون الحالي', 'Current stock'),
  'bookings': ('ملخص الحجوزات', 'Booking summary'),
  'reviews': ('ملخص المراجعات', 'Review summary'),
  'card_collections': ('تحصيل ماكينة البطاقة', 'Card-terminal collections'),
  'loyalty_marketing': (
    'حركة الولاء والكوبونات',
    'Loyalty and coupon activity',
  ),
  'complaints': ('الشكاوى المسجلة', 'Recorded complaints'),
  'documents': ('المستندات قريبة الانتهاء', 'Upcoming document expiries'),
  'recruitment': ('طلبات التوظيف المعلقة', 'Pending recruitment applications'),
  'service_quality': ('فحوص جودة الخدمة', 'Service quality checks'),
  'inventory_purchases': ('المشتريات المستلمة', 'Received purchases'),
  'profit': ('هل الربح الفعلي متاح؟', 'Is actual profit available?'),
  'forecast': ('هل توقع الإيرادات متاح؟', 'Is a revenue forecast available?'),
};
const _facts = <String, (String, String, String, String, String)>{
  'billed_revenue': (
    'الفواتير',
    'Invoices',
    'business_invoices',
    'EGP',
    'window',
  ),
  'cash_net': (
    'التحصيل النقدي',
    'Cash collections',
    'business_payment_events',
    'EGP',
    'window',
  ),
  'card_terminal_net': (
    'تحصيل ماكينة البطاقة',
    'Card-terminal collections',
    'business_payment_events',
    'EGP',
    'window',
  ),
  'recorded_expenses': (
    'المصروفات المسجلة',
    'Recorded expenses',
    'business_expenses',
    'EGP',
    'window',
  ),
  'bookings': ('الحجوزات', 'Bookings', 'bookings', 'count', 'window'),
  'completed_bookings': (
    'الحجوزات المكتملة',
    'Completed bookings',
    'bookings',
    'count',
    'window',
  ),
  'distinct_booking_customers': (
    'عملاء الحجوزات',
    'Customers in bookings',
    'bookings',
    'count',
    'window',
  ),
  'active_products': (
    'المنتجات النشطة',
    'Active products',
    'business_catalog_items',
    'count',
    'current_snapshot',
  ),
  'out_of_stock_products': (
    'منتجات برصيد مسجل صفر',
    'Products with recorded zero stock',
    'business_catalog_items',
    'count',
    'current_snapshot',
  ),
  'average_review_stars': (
    'المراجعات المسجلة',
    'Recorded reviews',
    'employee_service_reviews',
    'stars',
    'window',
  ),
  'loyalty_movements': (
    'حركات الولاء المرتبطة بطلبات الفرع',
    'Order-linked loyalty movements',
    'business_loyalty_transactions',
    'count',
    'window',
  ),
  'coupon_redemptions': (
    'مرات استخدام الكوبونات المسجلة',
    'Recorded coupon redemptions',
    'business_coupon_redemptions',
    'count',
    'window',
  ),
  'active_offers': (
    'العروض النشطة حاليًا',
    'Currently active offers',
    'business_offers',
    'count',
    'current_snapshot',
  ),
  'complaints_received': (
    'الشكاوى المسجلة خلال الفترة',
    'Complaints recorded in the period',
    'customer_complaints',
    'count',
    'window',
  ),
  'documents_expiring_30d': (
    'المستندات التي تنتهي خلال 30 يومًا',
    'Documents expiring within 30 days',
    'business_documents',
    'count',
    'current_snapshot',
  ),
  'pending_recruitment': (
    'طلبات التوظيف قيد المراجعة',
    'Recruitment applications awaiting review',
    'private.recruitment_applications',
    'count',
    'window',
  ),
  'quality_pass_rate': (
    'نسبة اجتياز فحوص الجودة المسجلة',
    'Recorded service-quality check pass rate',
    'private.service_quality_checks',
    'percent',
    'window',
  ),
  'received_purchase_costs': (
    'تكلفة أوامر الشراء المستلمة',
    'Recorded received purchase costs',
    'public.business_purchase_orders',
    'EGP',
    'window',
  ),
};
const _limits = <String, (String, String)>{
  'active_default_branch_only': (
    'الفرع الافتراضي النشط فقط.',
    'Active default branch only.',
  ),
  'incomplete_costs_no_actual_profit': (
    'التكاليف غير مكتملة؛ الربح الفعلي غير متاح.',
    'Costs are incomplete; actual profit is unavailable.',
  ),
  'gateway_fees_unavailable': (
    'التحصيل المسجل بالبطاقة متاح، لكن عمولات البوابة الفعلية غير متاحة.',
    'Recorded card-terminal collections are available; actual gateway fees are not.',
  ),
  'stock_is_current_not_historical': (
    'المخزون لقطة حالية وليست تاريخية.',
    'Stock is a current snapshot, not historical.',
  ),
  'workload_is_booking_count_not_employee_productivity': (
    'عدد الحجوزات لا يقيس إنتاجية الموظفين.',
    'Booking counts do not measure employee productivity.',
  ),
  'reviews_may_be_small_or_unrepresentative': (
    'قد تكون المراجعات قليلة أو غير ممثلة للجميع.',
    'Reviews may be few or unrepresentative.',
  ),
  'no_marketing_attribution': (
    'لا توجد نسبة مثبتة للنتائج إلى الحملات التسويقية.',
    'Results cannot be attributed to marketing campaigns here.',
  ),
  'no_forecast_or_causal_inference': (
    'لا توجد توقعات أو استنتاجات سببية.',
    'No forecasts or causal conclusions.',
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

bool validFreeOwnerEvidence(
  Map<String, dynamic> data,
  String selected,
  String from,
  String to,
) {
  if (data['mode'] != 'free_evidence_templates' ||
      data['paid_provider_allowed'] != false ||
      data['execution_supported'] != false ||
      data['requires_owner_review'] != true ||
      data['topic'] != selected ||
      !['answer', 'missing_data'].contains(data['state']) ||
      data['scope'] != 'active_default_branch' ||
      data['period'] is! Map ||
      data['period']['from'] != from ||
      data['period']['to'] != to ||
      data['answer'] is! String ||
      (data['answer'] as String).trim().isEmpty ||
      (data['answer'] as String).length > 6000 ||
      data['facts'] is! List ||
      data['citations'] is! List ||
      (data['facts'] as List).length > 20) {
    return false;
  }
  final seen = <String>{};
  for (final raw in data['facts'] as List) {
    if (raw is! Map || raw['id'] is! String || !seen.add(raw['id'])) {
      return false;
    }
    final known = _facts[raw['id']];
    final value = raw['value'];
    if (known == null ||
        raw['source'] != known.$3 ||
        raw['unit'] != known.$4 ||
        raw['basis'] != known.$5 ||
        raw['count'] is! int ||
        (raw['count'] as int) < 0 ||
        !(value == null || value is num && value.isFinite)) {
      return false;
    }
    final matches = (data['citations'] as List).where(
      (c) =>
          c is Map &&
          c['evidence_id'] == raw['id'] &&
          c['source'] == known.$3 &&
          c['basis'] == known.$5 &&
          c['count'] == raw['count'],
    );
    if (matches.length != 1) return false;
  }
  final required = switch (selected) {
    'summary' => _facts.keys.toSet(),
    'billing' => {'billed_revenue'},
    'collections' => {'cash_net'},
    'expenses' => {'recorded_expenses'},
    'stock' => {'active_products', 'out_of_stock_products'},
    'bookings' => {
      'bookings',
      'completed_bookings',
      'distinct_booking_customers',
    },
    'reviews' => {'average_review_stars'},
    'card_collections' => {'card_terminal_net'},
    'loyalty_marketing' => {
      'loyalty_movements',
      'coupon_redemptions',
      'active_offers',
    },
    'complaints' => {'complaints_received'},
    'documents' => {'documents_expiring_30d'},
    'recruitment' => {'pending_recruitment'},
    'service_quality' => {'quality_pass_rate'},
    'inventory_purchases' => {'received_purchase_costs'},
    _ => <String>{},
  };
  return seen.length == required.length &&
      seen.containsAll(required) &&
      (data['citations'] as List).length == seen.length &&
      (required.isNotEmpty || data['state'] == 'missing_data');
}

/// Read-only bounded questions; no prompt editor, execution, persistence or paid AI.
class FreeOwnerAssistantPanel extends StatefulWidget {
  final SupabaseClient? client;
  final FreeOwnerAssistantGateway? gateway;
  final DateTime from;
  final DateTime to;
  const FreeOwnerAssistantPanel({
    super.key,
    this.client,
    this.gateway,
    required this.from,
    required this.to,
  }) : assert(client != null || gateway != null);
  @override
  State<FreeOwnerAssistantPanel> createState() =>
      _FreeOwnerAssistantPanelState();
}

class _FreeOwnerAssistantPanelState extends State<FreeOwnerAssistantPanel> {
  late FreeOwnerAssistantGateway gateway;
  StreamSubscription<void>? subscription;
  String topic = 'summary';
  String? locale;
  Map<String, dynamic>? answer;
  String? error;
  bool busy = false;
  int generation = 0;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String day(DateTime d) => d.toIso8601String().substring(0, 10);

  void invalidate() {
    generation++;
    answer = null;
    error = null;
    busy = false;
  }

  void bind() {
    gateway =
        widget.gateway ?? SupabaseFreeOwnerAssistantGateway(widget.client!);
    subscription = gateway.authChanges.listen((_) {
      if (mounted) setState(invalidate);
    });
  }

  @override
  void initState() {
    super.initState();
    bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Localizations.localeOf(context).languageCode;
    if (locale != next) invalidate();
    locale = next;
  }

  @override
  void didUpdateWidget(covariant FreeOwnerAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.client != widget.client) {
      subscription?.cancel();
      invalidate();
      bind();
    } else if (day(oldWidget.from) != day(widget.from) ||
        day(oldWidget.to) != day(widget.to)) {
      invalidate();
    }
  }

  @override
  void dispose() {
    generation++;
    subscription?.cancel();
    super.dispose();
  }

  bool valid(
    Map<String, dynamic> data,
    String selected,
    String from,
    String to,
  ) => validFreeOwnerEvidence(data, selected, from, to);

  Future<void> ask() async {
    final actor = gateway.currentUserId;
    if (busy || actor == null) return;
    final token = ++generation;
    final from = day(widget.from), to = day(widget.to), selected = topic;
    final language = ar ? 'ar' : 'en';
    setState(() {
      busy = true;
      answer = null;
      error = null;
    });
    bool current() =>
        mounted &&
        token == generation &&
        gateway.currentUserId == actor &&
        day(widget.from) == from &&
        day(widget.to) == to &&
        (ar ? 'ar' : 'en') == language;
    try {
      final data = await gateway.ask(
        topic: selected,
        language: language,
        from: from,
        to: to,
      );
      if (!current()) return;
      if (!valid(data, selected, from, to)) {
        throw const FormatException('Unsupported evidence');
      }
      setState(() => answer = data);
    } catch (e) {
      if (!current()) return;
      setState(
        () => error =
            e is FunctionException && (e.status == 401 || e.status == 403)
            ? 'denied'
            : 'unavailable',
      );
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = gateway.currentUserId != null;
    final local = MaterialLocalizations.of(context);
    return Card(
      key: const ValueKey('free-owner-assistant'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('مساعد المالك المجاني', 'Free owner assistant'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextButton.icon(
              key: const ValueKey('free-owner-chat-open'),
              onPressed: !signedIn || busy
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FreeOwnerChatScreen(
                          gateway: gateway,
                          from: widget.from,
                          to: widget.to,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(
                t('محادثة الأسئلة المدعومة', 'Supported-question chat'),
              ),
            ),
            if (widget.client != null)
              TextButton.icon(
                onPressed: !signedIn || busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OwnerEvidenceTasksScreen(
                            gateway: SupabaseOwnerEvidenceTasksGateway(
                              widget.client!,
                            ),
                            from: widget.from,
                            to: widget.to,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(
                  t('المقترحات وسجل الموافقات', 'Proposals and approvals'),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              t(
                'إجابات محددة من السجلات فقط؛ لا نماذج مدفوعة ولا تنفيذ تغييرات.',
                'Bounded answers from recorded evidence only; no paid models or business changes.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${t('من', 'From')}: ${local.formatMediumDate(widget.from)}\n${t('إلى', 'To')}: ${local.formatMediumDate(widget.to)}',
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: InputDecoration(
                labelText: t('السؤال', 'Question'),
                border: const OutlineInputBorder(),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('free-owner-topic'),
                  value: topic,
                  isExpanded: true,
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() {
                              invalidate();
                              topic = value;
                            });
                          }
                        },
                  items: _topics.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            ar ? e.value.$1 : e.value.$2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('free-owner-ask'),
              onPressed: !signedIn || busy ? null : ask,
              icon: const Icon(Icons.manage_search),
              label: Text(
                busy
                    ? t('جارٍ مراجعة الأدلة…', 'Checking evidence…')
                    : t('عرض الإجابة', 'Show answer'),
              ),
            ),
            if (!signedIn)
              Text(
                t(
                  'سجّل الدخول بحساب المالك لعرض الأدلة.',
                  'Sign in as owner to view evidence.',
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error == 'denied'
                      ? t(
                          'انتهت الجلسة أو لا يوجد إذن المالك. لم تُعرض بيانات جديدة.',
                          'Session expired or owner access denied. No new evidence was displayed.',
                        )
                      : t(
                          'لا تتوفر إجابة موثوقة لهذا الطلب حاليًا. لم تتغير أي سجلات.',
                          'A supported evidence answer is unavailable right now. No records were changed.',
                        ),
                ),
              ),
            if (answer != null) ...[
              const Divider(height: 24),
              if (answer!['state'] == 'missing_data')
                Text(
                  t(
                    'بيانات غير متاحة أو غير مكتملة',
                    'Unavailable or incomplete data',
                  ),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              Text(
                answer!['answer'] as String,
                key: const ValueKey('free-owner-answer'),
              ),
              const SizedBox(height: 12),
              Text(
                t('مصادر الأدلة', 'Evidence sources'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if ((answer!['facts'] as List).isEmpty)
                Text(
                  t(
                    'لا توجد أرقام مستندة إلى أدلة لحساب هذه النتيجة.',
                    'No evidence-backed figures are available to calculate this result.',
                  ),
                ),
              for (final raw in answer!['facts'] as List)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${ar ? _facts[raw['id']]!.$1 : _facts[raw['id']]!.$2} · ${raw['basis'] == 'current_snapshot' ? t('لقطة حالية', 'Current snapshot') : t('الفترة المختارة', 'Selected period')} · ${t('السجلات المطابقة', 'Matching records')}: ${raw['count']}',
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                t('نطاق الإجابة وحدودها', 'Scope and limitations'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final code
                  in (answer!['limitations'] is List
                      ? answer!['limitations'] as List
                      : const []))
                if (_limits.containsKey(code))
                  Text(ar ? _limits[code]!.$1 : _limits[code]!.$2),
              Text(
                t(
                  'مراجعة المالك مطلوبة؛ لا ينفّذ المساعد أي إجراء.',
                  'Owner review is required; this assistant executes no actions.',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bounded chat using the existing free server engine, never an external model.
class FreeOwnerChatScreen extends StatefulWidget {
  final FreeOwnerAssistantGateway gateway;
  final DateTime from, to;
  const FreeOwnerChatScreen({
    super.key,
    required this.gateway,
    required this.from,
    required this.to,
  });
  @override
  State<FreeOwnerChatScreen> createState() => _FreeOwnerChatScreenState();
}

class _FreeOwnerChatScreenState extends State<FreeOwnerChatScreen> {
  final question = TextEditingController();
  final history = <Map<String, dynamic>>[];
  StreamSubscription<dynamic>? subscription;
  int epoch = 0;
  bool busy = false, invalid = false;
  String? error, language;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String day(DateTime date) => date.toIso8601String().substring(0, 10);
  void clear() {
    epoch++;
    history.clear();
    question.clear();
    error = null;
    busy = false;
  }

  void bind() {
    final gateway = widget.gateway;
    void invalidate() {
      if (mounted) {
        setState(() {
          invalid = true;
          clear();
        });
      }
    }

    if (gateway is SupabaseFreeOwnerAssistantGateway) {
      final session = gateway.client.auth.currentSession;
      subscription = gateway.client.auth.onAuthStateChange.listen((event) {
        final replay =
            event.session?.accessToken == session?.accessToken &&
            event.session?.user.id == session?.user.id &&
            const {
              AuthChangeEvent.initialSession,
              AuthChangeEvent.signedIn,
              AuthChangeEvent.tokenRefreshed,
            }.contains(event.event);
        if (!replay) invalidate();
      });
    } else {
      subscription = gateway.authChanges.listen((_) => invalidate());
    }
  }

  @override
  void initState() {
    super.initState();
    bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ar ? 'ar' : 'en';
    if (language != next) clear();
    language = next;
  }

  @override
  void didUpdateWidget(covariant FreeOwnerChatScreen old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway) {
      subscription?.cancel();
      clear();
      invalid = false;
      bind();
    } else if (day(old.from) != day(widget.from) ||
        day(old.to) != day(widget.to)) {
      clear();
    }
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    question.dispose();
    super.dispose();
  }

  String normalize(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[؟?!.،,]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
  static const _questionAliases = <String, String>{
    'how much cash did we collect': 'collections',
    'كم حصلنا نقدًا': 'collections',
    'how much did the card terminal collect': 'card_collections',
    'كم جمعنا على ماكينة البطاقة': 'card_collections',
    'how many loyalty movements and coupon redemptions': 'loyalty_marketing',
    'ما حركة الولاء واستخدام الكوبونات': 'loyalty_marketing',
    'how many complaints were received': 'complaints',
    'كم شكوى وردت خلال الفترة': 'complaints',
    'which documents expire soon': 'documents',
    'ما المستندات التي تنتهي قريبًا': 'documents',
    'how many applications are awaiting review': 'recruitment',
    'كم طلب توظيف ينتظر المراجعة': 'recruitment',
    'what share of recorded quality checks passed': 'service_quality',
    'ما نسبة فحوص الجودة التي اجتازت الفحص': 'service_quality',
    'how much did we spend on received purchases': 'inventory_purchases',
    'كم تكلفة المشتريات التي استلمناها': 'inventory_purchases',
  };
  String? resolve(String text) {
    final normalized = normalize(text);
    for (final entry in _questionAliases.entries) {
      if (normalize(entry.key) == normalized) return entry.value;
    }
    for (final e in _topics.entries) {
      if ([
        e.key,
        e.value.$1,
        e.value.$2,
      ].any((v) => normalize(v) == normalized)) {
        return e.key;
      }
    }
    return null;
  }

  Future<void> ask([String? selected]) async {
    if (busy || invalid || widget.gateway.currentUserId == null) return;
    final topic = selected ?? resolve(question.text);
    if (topic == null) {
      setState(
        () => error = t(
          'هذا السؤال غير مدعوم. اختر أحد الأسئلة أدناه؛ لن نختلق إجابة.',
          'This question is unsupported. Choose a question below; no answer will be invented.',
        ),
      );
      return;
    }
    final generation = ++epoch,
        actor = widget.gateway.currentUserId,
        from = day(widget.from),
        to = day(widget.to),
        lang = ar ? 'ar' : 'en';
    bool current() =>
        mounted &&
        !invalid &&
        generation == epoch &&
        actor == widget.gateway.currentUserId &&
        from == day(widget.from) &&
        to == day(widget.to) &&
        lang == (ar ? 'ar' : 'en');
    setState(() {
      busy = true;
      error = null;
      question.clear();
    });
    try {
      final result = await widget.gateway.ask(
        topic: topic,
        language: lang,
        from: from,
        to: to,
      );
      if (!current()) return;
      if (!validFreeOwnerEvidence(result, topic, from, to)) {
        throw const FormatException('Invalid evidence');
      }
      setState(() {
        history.add({'topic': topic, 'answer': result});
        if (history.length > 10) history.removeAt(0);
      });
    } catch (_) {
      if (current()) {
        setState(
          () => error = t(
            'تعذّر الحصول على إجابة موثقة. تحقق من الاتصال وصلاحية المالك.',
            'Unable to obtain an evidence-backed answer. Check connection and owner access.',
          ),
        );
      }
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('محادثة المالك المجانية', 'Free owner chat'))),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          t(
            'أسئلة محددة من سجلات الفرع النشط للفترة المختارة فقط. ليست محادثة عامة أو توقعات. لا تنفيذ تغييرات ولا خدمات مدفوعة.',
            'Supported questions from active-branch records for the selected period only. Not general chat or forecasting. No business changes or paid services.',
          ),
        ),
        Text(
          '${MaterialLocalizations.of(context).formatMediumDate(widget.from)} — ${MaterialLocalizations.of(context).formatMediumDate(widget.to)}',
        ),
        if (invalid)
          Text(
            t(
              'تغيّرت الجلسة؛ أعد فتح المحادثة بحساب المالك.',
              'Session changed; reopen the chat with the owner account.',
            ),
          ),
        if (error != null) Text(error!),
        ...history.map((item) {
          final topic = item['topic'] as String,
              data = item['answer'] as Map<String, dynamic>,
              title = _topics[topic]!;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ar ? title.$1 : title.$2,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (data['state'] == 'missing_data')
                    Text(t('البيانات غير كافية', 'Insufficient data')),
                  SelectionArea(child: Text(data['answer'] as String)),
                  ...(data['citations'] as List).cast<Map>().map((citation) {
                    final fact = _facts[citation['evidence_id']]!;
                    return Text(
                      '${t('المصدر', 'Source')}: ${ar ? fact.$1 : fact.$2} · ${t('السجلات المطابقة', 'Matching records')}: ${citation['count']}',
                    );
                  }),
                  Text(
                    t(
                      'هذه الأرقام ليست الربح الفعلي. مراجعة المالك مطلوبة.',
                      'These figures are not actual profit. Owner review is required.',
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        if (busy) const LinearProgressIndicator(),
        TextField(
          key: const ValueKey('free-owner-chat-question'),
          controller: question,
          maxLength: 500,
          enabled: !busy && !invalid,
          decoration: InputDecoration(
            labelText: t(
              'اكتب أحد الأسئلة المدعومة أدناه',
              'Enter one of the supported questions below',
            ),
          ),
          onSubmitted: (_) => ask(),
        ),
        FilledButton(
          key: const ValueKey('free-owner-chat-send'),
          onPressed: busy || invalid || widget.gateway.currentUserId == null
              ? null
              : () => ask(),
          child: Text(t('إرسال', 'Send')),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _topics.entries
              .map(
                (entry) => ActionChip(
                  label: Text(ar ? entry.value.$1 : entry.value.$2),
                  onPressed:
                      busy || invalid || widget.gateway.currentUserId == null
                      ? null
                      : () => ask(entry.key),
                ),
              )
              .toList(),
        ),
        Text(
          t(
            'تُحفظ آخر عشر إجابات في ذاكرة هذه الشاشة فقط وتُمسح عند تغيير الجلسة أو اللغة أو الفترة.',
            'Only the last ten answers remain in this screen memory; session, language or period changes clear them.',
          ),
        ),
      ],
    ),
  );
}
