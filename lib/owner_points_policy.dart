import 'dart:async';

import 'owner_points_operations.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'invoice_presentation.dart' show invoiceDate;
import 'workflow.dart' show newOrderRequestId;

abstract class OwnerPointsGateway {
  bool get current;
  Stream<void> get changes;
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

class SupabaseOwnerPointsGateway implements OwnerPointsGateway {
  SupabaseOwnerPointsGateway(this.client)
    : session = client.auth.currentSession;
  final SupabaseClient client;
  final Session? session;
  @override
  bool get current =>
      session != null &&
      client.auth.currentSession?.accessToken == session!.accessToken &&
      client.auth.currentUser?.id == session!.user.id;
  @override
  Stream<void> get changes => client.auth.onAuthStateChange
      .where((e) => !matchesInitialAuthReplay(e, session))
      .map((_) {});
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current ||
        !const {
          'get_owner_mixed_points_policy',
          'get_owner_mixed_points_operations',
          'save_owner_mixed_points_verbal_policy',
          'decide_owner_mixed_points_refund_review',
          'save_owner_mixed_points_policy',
        }.contains(name)) {
      throw StateError('Owner session unavailable');
    }
    final result = Map<String, dynamic>.from(
      await client
              .rpc(name, params: params)
              .timeout(const Duration(seconds: 25))
          as Map,
    );
    if (!current) throw StateError('Owner session changed');
    return result;
  }
}

/// Explicit, versioned future terms. This editor never activates earning or spending.
class OwnerPointsPolicyPanel extends StatefulWidget {
  const OwnerPointsPolicyPanel({
    super.key,
    required this.gateway,
    required this.branch,
  });
  final OwnerPointsGateway gateway;
  final String branch;
  @override
  State<OwnerPointsPolicyPanel> createState() => _OwnerPointsPolicyPanelState();
}

class _OwnerPointsPolicyPanelState extends State<OwnerPointsPolicyPanel> {
  final fields = <String, TextEditingController>{};
  final rates = <String, TextEditingController>{};
  final eligible = <String>{}, earning = <String>{};
  final choices = <String, bool>{};
  StreamSubscription<void>? changes;
  Map<String, dynamic>? data, pending;
  int epoch = 0, version = 0;
  bool busy = true, invalid = false;
  String? error, cancellation, refunded, basis;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool get active => mounted && !invalid && widget.gateway.current;
  bool get editable => active && !busy && pending == null;
  List<Map<String, dynamic>> get catalog =>
      List<Map<String, dynamic>>.from(data?['catalog'] ?? []);
  String label(Map<String, dynamic> item) =>
      !ar && (item['name_en']?.toString().trim().isNotEmpty ?? false)
      ? item['name_en']
      : item['name'];
  @override
  void initState() {
    super.initState();
    connect();
  }

  void connect() {
    changes = widget.gateway.changes.listen((_) {
      if (mounted) {
        setState(() {
          epoch++;
          invalid = true;
          data = pending = null;
          clear();
        });
      }
    });
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant OwnerPointsPolicyPanel old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway || old.branch != widget.branch) {
      epoch++;
      unawaited(changes?.cancel());
      clear();
      invalid = false;
      data = pending = null;
      busy = true;
      connect();
    }
  }

  void clear() {
    for (final c in [...fields.values, ...rates.values]) {
      c.dispose();
    }
    fields.clear();
    rates.clear();
    eligible.clear();
    earning.clear();
    choices.clear();
    cancellation = refunded = basis = null;
  }

  @override
  void dispose() {
    epoch++;
    unawaited(changes?.cancel());
    clear();
    super.dispose();
  }

  Future<void> load() async {
    if (!active || pending != null) return;
    final generation = ++epoch;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.call(
        'get_owner_mixed_points_policy',
        {'p_branch': widget.branch},
      );
      if (!active || generation != epoch) return;
      if (result['earning_enabled'] != false ||
          result['redemption_enabled'] != false ||
          result['legacy_balance_conversion_supported'] != false) {
        throw StateError('Unexpected points capabilities');
      }
      clear();
      data = result;
      version = result['version'] as int;
      final rules = Map<String, dynamic>.from(
        (result['current'] as Map?)?['rules'] ?? {},
      );
      for (final k in [
        'point_value_egp',
        'minimum_points',
        'maximum_points',
        'minimum_invoice_egp',
        'maximum_discount_egp',
        'maximum_discount_percent',
      ]) {
        fields[k] = TextEditingController(text: rules[k]?.toString() ?? '');
      }
      fields['reason'] = TextEditingController();
      eligible.addAll(List<String>.from(rules['eligible_item_ids'] ?? []));
      for (final k in [
        'allow_walk_in',
        'allow_booking',
        'allow_coupon',
        'allow_offer',
        'allow_manual_discount',
      ]) {
        choices[k] = rules[k] == true;
      }
      basis = rules['point_value_basis'];
      cancellation = rules['cancellation'];
      refunded = rules['refunded_contribution'];
      for (final item in catalog.where((i) => i['item_type'] == 'service')) {
        rates[item['item_id']] = TextEditingController();
      }
      for (final row in List<Map<String, dynamic>>.from(
        rules['earning_rates'] ?? [],
      )) {
        final id = row['item_id'] as String;
        earning.add(id);
        rates.putIfAbsent(id, () => TextEditingController()).text =
            row['points_per_completed_unit'].toString();
      }
      error = null;
    } catch (_) {
      if (active && generation == epoch) {
        error = t(
          'تعذر تحميل شروط النقاط. حاول مرة أخرى.',
          'Unable to load point terms. Please retry.',
        );
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  String digits(String value) {
    const a = '٠١٢٣٤٥٦٧٨٩', b = '۰۱۲۳۴۵۶۷۸۹';
    return value
        .trim()
        .split('')
        .map(
          (c) => a.contains(c)
              ? a.indexOf(c).toString()
              : b.contains(c)
              ? b.indexOf(c).toString()
              : c == '٫'
              ? '.'
              : c,
        )
        .join();
  }

  Future<void> save() async {
    if (!active || busy || data == null) return;
    final generation = epoch;
    if (pending == null) {
      try {
        final rules = <String, dynamic>{
          'unit': 'reward_points_v1',
          'point_value_basis': basis,
          ...choices,
          'eligible_item_ids': eligible.toList()..sort(),
          'earning_rates': earning
              .map(
                (id) => {
                  'item_id': id,
                  'points_per_completed_unit': int.parse(
                    digits(rates[id]!.text),
                  ),
                },
              )
              .toList(),
          'cancellation': cancellation,
          'refunded_contribution': refunded,
        };
        for (final k in [
          'point_value_egp',
          'minimum_points',
          'maximum_points',
          'minimum_invoice_egp',
          'maximum_discount_egp',
          'maximum_discount_percent',
        ]) {
          final value = num.parse(digits(fields[k]!.text));
          if (!value.isFinite) throw const FormatException();
          rules[k] = value;
        }
        if (eligible.isEmpty ||
            earning.isEmpty ||
            basis == null ||
            cancellation == null ||
            refunded == null ||
            fields['reason']!.text.trim().length < 5) {
          throw const FormatException();
        }
        pending = {
          'p_request': newOrderRequestId(),
          'p_branch': widget.branch,
          'p_expected_version': version,
          'p_rules': rules,
          'p_reason': fields['reason']!.text.trim(),
        };
      } catch (_) {
        setState(
          () => error = t(
            'أكمل القيم والخدمات والقواعد وسبب التغيير بوضوح.',
            'Complete the values, services, rules and change reason.',
          ),
        );
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.call(
        'save_owner_mixed_points_policy',
        pending!,
      );
      if (!active || generation != epoch) return;
      if (result['future_rules_saved'] != true ||
          result['earning_enabled'] != false ||
          result['redemption_enabled'] != false ||
          result['legacy_balances_imported'] != false ||
          result['version'] != version + 1) {
        throw StateError('Invalid future policy receipt');
      }
      pending = null;
      await load();
    } on PostgrestException catch (e) {
      if (active && generation == epoch) {
        if (const {'22023', '40001'}.contains(e.code)) pending = null;
        error = t(
          'لم تُحفظ الشروط. راجع القيم أو أعد تحميل النسخة الحالية.',
          'Terms were not saved. Review values or reload the current version.',
        );
      }
    } catch (_) {
      if (active && generation == epoch) {
        error = t(
          'تعذر تأكيد الحفظ. أعد محاولة نفس الطلب دون تغيير القيم.',
          'Save could not be confirmed. Retry the same request without changing values.',
        );
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Widget number(String key, String a, String e) => SizedBox(
    width: 240,
    child: TextField(
      key: ValueKey('points_$key'),
      controller: fields[key],
      enabled: editable,
      decoration: InputDecoration(labelText: t(a, e)),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    ),
  );
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('قواعد نقاط الولاء المستقبلية', 'Future loyalty point terms'),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xff071a36),
            ),
          ),
          Text(
            t(
              'حفظ الشروط لا يفعّل اكتساب النقاط أو صرفها، ولا يحوّل أرصدة الزيارات السابقة.',
              'Saving terms enables neither earning nor spending and does not convert previous visit balances.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (invalid || !widget.gateway.current)
            Text(
              t(
                'أعد تسجيل الدخول لإدارة الشروط.',
                'Sign in again to manage terms.',
              ),
            ),
          if (error != null) Text(error!),
          if (data != null && active) ...[
            Text(t('نسخة الشروط: $version', 'Terms version: $version')),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                number(
                  'point_value_egp',
                  'قيمة النقطة بالجنيه',
                  'Point value in EGP',
                ),
                number(
                  'minimum_points',
                  'أقل عدد نقاط للاستبدال',
                  'Minimum redeemable points',
                ),
                number(
                  'maximum_points',
                  'أقصى عدد نقاط للاستبدال',
                  'Maximum redeemable points',
                ),
                number(
                  'minimum_invoice_egp',
                  'الحد الأدنى للفاتورة بالجنيه',
                  'Minimum invoice in EGP',
                ),
                number(
                  'maximum_discount_egp',
                  'أقصى خصم بالجنيه',
                  'Maximum discount in EGP',
                ),
                number(
                  'maximum_discount_percent',
                  'أقصى نسبة خصم %',
                  'Maximum discount %',
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: const ValueKey('points_value_basis'),
              initialValue: basis,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t('أساس قيمة النقطة', 'Point value basis'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'gross_payable',
                  child: Text(
                    t(
                      'خفض المبلغ النهائي الشامل',
                      'Reduce the final payable amount',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'pre_tax_base',
                  child: Text(
                    t(
                      'خصم من السعر قبل الضريبة',
                      'Discount the price before tax',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: editable ? (v) => setState(() => basis = v) : null,
            ),
            if (basis == null)
              Text(
                t(
                  'اختر أساس قيمة النقطة قبل حفظ إصدار جديد؛ الإصدارات السابقة محفوظة.',
                  'Choose a point value basis before saving a new version; previous versions are preserved.',
                ),
              ),
            for (final item in <(String, String, String)>[
              ('allow_walk_in', 'الزيارات المباشرة', 'Walk-in visits'),
              ('allow_booking', 'الحجوزات', 'Bookings'),
              (
                'allow_coupon',
                'السماح مع كوبون مؤهل',
                'Allow with an eligible coupon',
              ),
              (
                'allow_offer',
                'السماح مع عرض مؤهل',
                'Allow with an eligible offer',
              ),
              (
                'allow_manual_discount',
                'السماح مع خصم يدوي',
                'Allow with a manual discount',
              ),
            ])
              CheckboxListTile(
                value: choices[item.$1] ?? false,
                onChanged: editable
                    ? (v) => setState(() => choices[item.$1] = v!)
                    : null,
                title: Text(t(item.$2, item.$3)),
              ),
            ExpansionTile(
              title: Text(
                t('بنود الاستبدال المؤهلة', 'Eligible redemption items'),
              ),
              children: [
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: catalog.length,
                    itemBuilder: (c, i) {
                      final row = catalog[i], id = row['item_id'] as String;
                      return CheckboxListTile(
                        value: eligible.contains(id),
                        onChanged: editable
                            ? (v) => setState(
                                () =>
                                    v! ? eligible.add(id) : eligible.remove(id),
                              )
                            : null,
                        title: Text(label(row)),
                      );
                    },
                  ),
                ),
              ],
            ),
            ExpansionTile(
              title: Text(
                t(
                  'النقاط لكل وحدة خدمة مكتملة ومدفوعة',
                  'Points per completed and paid service unit',
                ),
              ),
              children: [
                for (final row in catalog.where(
                  (r) => r['item_type'] == 'service',
                ))
                  Column(
                    children: [
                      CheckboxListTile(
                        value: earning.contains(row['item_id']),
                        onChanged: editable
                            ? (v) => setState(
                                () => v!
                                    ? earning.add(row['item_id'])
                                    : earning.remove(row['item_id']),
                              )
                            : null,
                        title: Text(label(row)),
                      ),
                      if (earning.contains(row['item_id']))
                        TextField(
                          key: ValueKey('points_rate_${row['item_id']}'),
                          controller: rates[row['item_id']],
                          enabled: editable,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('عدد النقاط', 'Number of points'),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: cancellation,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t('إلغاء المكافأة', 'Reward cancellation'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'restore_points',
                  child: Text(
                    t(
                      'إعادة النقاط وفق الاستحقاق الأصلي',
                      'Restore points under original entitlement',
                    ),
                  ),
                ),
                DropdownMenuItem(
                  value: 'forfeit_points',
                  child: Text(t('عدم إعادة النقاط', 'Do not restore points')),
                ),
              ],
              onChanged: editable
                  ? (v) => setState(() => cancellation = v)
                  : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: refunded,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t(
                  'استرداد خدمة ساهمت بالنقاط',
                  'Refund of a contributing service',
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: 'offset_future_points',
                  child: Text(
                    t('تسوية من النقاط المستقبلية', 'Offset future points'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'freeze_for_owner_review',
                  child: Text(
                    t(
                      'تعليق للمراجعة بواسطة المالك',
                      'Freeze for owner review',
                    ),
                  ),
                ),
              ],
              onChanged: editable ? (v) => setState(() => refunded = v) : null,
            ),
            TextField(
              key: const ValueKey('points_reason'),
              controller: fields['reason'],
              enabled: editable,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t('سبب التغيير', 'Change reason'),
              ),
            ),
            FilledButton(
              onPressed: active && !busy ? save : null,
              child: Text(
                pending == null
                    ? t('حفظ الشروط المستقبلية', 'Save future terms')
                    : t('إعادة محاولة نفس الحفظ', 'Retry the same save'),
              ),
            ),
          ],
          if (data != null && active)
            OwnerPointsOperationsPanel(
              key: ValueKey('points-operations-${widget.branch}'),
              gateway: widget.gateway,
              branch: widget.branch,
            ),
          if (data != null && active)
            ExpansionTile(
              title: Text(t('سجل شروط النقاط', 'Point terms history')),
              children: [
                for (final row in List<Map<String, dynamic>>.from(
                  data?['history'] ?? [],
                ))
                  ListTile(
                    title: Text(
                      t(
                        'الإصدار ${row['version']}',
                        'Version ${row['version']}',
                      ),
                    ),
                    subtitle: Text(
                      '${invoiceDate({'issued_at': row['created_at']}, ar)}\n${row['reason'] ?? ''}',
                    ),
                  ),
              ],
            ),
          OutlinedButton(
            onPressed: active && !busy && pending == null ? load : null,
            child: Text(t('إعادة تحميل الشروط', 'Reload terms')),
          ),
        ],
      ),
    ),
  );
}
