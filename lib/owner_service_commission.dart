import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_tax_invoice_settings.dart';
import 'dropdown_options.dart';
import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

class ServiceCommissionGateway implements OwnerTaxGateway {
  ServiceCommissionGateway(this.client) : session = client.auth.currentSession;
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
          'get_owner_service_commission_context',
          'save_owner_service_commission',
          'preview_owner_service_commission',
        }.contains(name)) {
      throw StateError('Owner session unavailable');
    }
    final result = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 25));
    if (!current) {
      throw StateError('Owner session changed');
    }
    return Map<String, dynamic>.from(result as Map);
  }
}

class OwnerServiceCommissionScreen extends StatefulWidget {
  const OwnerServiceCommissionScreen({super.key, required this.gateway});
  final OwnerTaxGateway gateway;
  @override
  State<OwnerServiceCommissionScreen> createState() =>
      _OwnerServiceCommissionScreenState();
}

class _OwnerServiceCommissionScreenState
    extends State<OwnerServiceCommissionScreen> {
  Map<String, dynamic>? data, preview, pending;
  String? item, error;
  String mode = 'percentage', split = 'equal';
  bool enabled = true, busy = false, invalid = false;
  int epoch = 0;
  final value = TextEditingController(),
      reason = TextEditingController(),
      base = TextEditingController();
  final shares = <String, TextEditingController>{};
  final crew = <String>{};
  StreamSubscription<void>? subscription;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool get editable =>
      !busy && !invalid && pending == null && widget.gateway.current;
  List<Map<String, dynamic>> rows(String key) {
    final raw = List<Map<String, dynamic>>.from(data?[key] ?? []);
    return switch (key) {
      'items' => uniqueDropdownRows(raw, 'item_id'),
      'staff' => uniqueDropdownRows(raw, 'staff_id'),
      _ => raw,
    };
  }

  Map<String, dynamic>? get selected =>
      rows('items').where((x) => x['item_id'] == item).firstOrNull;
  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.changes.listen((_) {
      epoch++;
      if (mounted) {
        setState(() {
          invalid = true;
          data = null;
          preview = null;
          pending = null;
        });
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    for (final c in [value, reason, base, ...shares.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void choose(String? id) {
    item = id;
    preview = null;
    crew.clear();
    final p = selected?['policy'] as Map?;
    mode = p?['mode'] ?? 'percentage';
    split = p?['split_mode'] ?? 'equal';
    enabled = p?['enabled'] ?? true;
    value.text = '${p?['value'] ?? 0}';
    reason.clear();
    for (final c in shares.values) {
      c.clear();
    }
    for (final x in p?['shares'] ?? []) {
      shares[x['staff_id']]?.text = '${x['percent']}';
      crew.add(x['staff_id']);
    }
  }

  Future<void> load() async {
    final generation = epoch;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.call(
        'get_owner_service_commission_context',
        {},
      );
      if (!mounted || generation != epoch) return;
      setState(() {
        data = result;
        for (final x in rows('staff')) {
          shares.putIfAbsent(x['staff_id'], () => TextEditingController());
        }
        choose(item ?? rows('items').firstOrNull?['item_id']);
        error = null;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(
          () => error = t(
            'تعذر تحميل إعدادات المالك.',
            'Unable to load owner settings.',
          ),
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> act(bool save) async {
    final generation = epoch;
    if (!widget.gateway.current || busy || invalid) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final allocations = [
        if (split == 'configured' && pending == null)
          for (final id in crew.toList()..sort())
            {'staff_id': id, 'percent': num.parse(shares[id]!.text)},
      ];
      if (save && pending == null) {
        pending = Map<String, dynamic>.from(
          jsonDecode(
            jsonEncode({
              'p_request': newOrderRequestId(),
              'p_branch': data!['branch'],
              'p_item': item,
              'p_expected_version':
                  (selected?['policy'] as Map?)?['version'] ?? 0,
              'p_enabled': enabled,
              'p_mode': mode,
              'p_value': num.parse(value.text),
              'p_split_mode': split,
              'p_shares': split == 'equal' ? [] : allocations,
              'p_reason': reason.text.trim(),
            }),
          ),
        );
      }
      final result = await widget.gateway.call(
        save
            ? 'save_owner_service_commission'
            : 'preview_owner_service_commission',
        save
            ? pending!
            : {
                'p_branch': data!['branch'],
                'p_item': item,
                'p_base': num.parse(base.text),
                'p_staff': crew.toList()..sort(),
              },
      );
      if (!mounted || generation != epoch) return;
      if (save) {
        if (result['policy_id'] is! String || result['version'] is! num) {
          throw StateError('Invalid receipt');
        }
        pending = null;
      } else {
        preview = result;
      }
    } catch (e) {
      if (mounted && generation == epoch) {
        if (e is FormatException ||
            e is PostgrestException &&
                RegExp(r'^(22|23|40|42|55|P0)[0-9A-Z]{3}$')
                    .hasMatch(e.code ?? '')) {
          pending = null;
        }
        setState(
          () => error = t(
            'تعذر تنفيذ الطلب. راجع القيم والصلاحيات؛ الطلب غير المؤكد يعاد بنفس الرقم.',
            'Request failed. Check values and permissions; uncertain requests retry with the same ID.',
          ),
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (save &&
        pending == null &&
        error == null &&
        mounted &&
        generation == epoch) {
      await load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('سياسة عمولات الخدمات', 'Service commission policy')),
    ),
    body: invalid
        ? Center(child: Text(t('أعد تسجيل الدخول.', 'Sign in again.')))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
              Text(
                t(
                  'للمستقبل فقط؛ أساس العمولة قبل الخصم دون الضريبة. تُجمّد عند بدء الخدمة وتُستحق بعد الإكمال والجودة.',
                  'Future only; commission base excludes tax and precedes discounts. Frozen at start, earned after completion and quality approval.',
                ),
              ),
              if (data != null) ...[
                DropdownButtonFormField<String>(
                  initialValue: item,
                  isExpanded: true,
                  items: [
                    for (final x in rows('items'))
                      DropdownMenuItem(
                        value: x['item_id'] as String,
                        child: Text(
                          '${ar ? x['name'] : x['name_en'] ?? x['name']}',
                        ),
                      ),
                  ],
                  onChanged: editable ? (v) => setState(() => choose(v)) : null,
                  decoration: InputDecoration(
                    labelText: t('الخدمة', 'Service'),
                  ),
                ),
                SwitchListTile(
                  title: Text(
                    t('تفعيل عمولة الخدمة', 'Enable service commission'),
                  ),
                  value: enabled,
                  onChanged: editable
                      ? (v) => setState(() => enabled = v)
                      : null,
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('commission_mode_${item}_$mode'),
                  isExpanded: true,
                  initialValue: mode,
                  items: [
                    DropdownMenuItem(
                      value: 'percentage',
                      child: Text(
                        t('نسبة من أساس الخدمة', 'Percentage of service base'),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'fixed',
                      child: Text(t('مبلغ ثابت بالجنيه', 'Fixed EGP amount')),
                    ),
                  ],
                  onChanged: editable ? (v) => setState(() => mode = v!) : null,
                ),
                TextField(
                  controller: value,
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t(
                      'إجمالي عمولة الخدمة',
                      'Total service commission',
                    ),
                  ),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('commission_split_${item}_$split'),
                  isExpanded: true,
                  initialValue: split,
                  items: [
                    DropdownMenuItem(
                      value: 'equal',
                      child: Text(t('بالتساوي', 'Equal shares')),
                    ),
                    DropdownMenuItem(
                      value: 'configured',
                      child: Text(
                        t(
                          'حصص محددة مجموعها 100%',
                          'Configured shares totaling 100%',
                        ),
                      ),
                    ),
                  ],
                  onChanged: editable
                      ? (v) => setState(() => split = v!)
                      : null,
                ),
                for (final x in rows('staff'))
                  Row(
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          title: Text('${x['name']}'),
                          value: crew.contains(x['staff_id']),
                          onChanged: editable
                              ? (v) => setState(() {
                                  v == true
                                      ? crew.add(x['staff_id'])
                                      : crew.remove(x['staff_id']);
                                })
                              : null,
                        ),
                      ),
                      if (split == 'configured')
                        SizedBox(
                          width: 95,
                          child: TextField(
                            controller: shares[x['staff_id']],
                            enabled: editable,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(suffixText: '%'),
                          ),
                        ),
                    ],
                  ),
                TextField(
                  controller: reason,
                  enabled: editable,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: t(
                      'سبب تغيير السياسة',
                      'Reason for policy change',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: editable && item != null ? () => act(true) : null,
                  child: Text(t('حفظ سياسة مستقبلية', 'Save future policy')),
                ),
                if (pending != null)
                  FilledButton(
                    onPressed: busy ? null : () => act(true),
                    child: Text(t('إعادة نفس الطلب', 'Retry same request')),
                  ),
                TextField(
                  controller: base,
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t(
                      'أساس قبل الخصم دون الضريبة للمعاينة فقط',
                      'Pretax, pre-discount base for preview only',
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: editable && item != null ? () => act(false) : null,
                  child: Text(
                    t('معاينة السياسة المحفوظة', 'Preview saved policy'),
                  ),
                ),
                if (preview != null)
                  Text(
                    preview!['configured'] == true
                        ? '${t('إجمالي العمولة', 'Total commission')}: ${preview!['total_commission']} EGP'
                        : t(
                            'لم تحفظ سياسة لهذه الخدمة.',
                            'No policy saved for this service.',
                          ),
                  ),
                for (final x in List<Map<String, dynamic>>.from(
                  preview?['allocations'] ?? [],
                ))
                  Text(
                    '${rows('staff').where((s) => s['staff_id'] == x['staff_id']).firstOrNull?['name'] ?? '—'}: ${x['amount']} EGP',
                  ),
              ],
            ],
          ),
  );
}
