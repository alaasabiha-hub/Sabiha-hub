import 'dart:async';

import 'owner_visit_cashier_grants.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;
import 'current_catalog.dart' show normalizedNumericInput;
import 'invoice_presentation.dart' show invoiceDate;

abstract class MixedVisitPolicyGateway {
  Future<Map<String, dynamic>> read(String branch, String rules);
  Future<Map<String, dynamic>> save(Map<String, dynamic> args);
}

class SupabaseMixedVisitPolicyGateway implements MixedVisitPolicyGateway {
  SupabaseMixedVisitPolicyGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  void check() {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Account scope changed');
    }
  }

  @override
  Future<Map<String, dynamic>> read(String branch, String rules) async {
    check();
    final x = Map<String, dynamic>.from(
      await client.rpc(
        'get_owner_mixed_visit_policy',
        params: {'p_branch': branch, 'p_rules': rules},
      ),
    );
    check();
    return x;
  }

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> args) async {
    check();
    final x = Map<String, dynamic>.from(
      await client.rpc('save_owner_mixed_visit_policy', params: args),
    );
    check();
    return x;
  }
}

/// Explicit future terms, never an activation control or an entitlement debit.
class OwnerMixedVisitPolicyPanel extends StatefulWidget {
  const OwnerMixedVisitPolicyPanel({
    super.key,
    this.client,
    this.gateway,
    required this.branch,
    required this.rules,
  }) : assert(client != null || gateway != null);
  final SupabaseClient? client;
  final MixedVisitPolicyGateway? gateway;
  final String branch, rules;
  @override
  State<OwnerMixedVisitPolicyPanel> createState() => _MixedVisitPolicyState();
}

class _MixedVisitPolicyState extends State<OwnerMixedVisitPolicyPanel> {
  late MixedVisitPolicyGateway gateway;
  StreamSubscription<AuthState>? auth;
  Map<String, dynamic>? data;
  final maxUnits = TextEditingController(),
      minimum = TextEditingController(),
      reference = TextEditingController(),
      reason = TextEditingController();
  bool busy = false, frozen = false;
  bool? walkIn, manual;
  String? tax, error, request, signature;
  int epoch = 0;
  String? actor;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  bool get current =>
      mounted &&
      !frozen &&
      (widget.client == null || widget.client!.auth.currentUser?.id == actor);
  @override
  void initState() {
    super.initState();
    configure();
  }

  void configure() {
    actor = widget.client?.auth.currentUser?.id;
    gateway = widget.gateway ?? SupabaseMixedVisitPolicyGateway(widget.client!);
    auth = widget.client?.auth.onAuthStateChange.listen((e) {
      if (mounted && widget.client!.auth.currentUser?.id != actor) {
        frozen = true;
        epoch++;
        clear();
        setState(() {
          busy = false;
        });
      }
    });
    load();
  }

  void clear() {
    data = null;
    walkIn = null;
    manual = null;
    tax = null;
    error = null;
    request = null;
    signature = null;
    for (final c in [maxUnits, minimum, reference, reason]) {
      c.clear();
    }
  }

  @override
  void didUpdateWidget(covariant OwnerMixedVisitPolicyPanel old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client ||
        old.gateway != widget.gateway ||
        old.branch != widget.branch ||
        old.rules != widget.rules) {
      epoch++;
      auth?.cancel();
      clear();
      frozen = false;
      configure();
    }
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    for (final c in [maxUnits, minimum, reference, reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    if (!current) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final x = await gateway.read(widget.branch, widget.rules);
      if (!current || generation != epoch) return;
      if (x['unit'] != 'service_visits' ||
          x['future_terms_only'] != true ||
          x['branch_id'] != widget.branch ||
          x['rules_version_id'] != widget.rules) {
        throw const FormatException('Invalid policy scope');
      }
      final saved = x['current'] as Map?;
      final terms = saved?['terms'] as Map?;
      setState(() {
        data = x;
        if (terms != null) {
          walkIn = terms['allow_walk_in'] as bool;
          manual = terms['allow_manual_discount'] as bool;
          tax = terms['tax_treatment'] as String;
          maxUnits.text = '${terms['maximum_covered_units']}';
          minimum.text = '${terms['minimum_invoice_egp']}';
          reference.text = '${terms['tax_review_reference']}';
        }
      });
    } catch (_) {
      if (current && generation == epoch) {
        setState(() {
          data = null;
          error = t(
            'تعذر التحقق من شروط المالك.',
            'Owner terms could not be verified.',
          );
        });
      }
    } finally {
      if (current && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!current || busy || data == null) return;
    final units = int.tryParse(normalizedNumericInput(maxUnits.text)),
        amount = num.tryParse(normalizedNumericInput(minimum.text));
    if (walkIn == null ||
        manual == null ||
        tax == null ||
        units == null ||
        units < 1 ||
        amount == null ||
        !amount.isFinite ||
        amount < 0 ||
        reference.text.trim().length < 10 ||
        reason.text.trim().length < 10) {
      setState(
        () => error = t(
          'اختر جميع الشروط وأدخل الحدود ومرجع المراجعة وسبب التغيير بوضوح.',
          'Choose all terms and enter limits, review reference and change reason.',
        ),
      );
      return;
    }
    final args = <String, dynamic>{
      'p_branch': widget.branch,
      'p_rules': widget.rules,
      'p_expected_version': (data!['current'] as Map?)?['version_no'] ?? 0,
      'p_terms': {
        'unit': 'service_visits',
        'allow_walk_in': walkIn,
        'tax_treatment': tax,
        'tax_review_reference': reference.text.trim(),
        'allow_manual_discount': manual,
        'maximum_covered_units': units,
        'minimum_invoice_egp': amount,
      },
      'p_reason': reason.text.trim(),
    };
    final sig = jsonEncode(args);
    if (signature != sig) {
      signature = sig;
      request = newOrderRequestId();
    }
    args['p_request'] = request;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final x = await gateway.save(args);
      if (!current || generation != epoch) return;
      if (x['version_id'] != request ||
          x['future_terms_only'] != true ||
          x['redemption_activated'] != false ||
          x['prior_invoices_changed'] != false) {
        throw const FormatException('Unconfirmed future policy');
      }
      reason.clear();
      await load();
    } catch (_) {
      if (current && generation == epoch) {
        setState(
          () => error = t(
            'لم نتأكد من الحفظ. أعد نفس المحاولة أو حدّث الشروط؛ الصرف لم يُفعّل.',
            'Save is unconfirmed. Retry unchanged or refresh terms; redemption was not enabled.',
          ),
        );
      }
    } finally {
      if (current && generation == epoch) setState(() => busy = false);
    }
  }

  Widget choice(
    String key,
    String ar,
    String en,
    bool? value,
    void Function(bool?) changed,
  ) => DropdownButtonFormField<bool>(
    key: ValueKey('$key-$epoch-$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: t(ar, en)),
    items: [
      DropdownMenuItem(value: false, child: Text(t('لا', 'No'))),
      DropdownMenuItem(value: true, child: Text(t('نعم', 'Yes'))),
    ],
    onChanged: busy ? null : changed,
  );
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t(
              'مكافآت الزيارات بالفاتورة المختلطة — شروط مستقبلية',
              'Visit rewards in mixed invoices — future terms',
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            t(
              'حفظ الشروط لا يحجز زيارات ولا يفعّل الصرف ولا يغيّر الفواتير أو الحقوق السابقة. المعالجة الضريبية تحتاج مراجعة صريحة من المالك؛ لا نتحقق قانونيًا منها تلقائيًا.',
              'Saving terms does not reserve visits, enable redemption or alter past invoices or rights. Tax treatment requires explicit owner review; it is not legally verified automatically.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          if (!current)
            Text(
              t(
                'تغيّر الحساب. أعد فتح الشاشة.',
                'Account changed. Reopen this screen.',
              ),
            ),
          if (current)
            OutlinedButton(
              onPressed: busy ? null : load,
              child: Text(
                t(
                  'تحديث شروط الفاتورة المختلطة',
                  'Refresh mixed-invoice terms',
                ),
              ),
            ),
          if (widget.client != null && current)
            OwnerVisitCashierGrantsPanel(
              client: widget.client,
              branch: widget.branch,
              rules: widget.rules,
            ),
          if (data != null && current) ...[
            Text(
              '${t('الإصدار المحفوظ', 'Saved version')}: ${(data!['current'] as Map?)?['version_no'] ?? 0}',
            ),
            Text(
              t(
                'اكتمال مسار إصدار مكافأة الزيارة ما زال مطلوبًا قبل التشغيل.',
                'The visit-reward issuance flow still needs completion before operation.',
              ),
            ),
            const SizedBox(height: 12),
            choice(
              'walk-in',
              'السماح المستقبلي للزيارة المباشرة',
              'Future walk-in permission',
              walkIn,
              (v) => setState(() => walkIn = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('tax-$epoch-$tax'),
              initialValue: tax,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t(
                  'معالجة تغطية المكافأة الضريبية',
                  'Reward tax treatment',
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: 'commercial_before_tax',
                  child: Text(
                    t(
                      'خصم تجاري قبل الضريبة',
                      'Commercial discount before tax',
                    ),
                  ),
                ),
              ],
              onChanged: busy ? null : (v) => setState(() => tax = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reference,
              enabled: !busy,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t(
                  'مرجع مراجعة المعالجة الضريبية',
                  'Tax treatment review reference',
                ),
              ),
            ),
            choice(
              'manual',
              'السماح بالجمع مع الخصم اليدوي',
              'Allow manual-discount composition',
              manual,
              (v) => setState(() => manual = v),
            ),
            TextField(
              controller: maxUnits,
              enabled: !busy,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t(
                  'أقصى وحدات خدمة تغطيها المكافأة',
                  'Maximum covered service units',
                ),
              ),
            ),
            TextField(
              controller: minimum,
              enabled: !busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t(
                  'الحد الأدنى للفاتورة بالجنيه',
                  'Minimum invoice in EGP',
                ),
              ),
            ),
            TextField(
              controller: reason,
              enabled: !busy,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t(
                  'سبب إصدار الشروط الجديدة',
                  'Reason for new terms version',
                ),
              ),
            ),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(t('حفظ شروط مستقبلية فقط', 'Save future terms only')),
            ),
            for (final h in (data!['history'] as List? ?? []))
              Text(
                '${t('الإصدار', 'Version')} ${h['version_no']} · ${invoiceDate({'issued_at': h['created_at']}, Localizations.localeOf(context).languageCode == 'ar')}',
              ),
          ],
        ],
      ),
    ),
  );
}
