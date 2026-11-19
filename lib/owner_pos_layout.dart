import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_tax_invoice_settings.dart';
import 'workflow.dart' show newOrderRequestId;

class OwnerPosLayoutEditor extends StatefulWidget {
  const OwnerPosLayoutEditor({
    super.key,
    required this.gateway,
    required this.branch,
  });
  final OwnerTaxGateway gateway;
  final String branch;
  @override
  State<OwnerPosLayoutEditor> createState() => _OwnerPosLayoutEditorState();
}

class _OwnerPosLayoutEditorState extends State<OwnerPosLayoutEditor> {
  final categories = <Map<String, dynamic>>[], items = <Map<String, dynamic>>[];
  final assignments = <String, Map<String, dynamic>>{};
  final reason = TextEditingController();
  Map<String, dynamic>? data, pending;
  String? error;
  bool busy = false, invalid = false;
  int epoch = 0;
  StreamSubscription<void>? subscription;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool get editable =>
      !busy && !invalid && pending == null && widget.gateway.current;
  int order(dynamic value) => int.parse(
    '$value'.replaceAllMapped(RegExp('[٠-٩۰-۹]'), (m) {
      final c = m[0]!.codeUnitAt(0);
      return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
    }),
  );
  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.changes.listen((_) {
      epoch++;
      if (mounted) {
        setState(() {
          invalid = true;
          categories.clear();
          items.clear();
          assignments.clear();
          data = null;
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
    reason.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    final generation = epoch;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.call('get_owner_pos_catalog_layout', {
        'p_branch': widget.branch,
        'p_after': more && items.isNotEmpty ? items.last['item_id'] : null,
      });
      if (!mounted || generation != epoch) return;
      if (more && data?['version'] != result['version']) {
        throw StateError('Layout changed');
      }
      setState(() {
        if (!more) {
          categories.clear();
          items.clear();
          assignments.clear();
          final spec = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(result['spec'])) as Map,
          );
          categories.addAll(
            List<Map<String, dynamic>>.from(spec['categories']),
          );
          for (final x in spec['items']) {
            assignments[x['item_id']] = Map<String, dynamic>.from(x);
          }
        }
        data = result;
        items.addAll(List<Map<String, dynamic>>.from(result['items']));
        for (final x in items) {
          assignments.putIfAbsent(
            x['item_id'],
            () => {
              'item_id': x['item_id'],
              'category_id': null,
              'sort_order': 0,
              'featured': false,
            },
          );
        }
        error = null;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        error = t(
          'تعذر تحميل إصدار الترتيب.',
          'Unable to load the layout revision.',
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!widget.gateway.current || busy || invalid) return;
    final generation = epoch;
    setState(() => busy = true);
    try {
      pending ??= Map<String, dynamic>.from(
        jsonDecode(
          jsonEncode({
            'p_request': newOrderRequestId(),
            'p_branch': widget.branch,
            'p_expected_version': data!['version'],
            'p_spec': {
              'categories': [
                for (final c in categories)
                  {...c, 'sort_order': order(c['sort_order'])},
              ],
              'items': [
                for (final x in assignments.values)
                  {...x, 'sort_order': order(x['sort_order'])},
              ],
            },
            'p_reason': reason.text.trim(),
          }),
        ),
      );
      final result = await widget.gateway.call(
        'save_owner_pos_catalog_layout',
        pending!,
      );
      if (!mounted || generation != epoch) return;
      if (result['layout_id'] is! String || result['version'] is! num) {
        throw StateError('Invalid layout receipt');
      }
      pending = null;
      error = null;
      reason.clear();
    } catch (e) {
      if (mounted && generation == epoch) {
        if (e is FormatException ||
            e is PostgrestException &&
                RegExp(r'^(22|23|40|42|55|P0)[0-9A-Z]{3}$')
                    .hasMatch(e.code ?? '')) {
          pending = null;
        }
        error = t(
          'تعذر حفظ التصنيفات والترتيب. راجع الحقول والإصدار.',
          'Unable to save categories and ordering. Review fields and revision.',
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (mounted && generation == epoch && pending == null && error == null) {
      await load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        t(
          'تصنيفات الكاشير وترتيب الأزرار',
          'Cashier categories and button order',
        ),
      ),
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
                  'الترتيب الأصغر يظهر أولًا. إيقاف التصنيف لا يحذف بنوده أو فواتيره، وتظل البنود ضمن الكل.',
                  'Lower order appears first. Disabling a category retains its items and invoices; items stay under All.',
                ),
              ),
              if (data != null) ...[
                OutlinedButton(
                  onPressed: editable
                      ? () => setState(
                          () => categories.add({
                            'category_id': newOrderRequestId(),
                            'name_ar': '',
                            'name_en': '',
                            'sort_order': categories.length,
                            'enabled': true,
                          }),
                        )
                      : null,
                  child: Text(t('إضافة تصنيف', 'Add category')),
                ),
                for (final c in categories)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          TextFormField(
                            key: ValueKey(
                              'cat_ar_${c['category_id']}_${data!['version']}',
                            ),
                            initialValue: c['name_ar'],
                            enabled: editable,
                            decoration: InputDecoration(
                              labelText: t(
                                'اسم التصنيف بالعربية',
                                'Arabic category name',
                              ),
                            ),
                            onChanged: (v) => setState(() => c['name_ar'] = v),
                          ),
                          TextFormField(
                            key: ValueKey(
                              'cat_en_${c['category_id']}_${data!['version']}',
                            ),
                            initialValue: c['name_en'],
                            enabled: editable,
                            decoration: InputDecoration(
                              labelText: t(
                                'اسم التصنيف بالإنجليزية',
                                'English category name',
                              ),
                            ),
                            onChanged: (v) => setState(() => c['name_en'] = v),
                          ),
                          TextFormField(
                            key: ValueKey(
                              'cat_order_${c['category_id']}_${data!['version']}',
                            ),
                            initialValue: '${c['sort_order']}',
                            enabled: editable,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('ترتيب التصنيف', 'Category order'),
                            ),
                            onChanged: (v) => c['sort_order'] = v,
                          ),
                          SwitchListTile(
                            title: Text(t('التصنيف نشط', 'Category active')),
                            value: c['enabled'] == true,
                            onChanged: editable
                                ? (v) => setState(() => c['enabled'] = v)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final item in items)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${ar ? item['name'] : item['name_en'] ?? item['name']}',
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'item_category_${item['item_id']}_${data!['version']}',
                            ),
                            initialValue:
                                assignments[item['item_id']]!['category_id'] ??
                                '',
                            isExpanded: true,
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(t('بدون تصنيف', 'Uncategorized')),
                              ),
                              for (final c in categories)
                                DropdownMenuItem(
                                  value: c['category_id'] as String,
                                  child: Text(
                                    '${ar ? c['name_ar'] : c['name_en']}',
                                  ),
                                ),
                            ],
                            onChanged: editable
                                ? (v) => setState(
                                    () =>
                                        assignments[item['item_id']]!['category_id'] =
                                            v == '' ? null : v,
                                  )
                                : null,
                          ),
                          TextFormField(
                            key: ValueKey(
                              'item_order_${item['item_id']}_${data!['version']}',
                            ),
                            initialValue:
                                '${assignments[item['item_id']]!['sort_order']}',
                            enabled: editable,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('ترتيب الزر', 'Button order'),
                            ),
                            onChanged: (v) =>
                                assignments[item['item_id']]!['sort_order'] = v,
                          ),
                          CheckboxListTile(
                            title: Text(t('ضمن المفضلة', 'Show in favorites')),
                            value:
                                assignments[item['item_id']]!['featured'] ==
                                true,
                            onChanged: editable
                                ? (v) => setState(
                                    () =>
                                        assignments[item['item_id']]!['featured'] =
                                            v == true,
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (data!['has_more'] == true)
                  TextButton(
                    onPressed: editable ? () => load(more: true) : null,
                    child: Text(t('تحميل المزيد', 'Load more')),
                  ),
                TextField(
                  controller: reason,
                  enabled: editable,
                  decoration: InputDecoration(
                    labelText: t(
                      'سبب تغيير العرض',
                      'Reason for display change',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: editable ? save : null,
                  child: Text(
                    t('حفظ التصنيفات والترتيب', 'Save categories and order'),
                  ),
                ),
                if (pending != null)
                  FilledButton(
                    onPressed: busy ? null : save,
                    child: Text(t('إعادة نفس الطلب', 'Retry same request')),
                  ),
              ],
            ],
          ),
  );
}
