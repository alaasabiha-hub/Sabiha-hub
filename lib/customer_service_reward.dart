import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'customer_visuals.dart';
import 'customer_booking_ui.dart'
    show bookingPaymentLabel, bookingAppointmentLabel;
import 'invoice_presentation.dart' show invoiceDate;
import 'service_booking_attempt.dart';
import 'workflow.dart' show newOrderRequestId;

final rewardWalletRevision = ValueNotifier<int>(0);
void refreshRewardWallet() => rewardWalletRevision.value++;

class CustomerRewardWallet extends StatefulWidget {
  const CustomerRewardWallet({super.key, required this.client});
  final SupabaseClient client;
  @override
  State<CustomerRewardWallet> createState() => _WalletState();
}

class _WalletState extends State<CustomerRewardWallet> {
  Map<String, dynamic>? data;
  bool busy = false, reloadPending = false;
  String? error;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    rewardWalletRevision.addListener(load);
    load();
  }

  @override
  void dispose() {
    rewardWalletRevision.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    if (busy) {
      reloadPending = true;
      return;
    }
    setState(() => busy = true);
    try {
      final value = Map<String, dynamic>.from(
        await widget.client.rpc('get_my_reward_wallet') as Map,
      );
      if (mounted) {
        setState(() {
          data = value;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          data = null;
          error = t(
            'رصيد البرامج غير متاح؛ لا نفترض أنه صفر.',
            'Program balances are unavailable; no zero balance is assumed.',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (reloadPending) {
          reloadPending = false;
          load();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('زيارات متاحة حسب البرنامج', 'Available visits by program'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            t(
              'قد تتداخل أرصدة البرامج؛ لا تُجمع. صافي الزيارات التاريخي ليس رصيداً متاحاً، ولا يدمج بالنقاط القديمة.',
              'Program pools may overlap; do not add them. Lifetime net visits are not an available balance and are separate from legacy points.',
            ),
          ),
          if (error != null) Text(error!),
          if (busy) const LinearProgressIndicator(),
          if (data != null) ...[
            if ((data!['programs'] as List? ?? []).isEmpty)
              Text(
                t(
                  'لا يوجد برنامج رصيد متاح في سجل الخادم.',
                  'No program balance is available in the server record.',
                ),
              ),
            for (final p in (data!['programs'] as List? ?? []))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${p['offer_name'] ?? (p['reward_service'] as Map?)?['name'] ?? t('برنامج زيارات مستقل', 'Separate visit program')}\n${t('زيارات غير مستخدمة وصالحة', 'Unused valid visits')}: ${p['unused_valid_visits']} · ${t('الحد', 'Threshold')}: ${p['threshold_visits']}\n${t('تتطلب تبنياً صريحاً', 'Require explicit adoption')}: ${p['adoption_required_visits']}',
                ),
              ),
          ],
          TextButton(
            onPressed: busy ? null : load,
            child: Text(t('تحديث رصيد البرامج', 'Refresh program balances')),
          ),
        ],
      ),
    ),
  );
}

/// Opt-in reward mode. Placement, receipts and normal retries share one durable controller.
class CustomerServiceRewardPanel extends StatefulWidget {
  const CustomerServiceRewardPanel({
    super.key,
    required this.client,
    required this.attempt,
    required this.normalPayload,
    required this.appointmentReviewed,
    required this.onModeChanged,
    required this.onAcknowledged,
  });
  final SupabaseClient client;
  final ServiceBookingAttempt attempt;
  final Map<String, dynamic> normalPayload;
  final bool appointmentReviewed;
  final ValueChanged<bool> onModeChanged;
  final VoidCallback onAcknowledged;
  @override
  State<CustomerServiceRewardPanel> createState() => _RewardPanelState();
}

class _RewardPanelState extends State<CustomerServiceRewardPanel> {
  Map<String, dynamic>? options, quote;
  String? selected, quoteId, quoteSignature, error, refreshedReceipt;
  bool rewardMode = false, busy = false, terms = false, adoption = false;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    widget.attempt.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) changed();
    });
  }

  @override
  void dispose() {
    widget.attempt.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (!mounted) return;
    if (widget.attempt.succeeded &&
        refreshedReceipt != widget.attempt.requestId) {
      refreshedReceipt = widget.attempt.requestId;
      refreshRewardWallet();
    }
    if (widget.attempt.state == 'closed') {
      quote = null;
      quoteId = null;
      terms = adoption = false;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant CustomerServiceRewardPanel old) {
    super.didUpdateWidget(old);
    if (jsonEncode(old.normalPayload) != jsonEncode(widget.normalPayload) &&
        !widget.attempt.locked) {
      options = null;
      quote = null;
      selected = null;
      quoteId = null;
      quoteSignature = null;
      terms = adoption = false;
    }
  }

  Future<void> loadOptions() async {
    if (widget.attempt.locked || busy) return;
    setState(() {
      busy = true;
      rewardMode = true;
      error = null;
    });
    widget.onModeChanged(true);
    final scope =
        '${widget.normalPayload['p_service']}:${widget.normalPayload['p_branch']}';
    try {
      final value = Map<String, dynamic>.from(
        await widget.client.rpc(
          'get_service_reward_options',
          params: {
            'p_service': widget.normalPayload['p_service'],
            'p_branch': widget.normalPayload['p_branch'],
          },
        ) as Map,
      );
      if (mounted &&
          scope ==
              '${widget.normalPayload['p_service']}:${widget.normalPayload['p_branch']}') {
        setState(() => options = value);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'تعذر التحقق من الأهلية الفعلية. لا يوجد انتقال تلقائي لحجز مدفوع.',
            'Actual eligibility could not be checked. There is no automatic fallback to a paid booking.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> getQuote() async {
    if (busy ||
        widget.attempt.locked ||
        selected == null ||
        !widget.appointmentReviewed) {
      return;
    }
    final programs = (options?['programs'] as List? ?? []);
    final program = programs.firstWhere(
      (p) => p['rules_version_id'] == selected,
    );
    final payload = {...widget.normalPayload}..remove('p_expected_price');
    payload['p_policy_version'] = program['policy_version_id'];
    payload['p_rules_version'] = selected;
    final signature = jsonEncode(payload);
    if (quoteSignature != signature) {
      quoteSignature = signature;
      quoteId = newOrderRequestId();
    }
    setState(() {
      busy = true;
      quote = null;
      terms = adoption = false;
      error = null;
    });
    try {
      final value = Map<String, dynamic>.from(
        await widget.client.rpc(
          'quote_service_reward',
          params: {'p_request': quoteId, ...payload},
        ) as Map,
      );
      if (mounted && quoteSignature == signature) setState(() => quote = value);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'تعذر تحميل العرض الفعلي؛ لم يُنشأ حجز.',
            'The actual quote could not be loaded; no booking was created.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget ruleTerms(Map rules) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final key in _ruleNames.keys)
        Text(
          '${t(_ruleNames[key]!.$1, _ruleNames[key]!.$2)}: ${_ruleValues['${rules[key]}'] == null ? '—' : t(_ruleValues['${rules[key]}']!.$1, _ruleValues['${rules[key]}']!.$2)}',
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final a = widget.attempt;
    final result = a.view['result'] as Map?;
    final q = quote;
    return PopScope(
      canPop: !a.locked,
      child: CustomerPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(
                'حجز عادي أو مكافأة زيارات اختيارية',
                'Ordinary booking or optional visit reward',
              ),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (a.error != null)
              Text(
                t(
                  'نتيجة الطلب غير مؤكدة. البيانات وطريقة الحجز مقفلتان؛ أعد نفس الطلب أو تحقق من الخادم.',
                  'The outcome is unconfirmed. Details and mode are locked; retry the same request or check the server.',
                ),
              ),
            if (a.busy || busy) const LinearProgressIndicator(),
            if (a.succeeded && result != null) ...[
              Text(
                '${t('الحجز المحفوظ', 'Saved booking')}: ${result['booking_number'] ?? result['booking_id']}',
              ),
              Text(
                '${t('الفاتورة', 'Invoice')}: ${result['invoice_number'] ?? result['invoice_id']}',
              ),
              if (result['amount_due'] != null)
                Text(
                  '${t('المستحق', 'Amount due')}: ${result['amount_due']} ${result['currency'] ?? 'EGP'}',
                ),
              if (result['gross_amount'] != null)
                Text(
                  '${t('السعر قبل المكافأة', 'Gross before reward')}: ${result['gross_amount']} EGP · ${t('التغطية', 'Coverage')}: ${result['reward_discount']} EGP',
                ),
              if (result['rules'] is Map) ruleTerms(result['rules'] as Map),
              Text(
                bookingPaymentLabel(result['payment_status'] as String?, ar),
              ),
              FilledButton(
                onPressed: a.busy
                    ? null
                    : () async {
                        if (await a.acknowledge()) {
                          refreshRewardWallet();
                          widget.onAcknowledged();
                        }
                      },
                child: Text(
                  t(
                    'راجعت الحجز والفاتورة · متابعة',
                    'I reviewed the booking and invoice · Continue',
                  ),
                ),
              ),
            ] else if (a.locked) ...[
              Text(
                t(
                  'طلب محفوظ بانتظار الحسم؛ لا تغيّر الخدمة أو الموعد أو الطريقة.',
                  'A saved attempt needs resolution; do not change the service, appointment or mode.',
                ),
              ),
              if (a.view['form_context'] is Map)
                Text(
                  '${t('الخدمة والموعد المحفوظان على الخادم', 'Server-saved service and appointment')}: ${bookingAppointmentLabel(context, a.view['form_context'] as Map)}',
                ),
              if (a.view['payload'] is Map && a.mode == 'normal')
                Text(
                  '${t('الموعد المحفوظ', 'Saved appointment')}: ${bookingAppointmentLabel(context, {'booking_date': (a.view['payload'] as Map)['p_date'], 'booking_time': (a.view['payload'] as Map)['p_time']})}',
                ),
              if ([
                'different_mode',
                'manual_review_required',
              ].contains(a.state))
                Text(
                  t(
                    'يوجد تعارض أو سجل يتطلب مراجعة الدعم؛ لن ننشئ حجزاً آخر.',
                    'A conflicting record needs support review; no other booking will be created.',
                  ),
                ),
              TextButton(
                onPressed: a.busy ? null : a.recover,
                child: Text(t('التحقق من حالة الطلب', 'Check attempt status')),
              ),
              if (a.canRetry)
                FilledButton(
                  onPressed: a.busy ? null : a.retry,
                  child: Text(
                    t(
                      'إعادة نفس الطلب المحفوظ',
                      'Retry the exact saved request',
                    ),
                  ),
                ),
              if (a.requestId != null &&
                  ![
                    'different_mode',
                    'manual_review_required',
                  ].contains(a.state))
                TextButton(
                  onPressed: a.busy ? null : a.close,
                  child: Text(
                    t(
                      'طلب إغلاق آمن قبل التعديل',
                      'Request safe close before editing',
                    ),
                  ),
                ),
            ] else ...[
              if (!rewardMode)
                OutlinedButton(
                  onPressed: busy ? null : loadOptions,
                  child: Text(
                    t(
                      'التحقق من مكافأة زيارات · اختياري',
                      'Check visit reward · optional',
                    ),
                  ),
                ),
              if (rewardMode) ...[
                Text(
                  t(
                    'أرصدة البرامج قد تتداخل؛ لا تُجمع ولا تتحول إلى نقود. لا تكديس أو استبدال جزئي أو مكافأة زيارة مباشرة.',
                    'Program pools may overlap; do not add or convert them to money. No stacking, partial redemption or walk-in rewards.',
                  ),
                ),
                if (error != null) Text(error!),
                if (options == null && !busy)
                  TextButton(
                    onPressed: loadOptions,
                    child: Text(
                      t('تحديث الأهلية الفعلية', 'Refresh actual eligibility'),
                    ),
                  ),
                if (options != null && options!['redemption_enabled'] != true)
                  Text(
                    t(
                      'الاستبدال غير متاح وفق حالة الخادم.',
                      'Redemption is unavailable according to the server.',
                    ),
                  ),
                if (options != null) ...[
                  if ((options!['programs'] as List? ?? []).isEmpty)
                    Text(
                      t(
                        'لا توجد برامج مكافأة فعلية لهذه الخدمة.',
                        'No actual reward programs exist for this service.',
                      ),
                    ),
                  for (final p in (options!['programs'] as List? ?? []))
                    Text(
                      '${t('زيارات متاحة لهذا البرنامج فقط', 'Available visits for this program only')}: ${p['available_visits']} / ${p['threshold_visits']}\n${p['eligible'] == true ? t('مؤهل حسب الخادم', 'Eligible according to the server') : t('غير مؤهل حالياً؛ يلزم رصيد فعلي أو معالجة الاسترداد', 'Not currently eligible; actual visits or refund resolution are required')}',
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(selected),
                    initialValue: selected,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        'اختر برنامجاً فعلياً صراحةً',
                        'Explicitly select an actual program',
                      ),
                    ),
                    items: [
                      for (final p in (options!['programs'] as List? ?? []))
                        DropdownMenuItem(
                          value: '${p['rules_version_id']}',
                          enabled:
                              options!['redemption_enabled'] == true &&
                              p['eligible'] == true,
                          child: Text(
                            '${(p['terms_snapshot'] as Map?)?['offer_name'] ?? (p['terms_snapshot'] as Map?)?['offer']?['name'] ?? t('برنامج زيارات', 'Visit program')} · ${p['available_visits']} / ${p['threshold_visits']}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() {
                            selected = v;
                            quote = null;
                            quoteId = null;
                            quoteSignature = null;
                            terms = adoption = false;
                          }),
                  ),
                  TextButton(
                    onPressed:
                        busy || selected == null || !widget.appointmentReviewed
                        ? null
                        : getQuote,
                    child: Text(
                      t(
                        'تحميل عرض المكافأة الفعلي',
                        'Load actual reward quote',
                      ),
                    ),
                  ),
                ],
                if (q != null && q['eligible'] != true) ...[
                  Text(
                    '${t('المكافأة غير متاحة', 'Reward unavailable')}: ${_blocked['${q['reason']}'] == null ? t('تحقق من أهلية البرنامج والموعد', 'Check actual program and appointment eligibility') : t(_blocked['${q['reason']}']!.$1, _blocked['${q['reason']}']!.$2)}',
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      quote = null;
                      quoteId = null;
                      quoteSignature = null;
                    }),
                    child: Text(
                      t('مراجعة العرض من جديد', 'Review a fresh quote'),
                    ),
                  ),
                ],
                if (q != null && q['eligible'] == true) ...[
                  Text(
                    '${t('السعر الفعلي قبل المكافأة', 'Actual gross price')}: ${q['gross_amount']} ${q['currency']}',
                  ),
                  Text(
                    '${t('تغطية المكافأة', 'Reward coverage')}: ${q['reward_discount']} ${q['currency']} · ${t('المستحق', 'Amount due')}: ${q['amount_due']} ${q['currency']}',
                  ),
                  Text(
                    '${t('الزيارات المطلوبة', 'Required visits')}: ${q['threshold_visits']}',
                  ),
                  Text(
                    '${t('صلاحية عرض الخادم', 'Server quote expiry')}: ${invoiceDate({'issued_at': q['expires_at']}, ar)}',
                  ),
                  ruleTerms(
                    (q['terms_snapshot'] as Map?)?['rules'] as Map? ?? {},
                  ),
                  CheckboxListTile(
                    value: terms,
                    onChanged: (v) => setState(() => terms = v == true),
                    title: Text(
                      t(
                        'أوافق صراحةً على شروط هذا العرض المحفوظة واستهلاك الزيارات المطلوبة.',
                        'I explicitly accept this frozen quote’s terms and consumption of the required visits.',
                      ),
                    ),
                  ),
                  if (q['adoption_required'] == true)
                    CheckboxListTile(
                      value: adoption,
                      onChanged: (v) => setState(() => adoption = v == true),
                      title: Text(
                        t(
                          'أتبنى الزيارات المؤهلة السابقة لهذه الشروط صراحةً؛ تبقى صلاحيتها الأصلية محفوظة.',
                          'I explicitly adopt the quoted prior eligible visits into these terms; their original expiry is preserved.',
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed:
                        terms &&
                            (q['adoption_required'] != true || adoption) &&
                            !busy
                        ? () => a.submit('reward', {
                            'p_quote': q['quote_id'],
                            'p_fingerprint': q['fingerprint'],
                            'p_accept_terms': terms,
                            'p_adopt_existing_visits': adoption,
                          })
                        : null,
                    child: Text(
                      t(
                        'تأكيد حجز المكافأة المعروض',
                        'Confirm this quoted reward booking',
                      ),
                    ),
                  ),
                ],
                TextButton(
                  onPressed: busy
                      ? null
                      : () {
                          setState(() {
                            rewardMode = false;
                            quote = null;
                            terms = adoption = false;
                          });
                          widget.onModeChanged(false);
                        },
                  child: Text(
                    t(
                      'اختيار الحجز العادي صراحةً',
                      'Explicitly choose ordinary booking',
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

const _ruleNames = {
  'pooling': ('تجميع الزيارات', 'Visit pooling'),
  'expiry': ('انتهاء الصلاحية', 'Expiry'),
  'cancellation': ('إلغاء المكافأة', 'Reward cancellation'),
  'refunded_contribution': ('استرداد زيارة مساهمة', 'Refunded contribution'),
};
const _ruleValues = {
  'policy_version': ('نفس إصدار السياسة فقط', 'Same policy version only'),
  'offer_branch': (
    'نفس العرض والفرع عبر الإصدارات',
    'Same offer and branch across versions',
  ),
  'no_expiry': ('دون انتهاء صلاحية', 'No expiry'),
  'snapshot_offer_end': ('نهاية العرض المحفوظة', 'Frozen offer end'),
  'restore_visits': (
    'إعادة الزيارات الصالحة عند الإلغاء',
    'Restore valid visits on cancellation',
  ),
  'forfeit_visits': (
    'عدم إعادة الزيارات عند الإلغاء',
    'Do not restore visits on cancellation',
  ),
  'offset_future_visits': (
    'احترام المكافأة وخصم الأثر مستقبلاً',
    'Honor reward; offset future visits',
  ),
  'freeze_for_owner_review': (
    'احترام المكافأة وتجميد الاستبدال لمراجعة المالك',
    'Honor reward; freeze redemption for owner review',
  ),
};
const _blocked = {
  'quote_expired': ('انتهت صلاحية العرض', 'Quote expired'),
  'checkout_not_fully_installed': (
    'المسار غير جاهز على الخادم',
    'Checkout is not ready on the server',
  ),
  'actual_activated_reward_terms_required': (
    'يلزم برنامج مفعل وشروط فعلية',
    'Actual activated terms are required',
  ),
  'refund_review_or_offset_required': (
    'يلزم حسم مراجعة أو خصم أثر استرداد',
    'Refund review or offset is required',
  ),
  'actual_service_vehicle_or_branch_unavailable': (
    'الخدمة أو السيارة أو الفرع غير متاح',
    'Actual service, vehicle or branch unavailable',
  ),
  'appointment_unavailable': ('الموعد غير متاح', 'Appointment unavailable'),
  'insufficient_actual_eligible_visits': (
    'الزيارات الفعلية غير كافية',
    'Insufficient actual eligible visits',
  ),
  'frozen_expiry_passed': (
    'انتهت الصلاحية المحفوظة',
    'Frozen expiry has passed',
  ),
};
