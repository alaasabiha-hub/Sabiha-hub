import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_mixed_visit_policy.dart';
import 'hr_payroll.dart' show hrRequestId;
import 'invoice_presentation.dart' show invoiceDate;

abstract class RedemptionRulesGateway {
  Future<Map<String, dynamic>> read(String policyVersion);
  Future<Map<String, dynamic>> save(Map<String, dynamic> inputs);
  bool get activationAvailable => false;
  Future<void> activate(String request, String rules) =>
      throw UnsupportedError('Activation unavailable');
}

class SupabaseRedemptionRulesGateway extends RedemptionRulesGateway {
  SupabaseRedemptionRulesGateway(this.client);
  final SupabaseClient client;
  @override
  bool get activationAvailable => true;
  @override
  Future<void> activate(String request, String rules) async {
    await client.rpc(
      'activate_loyalty_redemption',
      params: {'p_request': request, 'p_rules_version': rules},
    );
  }

  @override
  Future<Map<String, dynamic>> read(String policyVersion) async =>
      Map<String, dynamic>.from(
        await client.rpc(
          'get_loyalty_redemption_rules',
          params: {'p_policy_version': policyVersion},
        ) as Map,
      );
  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> inputs) async =>
      Map<String, dynamic>.from(
        await client.rpc('save_loyalty_redemption_rules', params: inputs)
            as Map,
      );
}

/// Future terms only. This panel cannot consume visits or alter an invoice.
class OwnerRedemptionRulesPanel extends StatefulWidget {
  const OwnerRedemptionRulesPanel({
    super.key,
    required this.gateway,
    required this.policyVersion,
    this.onPolicyStale,
  });
  final RedemptionRulesGateway gateway;
  final String? policyVersion;
  final Future<void> Function()? onPolicyStale;
  @override
  State<OwnerRedemptionRulesPanel> createState() => _RedemptionRulesState();
}

class _RedemptionRulesState extends State<OwnerRedemptionRulesPanel> {
  Map<String, dynamic>? data;
  final Map<String, String> choices = {};
  bool busy = false;
  int draftRevision = 0;
  String? error, request, signature, activationRequest, activatingRules;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    if (widget.policyVersion != null) load();
  }

  @override
  void didUpdateWidget(covariant OwnerRedemptionRulesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.policyVersion != widget.policyVersion) {
      data = null;
      choices.clear();
      request = null;
      signature = null;
      error = null;
      if (widget.policyVersion != null) load();
    }
  }

  Future<void> load() async {
    if (widget.policyVersion == null) return;
    final version = widget.policyVersion!;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await widget.gateway.read(version);
      if (mounted && widget.policyVersion == version) {
        setState(() {
          data = value;
          choices.clear();
          draftRevision++;
          request = null;
          signature = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          data = null;
          choices.clear();
        });
      }
      if (mounted) {
        setState(
          () => error = e is PostgrestException && e.code == '42501'
              ? t(
                  'تتطلب هذه القواعد صلاحية المالك.',
                  'These rules require owner access.',
                )
              : t(
                  'تعذر تحميل شروط الاستبدال الفعلية.',
                  'Unable to load the actual redemption terms.',
                ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy ||
        data == null ||
        _ruleLabels.keys.any((key) => choices[key] == null)) {
      return;
    }
    final payload = <String, dynamic>{
      'p_policy_version': widget.policyVersion,
      'p_expected_rules_version':
          (data!['current'] as Map?)?['rules_version_id'],
      'p_rules': {for (final key in _ruleLabels.keys) key: choices[key]},
    };
    final next = jsonEncode(payload);
    if (signature != next) {
      signature = next;
      request = hrRequestId();
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.save({
        'p_request': request,
        ...payload,
      });
      if (!mounted) return;
      setState(() {
        data = result;
        choices.clear();
        draftRevision++;
        signature = null;
        request = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'حُفظ إصدار شروط جديد للمستقبل؛ الاستبدال ما زال معطلاً.',
              'A future terms version was saved; redemption remains disabled.',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (e is PostgrestException && (e.code == '40001' || e.code == '55000')) {
        if (e.code == '55000' && widget.onPolicyStale != null) {
          await widget.onPolicyStale!();
          if (!mounted) return;
        }
        await load();
        if (mounted) {
          setState(
            () => error = t(
              'تغير إصدار الشروط أو السياسة. تم تحديث السياق؛ راجع اختياراتك من جديد.',
              'The terms or policy version changed. Context reloaded; review your choices again.',
            ),
          );
        }
      } else {
        setState(
          () => error = t(
            'تعذر الحفظ. احتُفظ بالاختيارات وهوية الطلب لإعادة المحاولة.',
            'Save failed. Choices and request identity are retained for retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _activateRules() async {
    final rules = (data?['current'] as Map?)?['rules_version_id'] as String?;
    if (rules == null || busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          t('تفعيل هذا الإصدار صراحةً', 'Explicitly activate this version'),
        ),
        content: Text(
          t(
            'يتيح هذا الإصدار عروض حجز مكافأة فعلية وفق الشروط المحفوظة وبعد تحقق الخادم. حفظ إصدار لاحق لا يفعّله تلقائياً. لا تُستورد النقاط القديمة ولا تتحول الزيارات إلى نقود.',
            'This version permits actual reward booking quotes under its frozen terms after server checks. Saving a later version never activates it automatically. Legacy points are not imported and visits are not converted to cash.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('تفعيل هذا الإصدار', 'Activate this version')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    if (activatingRules != rules) {
      activatingRules = rules;
      activationRequest = hrRequestId();
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.activate(activationRequest!, rules);
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'التفعيل غير مؤكد. حدّث الحالة أو أعد نفس الطلب؛ الخادم يتحقق من الجاهزية الفعلية.',
            'Activation is unconfirmed. Refresh or retry the same request; the server checks actual readiness.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String label(String value) {
    final known = _optionLabels[value];
    return known == null ? value : t(known.$1, known.$2);
  }

  @override
  Widget build(BuildContext context) {
    final current = data?['current'] as Map?;
    final reward = data?['reward_service'] as Map?;
    final offer = data?['offer'] as Map?;
    final backend = data?['backend_readiness'] as Map? ?? {};
    final blockers = (data?['blockers'] as List? ?? []).cast<String>();
    final capabilitiesReady = [
      'quote_implemented',
      'booking_implemented',
      'allocation_implemented',
      'consumption_implemented',
      'release_implemented',
      'refund_resolution_implemented',
      'earning_rules_binding_implemented',
      'readers_integrated',
    ].every((key) => backend[key] == true);
    final canActivate =
        widget.gateway.activationAvailable &&
        capabilitiesReady &&
        data?['terms_valid'] == true &&
        data?['configuration_valid'] == true &&
        data?['current_rules_activated'] != true &&
        !blockers.any(
          (code) => [
            'policy_not_enabled',
            'earning_not_activated',
            'expiry_deadline_passed',
            'policy_not_current',
          ].contains(code),
        );
    final rewardReady =
        reward != null &&
        reward['is_active'] == true &&
        reward['is_public'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('شروط الاستبدال المستقبلية', 'Future redemption terms'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              data?['redemption_enabled'] == true
                  ? t(
                      'هذا الإصدار مفعل للاستبدال عبر حجز مكافأة صريح وبعرض يتحقق منه الخادم. حفظ شروط جديدة لا يفعّلها تلقائياً.',
                      'This version is activated for explicit reward booking with a server-validated quote. Saving new terms never activates them automatically.',
                    )
                  : t(
                      'الاستبدال الفعلي معطل لهذا الإصدار حتى اكتمال الجاهزية والتفعيل الصريح. حفظ الشروط لا يستهلك زيارات ولا يغير سعراً ولا يفعّل الاستبدال.',
                      'Actual redemption is disabled for this version until readiness and explicit activation. Saving terms consumes no visits, changes no price and does not enable redemption.',
                    ),
            ),
            if (widget.policyVersion == null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  t(
                    'احفظ سياسة أهلية فعلية أولاً؛ لا توجد سياسة مفترضة لهذا المحرر.',
                    'Save an actual eligibility policy first; this editor has no assumed policy.',
                  ),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error!),
              ),
            if (busy) const LinearProgressIndicator(),
            if (data == null && widget.policyVersion != null && !busy)
              TextButton(
                onPressed: load,
                child: Text(t('إعادة تحميل السياق', 'Reload context')),
              ),
            if (data != null) ...[
              const SizedBox(height: 16),
              Text(
                '${t('إصدار السياسة الفعلي', 'Actual policy version')}: ${data!['policy_version_no']}',
              ),
              Text(
                '${t('عرض الزيارات الفعلي', 'Actual visit offer')}: ${offer?['name'] ?? '—'}',
              ),
              Text(
                '${t('حد الزيارات المحفوظ', 'Saved visit threshold')}: ${data!['threshold_visits']}',
              ),
              Text(
                '${t('خدمة المكافأة الفعلية', 'Actual reward service')}: ${reward?['name'] ?? t('غير محددة', 'Not configured')}',
              ),
              Text(
                '${t('نهاية العرض المحفوظة', 'Frozen offer end')}: ${offer?['ends_at'] == null ? t('لا توجد نهاية مسجلة', 'No end recorded') : invoiceDate({'issued_at': offer!['ends_at']}, ar)}',
              ),
              const SizedBox(height: 12),
              Text(
                data!['rules_saved'] == true
                    ? t(
                        'يوجد إصدار شروط محفوظ؛ هذا لا يعني جاهزية الاستبدال.',
                        'A terms version is saved; this does not mean redemption is ready.',
                      )
                    : t(
                        'لا توجد شروط محفوظة؛ اختر كل قرار صراحةً.',
                        'No saved terms; choose every decision explicitly.',
                      ),
              ),
              Text(
                data!['terms_valid'] == true
                    ? t(
                        'الشروط صالحة وفق تحقق الخادم؛ حالة التفعيل معروضة أعلاه.',
                        'Terms pass server validation; activation status is shown above.',
                      )
                    : t(
                        'الشروط أو متطلباتها غير مكتملة وفق تحقق الخادم.',
                        'Terms or their prerequisites are incomplete according to server validation.',
                      ),
              ),
              if (blockers.any((code) => code.endsWith('_not_implemented')))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    t(
                      'المسار الفعلي غير مكتمل بعد؛ لا يمكن التفعيل حتى يتحقق الخادم من جميع المتطلبات.',
                      'The actual flow is not complete; activation requires all server prerequisites.',
                    ),
                  ),
                ),
              for (final code in blockers.where(
                (code) => !code.endsWith('_not_implemented'),
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _blockerLabels[code] == null
                        ? '${t('مانع من الخادم', 'Server blocker')}: $code'
                        : t(_blockerLabels[code]!.$1, _blockerLabels[code]!.$2),
                  ),
                ),
              if (canActivate)
                FilledButton(
                  onPressed: busy ? null : _activateRules,
                  child: Text(
                    t(
                      'مراجعة وتفعيل الاستبدال لهذا الإصدار',
                      'Review and activate redemption for this version',
                    ),
                  ),
                ),
              TextButton(
                onPressed: busy ? null : load,
                child: Text(
                  t('تحديث جاهزية الشروط', 'Refresh terms readiness'),
                ),
              ),
              if (current != null) ...[
                const SizedBox(height: 16),
                Text(
                  '${t('إصدار الشروط المحفوظ', 'Saved terms version')}: ${current['version_no']}',
                ),
                Text(invoiceDate({'issued_at': current['created_at']}, ar)),
                for (final entry in _ruleLabels.entries)
                  Text(
                    '${t(entry.value.$1, entry.value.$2)}: ${label('${(current['rules'] as Map?)?[entry.key] ?? '—'}')}',
                  ),
              ],
              if (current != null &&
                  widget.gateway is SupabaseRedemptionRulesGateway)
                OwnerMixedVisitPolicyPanel(
                  key: ValueKey(
                    'mixed-visit-${(widget.gateway as SupabaseRedemptionRulesGateway).client.auth.currentUser?.id}-${current['rules_version_id']}',
                  ),
                  client:
                      (widget.gateway as SupabaseRedemptionRulesGateway).client,
                  branch: data!['branch_id'] as String,
                  rules: current['rules_version_id'] as String,
                ),
              if ((data!['history'] as List? ?? []).isNotEmpty)
                ExpansionTile(
                  title: Text(t('سجل إصدارات الشروط', 'Terms version history')),
                  children: [
                    for (final item in (data!['history'] as List))
                      ListTile(
                        title: Text(
                          '${t('الإصدار', 'Version')} ${item['version_no']}',
                        ),
                        subtitle: Text(
                          '${invoiceDate({'issued_at': item['created_at']}, ar)}\n${[for (final rule in _ruleLabels.entries) '${t(rule.value.$1, rule.value.$2)}: ${label('${(item['rules'] as Map?)?[rule.key] ?? '—'}')}'].join('\n')}',
                        ),
                      ),
                  ],
                ),
              if (rewardReady) ...[
                const SizedBox(height: 20),
                Text(
                  t(
                    'إصدار مستقبلي جديد: لا تُعبّأ الاختيارات تلقائياً من الإصدار السابق.',
                    'New future version: choices are not prefilled from the saved version.',
                  ),
                ),
                for (final entry in _ruleLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        'redemption-$draftRevision-${current?['rules_version_id']}-${entry.key}',
                      ),
                      initialValue: choices[entry.key],
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: t(entry.value.$1, entry.value.$2),
                        border: const OutlineInputBorder(),
                      ),
                      hint: Text(t('اختر صراحةً', 'Choose explicitly')),
                      items: [
                        for (final value
                            in ((data!['supported_rules'] as Map?)?[entry.key]
                                    as List? ??
                                []))
                          DropdownMenuItem<String>(
                            value: '$value',
                            enabled:
                                value != 'snapshot_offer_end' ||
                                offer?['ends_at'] != null,
                            child: Text(
                              label('$value'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setState(() {
                              if (v != null) choices[entry.key] = v;
                            }),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  t(
                    'في خياري الاسترداد تُحترم المكافأة الصادرة ولا تُفرض مبالغ بأثر رجعي؛ الاختيار يحدد التعامل مع الاستحقاق المستقبلي فقط.',
                    'Both refund choices honor the issued reward and never charge money retroactively; the choice governs future eligibility only.',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed:
                      busy ||
                          _ruleLabels.keys.any((key) => choices[key] == null)
                      ? null
                      : save,
                  child: Text(
                    t('حفظ إصدار شروط مستقبلي', 'Save future terms version'),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    t(
                      'لا يمكن إعداد إصدار جديد دون خدمة مكافأة فعلية نشطة ومنشورة ضمن السياسة. صحح العرض واحفظ سياسة جديدة أولاً.',
                      'A new version requires an actual active published reward service in the policy. Correct the offer and save a new policy first.',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

const _ruleLabels = {
  'pooling': ('تجميع الزيارات', 'Visit pooling'),
  'expiry': ('انتهاء صلاحية الزيارات', 'Visit expiry'),
  'cancellation': ('إلغاء حجز المكافأة', 'Reward booking cancellation'),
  'refunded_contribution': (
    'استرداد زيارة ساهمت في الرصيد',
    'Refunded contributing visit',
  ),
};
const _optionLabels = {
  'policy_version': ('نفس إصدار السياسة فقط', 'Same policy version only'),
  'offer_branch': (
    'نفس العرض والفرع عبر إصدارات السياسة',
    'Same offer and branch across policy versions',
  ),
  'no_expiry': ('دون انتهاء صلاحية', 'No expiry'),
  'snapshot_offer_end': (
    'نهاية العرض المحفوظة في السياسة',
    'Frozen policy offer end',
  ),
  'restore_visits': (
    'إعادة الزيارات إلى الرصيد',
    'Restore visits to the balance',
  ),
  'forfeit_visits': ('عدم إعادة الزيارات', 'Do not restore visits'),
  'offset_future_visits': (
    'احترام المكافأة وخصم الأثر من الزيارات المستقبلية',
    'Honor reward; offset future visits',
  ),
  'freeze_for_owner_review': (
    'احترام المكافأة وتجميد الاستبدال المستقبلي لمراجعة المالك',
    'Honor reward; freeze future redemption for owner review',
  ),
};
const _blockerLabels = {
  'redemption_not_activated': (
    'هذا الإصدار لم يُفعّل للاستبدال بعد.',
    'This version is not activated for redemption.',
  ),
  'redemption_rules_not_saved': (
    'لا توجد شروط استبدال محفوظة.',
    'No redemption terms are saved.',
  ),
  'policy_not_current': (
    'السياسة ليست أحدث إصدار؛ أعد تحميل السياق.',
    'The policy is not current; reload context.',
  ),
  'policy_not_enabled': (
    'سياسة الأهلية غير مفعلة.',
    'The eligibility policy is not enabled.',
  ),
  'offer_not_active_or_public': (
    'العرض الحالي ليس نشطاً ومنشوراً.',
    'The current offer is not active and public.',
  ),
  'offer_terms_changed': (
    'تغيرت شروط العرض عن لقطة السياسة.',
    'Offer terms differ from the frozen policy snapshot.',
  ),
  'threshold_invalid': (
    'حد الزيارات المحفوظ غير صالح.',
    'The saved visit threshold is invalid.',
  ),
  'reward_service_missing': (
    'خدمة المكافأة الفعلية غير محددة.',
    'The actual reward service is missing.',
  ),
  'reward_service_unavailable': (
    'خدمة المكافأة ليست نشطة ومنشورة في الفرع.',
    'The branch reward service is not active and published.',
  ),
  'expiry_deadline_missing': (
    'خيار انتهاء الصلاحية يتطلب نهاية عرض محفوظة فعلية.',
    'Expiry requires a real frozen offer end.',
  ),
  'expiry_deadline_passed': (
    'انقضت نهاية العرض المحفوظة.',
    'The frozen offer end has passed.',
  ),
  'earning_not_activated': (
    'احتساب الزيارات غير مفعل.',
    'Visit earning is not activated.',
  ),
  'redemption_quote_not_implemented': (
    'تسعير الاستبدال غير منفذ بعد.',
    'Redemption quoting is not implemented.',
  ),
  'booking_redemption_not_implemented': (
    'ربط الاستبدال بالحجز غير منفذ بعد.',
    'Booking redemption is not implemented.',
  ),
  'visit_reservation_not_implemented': (
    'حجز الزيارات للاستبدال غير منفذ بعد.',
    'Visit reservation is not implemented.',
  ),
  'visit_consumption_not_implemented': (
    'استهلاك الزيارات للاستبدال غير منفذ بعد.',
    'Visit consumption is not implemented.',
  ),
  'visit_release_not_implemented': (
    'تحرير الزيارات المحجوزة غير منفذ بعد.',
    'Visit release is not implemented.',
  ),
  'reward_invoice_document_state_not_implemented': (
    'حالة مستند فاتورة المكافأة غير منفذة بعد.',
    'Reward invoice document state is not implemented.',
  ),
  'refunded_contribution_resolution_not_implemented': (
    'معالجة أثر الزيارات المستردة غير منفذة بعد.',
    'Refunded contribution resolution is not implemented.',
  ),
  'owner_refund_review_resolution_not_implemented': (
    'مسار حسم مراجعة المالك للاسترداد غير منفذ بعد.',
    'Owner refund review resolution is not implemented.',
  ),
};
