import 'app_config.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

class BranchSelection {
  static String? current;
}

String branchName(Map<String, dynamic> b, BuildContext c) =>
    b[Localizations.localeOf(c).languageCode == 'en' ? 'name_en' : 'name_ar']
        ?.toString() ??
    '';

class BranchSettingsScreen extends StatefulWidget {
  final SupabaseClient client;
  const BranchSettingsScreen({super.key, required this.client});
  @override
  State<BranchSettingsScreen> createState() => _BranchSettingsScreenState();
}

class _BranchSettingsScreenState extends State<BranchSettingsScreen> {
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  String roleName(Object? role) => switch (role) {
    'owner' => t('المالك', 'Owner'),
    'manager' => t('المدير', 'Manager'),
    'cashier' => t('الكاشير', 'Cashier'),
    'employee' => t('الموظف', 'Employee'),
    _ => t('صلاحية أخرى', 'Other role'),
  };

  List<Map<String, dynamic>> branches = [],
      hours = [],
      exceptions = [],
      resources = [],
      catalog = [],
      staff = [],
      access = [];
  String? selected, error;
  bool busy = false;
  final nameAr = TextEditingController(),
      nameEn = TextEditingController(),
      addressAr = TextEditingController(),
      addressEn = TextEditingController(),
      maps = TextEditingController(),
      phone = TextEditingController(),
      minimum = TextEditingController();
  bool active = true,
      closed = false,
      delivery = false,
      inspectionRequired = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [
      nameAr,
      nameEn,
      addressAr,
      addressEn,
      maps,
      phone,
      minimum,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final b = await widget.client
          .from('business_branches')
          .select()
          .order('name_ar');
      branches = List<Map<String, dynamic>>.from(b);
      selected ??= branches.firstWhere(
        (b) => b['is_default'] == true,
        orElse: () => branches.first,
      )['branch_id'];
      final current = branches.firstWhere((b) => b['branch_id'] == selected);
      nameAr.text = current['name_ar'];
      nameEn.text = current['name_en'];
      addressAr.text = current['address_ar'];
      addressEn.text = current['address_en'];
      maps.text = current['maps_url'];
      phone.text = current['whatsapp_phone'];
      minimum.text = current['minimum_subtotal'].toString();
      active = current['is_active'];
      closed = current['temporarily_closed'];
      delivery = current['delivery_enabled'];
      inspectionRequired = current['inspection_required'];
      hours = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branch_hours')
            .select()
            .eq('branch_id', selected!)
            .order('weekday'),
      );
      exceptions = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branch_exceptions')
            .select()
            .eq('branch_id', selected!)
            .order('exception_date'),
      );
      resources = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_branch_resources')
            .select()
            .eq('branch_id', selected!),
      );
      catalog = List<Map<String, dynamic>>.from(
        await widget.client
            .from('business_catalog_items')
            .select(
              'item_id,name,item_type,price,stock_quantity,duration_minutes,resource_key,catalog_key',
            )
            .eq('branch_id', selected!)
            .order('name'),
      );
      staff = List<Map<String, dynamic>>.from(
        await widget.client
            .from('staff_profiles')
            .select('user_id,full_name,role')
            .eq('is_active', true),
      );
      access = List<Map<String, dynamic>>.from(
        await widget.client
            .from('staff_branch_access')
            .select()
            .eq('branch_id', selected!),
      );
      if (mounted) setState(() => error = null);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'load');
      }
    }
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() => busy = true);
    try {
      await operation();
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'save');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<List<String>?> prompt(
    String title,
    List<String> labels,
    List<String> initial,
  ) async {
    final controls = initial
        .map((s) => TextEditingController(text: s))
        .toList();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                labels.length,
                (i) => TextField(
                  controller: controls[i],
                  decoration: InputDecoration(labelText: labels[i]),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('حفظ', 'Save')),
          ),
        ],
      ),
    );
    final values = controls.map((c) => c.text.trim()).toList();
    for (final c in controls) {
      c.dispose();
    }
    return result == true ? values : null;
  }

  Future<String?> chooseOtherBranch(String title) async {
    return showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title),
        children: branches
            .where((b) => b['branch_id'] != selected)
            .map(
              (b) => SimpleDialogOption(
                onPressed: () => Navigator.pop(c, b['branch_id']),
                child: Text(branchName(b, context)),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> transferStock() async {
    final products = catalog.where((p) => p['item_type'] == 'product').toList();
    if (products.isEmpty) return;
    final destination = await chooseOtherBranch(
      t('الفرع المستلم', 'Receiving establishment'),
    );
    if (destination == null || !mounted) return;
    String item = products.first['item_id'];
    final quantity = TextEditingController(text: '1'),
        reason = TextEditingController();
    final request = newOrderRequestId();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(
            t(
              'تحويل مخزون بين الفروع',
              'Transfer stock between establishments',
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: item,
                items: products
                    .map(
                      (p) => DropdownMenuItem(
                        value: p['item_id'] as String,
                        child: Text(p['name']),
                      ),
                    )
                    .toList(),
                onChanged: (v) => update(() => item = v!),
              ),
              TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('الكمية', 'Quantity')),
              ),
              TextField(
                controller: reason,
                decoration: InputDecoration(
                  labelText: t('سبب التحويل', 'Transfer reason'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t('تأكيد التحويل', 'Confirm transfer')),
            ),
          ],
        ),
      ),
    );
    final count = int.tryParse(quantity.text), note = reason.text;
    quantity.dispose();
    reason.dispose();
    if (accepted == true) {
      await run(() async {
        final source = products.firstWhere((p) => p['item_id'] == item);
        final target = await widget.client
            .from('business_catalog_items')
            .select('item_id')
            .eq('branch_id', destination)
            .eq('catalog_key', source['catalog_key'])
            .maybeSingle();
        if (target == null) {
          throw StateError('Copy the product catalog to the destination first');
        }
        await widget.client.rpc(
          'transfer_branch_stock',
          params: {
            'p_request': request,
            'p_from': item,
            'p_to': target['item_id'],
            'p_quantity': count,
            'p_reason': note,
          },
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('إعدادات المركز والفروع', 'Establishment settings')),
      actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null)
          Text(
            error == 'load'
                ? t(
                    'تعذر تحميل إعدادات الفروع.',
                    'Could not load establishment settings.',
                  )
                : t(
                    'تعذر الحفظ. تحقق من القيم والصلاحية.',
                    'Could not save. Check the values and permissions.',
                  ),
            style: const TextStyle(color: Colors.red),
          ),
        if (busy) const LinearProgressIndicator(),
        if (AppConfig.multiBranchEnabled && branches.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(selected),
            initialValue: selected,
            items: branches
                .map(
                  (b) => DropdownMenuItem(
                    value: b['branch_id'] as String,
                    child: Text(branchName(b, context)),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (v) {
                    setState(() => selected = v);
                    load();
                  },
          ),
        if (AppConfig.multiBranchEnabled)
          OutlinedButton(
            onPressed: busy
                ? null
                : () async {
                    final v = await prompt(
                      t('فرع جديد', 'New establishment'),
                      [
                        t('الاسم بالعربية', 'Name in Arabic'),
                        t('الاسم بالإنجليزية', 'Name in English'),
                      ],
                      ['', ''],
                    );
                    if (v != null) {
                      await run(() async {
                        final b = await widget.client
                            .from('business_branches')
                            .insert({'name_ar': v[0], 'name_en': v[1]})
                            .select('branch_id')
                            .single();
                        selected = b['branch_id'];
                      });
                    }
                  },
            child: Text(t('إضافة فرع', 'Add establishment')),
          ),
        TextField(
          controller: nameAr,
          decoration: InputDecoration(
            labelText: t('الاسم بالعربية', 'Name in Arabic'),
          ),
        ),
        TextField(
          controller: nameEn,
          decoration: InputDecoration(
            labelText: t('الاسم بالإنجليزية', 'Name in English'),
          ),
        ),
        TextField(
          controller: addressAr,
          decoration: InputDecoration(
            labelText: t('العنوان بالعربية', 'Address in Arabic'),
          ),
        ),
        TextField(
          controller: addressEn,
          decoration: InputDecoration(
            labelText: t('العنوان بالإنجليزية', 'Address in English'),
          ),
        ),
        TextField(
          controller: maps,
          decoration: InputDecoration(
            labelText: t(
              'رابط Google Maps الرسمي HTTPS',
              'Official Google Maps HTTPS link',
            ),
          ),
        ),
        TextField(
          controller: phone,
          decoration: InputDecoration(
            labelText: t(
              'واتساب الفرع الدولي (فارغ لاستخدام الرئيسي)',
              'International WhatsApp number (empty to use the main number)',
            ),
          ),
        ),
        SwitchListTile(
          value: active,
          title: Text(t('فرع نشط', 'Active establishment')),
          onChanged: (v) => setState(() => active = v),
        ),
        SwitchListTile(
          value: closed,
          title: Text(t('إغلاق مؤقت', 'Temporarily closed')),
          onChanged: (v) => setState(() => closed = v),
        ),
        SwitchListTile(
          value: delivery,
          title: Text(t('توصيل منتجات هذا الفرع', 'Product delivery enabled')),
          onChanged: (v) => setState(() => delivery = v),
        ),
        TextField(
          controller: minimum,
          decoration: InputDecoration(
            labelText: t(
              'الحد الأدنى للمنتجات قبل الخصم EGP',
              'Minimum product subtotal before discounts (EGP)',
            ),
          ),
        ),
        FilledButton(
          onPressed: busy || selected == null
              ? null
              : () => run(() async {
                  await widget.client
                      .from('business_branches')
                      .update({
                        'name_ar': nameAr.text.trim(),
                        'name_en': nameEn.text.trim(),
                        'address_ar': addressAr.text.trim(),
                        'address_en': addressEn.text.trim(),
                        'maps_url': maps.text.trim(),
                        'whatsapp_phone': phone.text.trim(),
                        'is_active': active,
                        'temporarily_closed': closed,
                        'delivery_enabled': delivery,
                        'inspection_required': inspectionRequired,
                        'minimum_subtotal': double.parse(minimum.text),
                      })
                      .eq('branch_id', selected!);
                }),
          child: Text(t('حفظ بيانات الفرع', 'Save establishment details')),
        ),
        SwitchListTile(
          value: inspectionRequired,
          title: Text(
            t(
              'اشتراط فحص معتمد قبل وبعد لإكمال الخدمة',
              'Require approved before/after inspection to complete service',
            ),
          ),
          onChanged: (v) => setState(() => inspectionRequired = v),
        ),
        const Divider(),
        Text(t('ساعات العمل بتوقيت مصر', 'Business hours in Egypt time')),
        ...hours.map(
          (h) => ListTile(
            title: Text(
              [
                t('الأحد', 'Sunday'),
                t('الاثنين', 'Monday'),
                t('الثلاثاء', 'Tuesday'),
                t('الأربعاء', 'Wednesday'),
                t('الخميس', 'Thursday'),
                t('الجمعة', 'Friday'),
                t('السبت', 'Saturday'),
              ][h['weekday']],
            ),
            subtitle: Text(
              h['is_open']
                  ? '${h['opens_at']} — ${h['closes_at']}'
                  : t('مغلق', 'Closed'),
            ),
            trailing: Switch(
              value: h['is_open'],
              onChanged: busy
                  ? null
                  : (v) => run(() async {
                      await widget.client
                          .from('business_branch_hours')
                          .update({'is_open': v})
                          .eq('branch_id', selected!)
                          .eq('weekday', h['weekday']);
                    }),
            ),
            onTap: () async {
              final v = await prompt(
                t('ساعات العمل', 'Business hours'),
                [
                  t('فتح HH:MM', 'Opening HH:MM'),
                  t('إغلاق HH:MM', 'Closing HH:MM'),
                ],
                [
                  h['opens_at'].toString().substring(0, 5),
                  h['closes_at'].toString().substring(0, 5),
                ],
              );
              if (v != null) {
                await run(() async {
                  await widget.client
                      .from('business_branch_hours')
                      .update({'opens_at': v[0], 'closes_at': v[1]})
                      .eq('branch_id', selected!)
                      .eq('weekday', h['weekday']);
                });
              }
            },
          ),
        ),
        ...exceptions.map(
          (e) => ListTile(
            title: Text(e['exception_date']),
            subtitle: Text(
              '${e['reason']} · ${e['is_closed'] ? t('إجازة', 'Closed day') : '${e['opens_at']} — ${e['closes_at']}'}',
            ),
            trailing: IconButton(
              tooltip: t('إزالة الاستثناء فقط', 'Remove this exception only'),
              icon: const Icon(Icons.undo),
              onPressed: busy
                  ? null
                  : () => run(() async {
                      await widget.client
                          .from('business_branch_exceptions')
                          .delete()
                          .eq('branch_id', selected!)
                          .eq('exception_date', e['exception_date']);
                    }),
            ),
          ),
        ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () async {
                  final v = await prompt(
                    t(
                      'إجازة أو موعد استثنائي',
                      'Closed day or exceptional hours',
                    ),
                    [
                      t('التاريخ YYYY-MM-DD', 'Date YYYY-MM-DD'),
                      t('سبب الاستثناء', 'Exception reason'),
                      t(
                        'وقت الفتح HH:MM (فارغ لإجازة)',
                        'Opening HH:MM (empty for a closed day)',
                      ),
                      t('وقت الإغلاق HH:MM', 'Closing HH:MM'),
                    ],
                    ['', '', '', ''],
                  );
                  if (v != null) {
                    await run(() async {
                      await widget.client
                          .from('business_branch_exceptions')
                          .upsert({
                            'branch_id': selected,
                            'exception_date': v[0],
                            'reason': v[1],
                            'is_closed': v[2].isEmpty,
                            'opens_at': v[2].isEmpty ? null : v[2],
                            'closes_at': v[2].isEmpty ? null : v[3],
                          }, onConflict: 'branch_id,exception_date');
                    });
                  }
                },
          child: Text(
            t(
              'إضافة إجازة أو ساعات استثنائية',
              'Add a closed day or exceptional hours',
            ),
          ),
        ),
        const Divider(),
        Text(t('الموارد والطاقة الاستيعابية', 'Resources and capacity')),
        ...resources.map(
          (r) => ListTile(
            title: Text('${r['resource_key']} · ${r['capacity']}'),
            onTap: () async {
              final v = await prompt(
                t('عدد المواقع المتاحة', 'Available service bays'),
                [t('عدد الموارد', 'Resource count')],
                [r['capacity'].toString()],
              );
              if (v != null) {
                await run(() async {
                  await widget.client
                      .from('business_branch_resources')
                      .update({'capacity': int.parse(v[0])})
                      .eq('branch_id', selected!)
                      .eq('resource_key', r['resource_key']);
                });
              }
            },
          ),
        ),
        const Divider(),
        Text(t('أسعار وخدمات ومخزون الفرع', 'Prices, services and stock')),
        ...catalog.map(
          (p) => ListTile(
            title: Text(p['name']),
            subtitle: Text(
              '${p['price']} EGP · ${t('مخزون', 'Stock')} ${p['stock_quantity'] ?? t('غير محدود', 'Unlimited')} · ${p['duration_minutes']} ${t('دقيقة', 'minutes')}',
            ),
            onTap: () async {
              final v = await prompt(
                t('السعر ومدة الخدمة', 'Price and service duration'),
                [
                  t('السعر EGP', 'Price (EGP)'),
                  t('مدة الخدمة بالدقائق', 'Service duration in minutes'),
                ],
                [p['price'].toString(), p['duration_minutes'].toString()],
              );
              if (v != null) {
                await run(() async {
                  await widget.client
                      .from('business_catalog_items')
                      .update({
                        'price': double.parse(v[0]),
                        'duration_minutes': int.parse(v[1]),
                      })
                      .eq('item_id', p['item_id']);
                });
              }
            },
          ),
        ),
        if (branches.length > 1)
          OutlinedButton(
            onPressed: busy
                ? null
                : () async {
                    final source = await chooseOtherBranch(
                      t(
                        'نسخ الأسعار من الفرع',
                        'Copy prices from establishment',
                      ),
                    );
                    if (source != null) {
                      await run(() async {
                        await widget.client.rpc(
                          'copy_branch_prices',
                          params: {'p_from': source, 'p_to': selected},
                        );
                      });
                    }
                  },
            child: Text(
              t(
                'نسخ أسعار فرع آخر دون المخزون',
                'Copy other establishment prices without stock',
              ),
            ),
          ),
        const Divider(),
        if (branches.length > 1)
          OutlinedButton(
            onPressed: busy || !AppConfig.multiBranchEnabled
                ? null
                : transferStock,
            child: Text(
              t(
                'تحويل مخزون إلى فرع آخر',
                'Transfer stock to another establishment',
              ),
            ),
          ),
        Text(
          t(
            'صلاحيات الموظفين في هذا الفرع',
            'Employee permissions at this establishment',
          ),
        ),
        ...staff.map((s) {
          final a = access
              .where((a) => a['user_id'] == s['user_id'])
              .firstOrNull;
          return ListTile(
            title: Text('${s['full_name']} · ${roleName(s['role'])}'),
            subtitle: Row(
              children: [
                Expanded(
                  child: Text(
                    t('السماح بتعديل الأسعار', 'Allow price changes'),
                  ),
                ),
                Checkbox(
                  value: a?['can_edit_prices'] == true,
                  onChanged: busy || a == null
                      ? null
                      : (v) => run(() async {
                          await widget.client
                              .from('staff_branch_access')
                              .update({'can_edit_prices': v})
                              .eq('user_id', s['user_id'])
                              .eq('branch_id', selected!);
                        }),
                ),
              ],
            ),
            trailing: Switch(
              value: a != null,
              onChanged: busy
                  ? null
                  : (v) => run(() async {
                      if (v) {
                        await widget.client.from('staff_branch_access').upsert({
                          'user_id': s['user_id'],
                          'branch_id': selected,
                        }, onConflict: 'user_id,branch_id');
                      } else {
                        await widget.client
                            .from('staff_branch_access')
                            .delete()
                            .eq('user_id', s['user_id'])
                            .eq('branch_id', selected!);
                      }
                    }),
            ),
          );
        }),
      ],
    ),
  );
}
