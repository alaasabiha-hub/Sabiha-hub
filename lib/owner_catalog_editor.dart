import 'owner_pos_layout.dart';
import 'catalog_media.dart';
import 'dropdown_options.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_service_commission.dart';
import 'owner_tax_invoice_settings.dart';
import 'workflow.dart' show newOrderRequestId;

class OwnerCatalogGateway extends ServiceCommissionGateway
    implements OwnerCatalogMedia {
  @override
  Future<String?> uploadImage(String branch, String item) =>
      pickAndUploadCatalogImage(client, branch, item, () => current);
  OwnerCatalogGateway(super.client);
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current ||
        !const {
          'get_owner_catalog_items',
          'save_owner_catalog_item',
          'save_owner_catalog_item_with_vehicle_prices',
          'save_owner_vehicle_class',
          'owner_correct_vehicle_class',
          'get_owner_pos_catalog_layout',
          'save_owner_pos_catalog_layout',
          'attach_owner_catalog_image',
        }.contains(name)) {
      throw StateError('Owner catalogue session unavailable');
    }
    final result = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 25));
    if (!current) throw StateError('Owner session changed');
    final data = Map<String, dynamic>.from(result as Map);
    if (name == 'get_owner_catalog_items') {
      final items = List<Map<String, dynamic>>.from(data['items']);
      await enrichCatalogImages(client, items);
      data['items'] = items;
    }
    if (!current) throw StateError('Owner session changed');
    return data;
  }
}

class OwnerCatalogEditor extends StatefulWidget {
  const OwnerCatalogEditor({super.key, required this.gateway});
  final OwnerTaxGateway gateway;
  @override
  State<OwnerCatalogEditor> createState() => _OwnerCatalogEditorState();
}

class _OwnerCatalogEditorState extends State<OwnerCatalogEditor> {
  Map<String, dynamic>? data, pending, imagePending;
  final items = <Map<String, dynamic>>[];
  String? selected, error;
  String kind = 'service';
  bool enabled = true, published = false, busy = false, invalid = false;
  int epoch = 0;
  final fields = {
    for (final key in [
      'name',
      'name_en',
      'price',
      'duration_minutes',
      'category',
      'image_url',
      'reason',
    ])
      key: TextEditingController(),
  };
  final vehiclePriceFields = <String, TextEditingController>{};
  StreamSubscription<void>? subscription;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool get editable =>
      !busy &&
      !invalid &&
      pending == null &&
      imagePending == null &&
      widget.gateway.current;
  String number(String s) =>
      s.trim().replaceAll('٫', '.').replaceAllMapped(RegExp('[٠-٩۰-۹]'), (m) {
        final c = m[0]!.codeUnitAt(0);
        return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
      });
  Map<String, dynamic>? get row =>
      items.where((x) => x['item_id'] == selected).firstOrNull;
  @override
  void initState() {
    super.initState();
    subscription = widget.gateway.changes.listen((_) {
      epoch++;
      if (mounted) {
        setState(() {
          invalid = true;
          data = null;
          items.clear();
          pending = imagePending = null;
          for (final c in fields.values) {
            c.clear();
          }
        });
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    for (final c in fields.values) {
      c.dispose();
    }
    for (final c in vehiclePriceFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void choose(String? id) {
    selected = id;
    final item = row;
    kind = item?['item_type'] ?? 'service';
    enabled = item?['is_active'] ?? true;
    published = item?['is_public'] ?? false;
    for (final key in fields.keys) {
      fields[key]!.text =
          '${item?[key] ?? (key == 'duration_minutes' ? 60 : '')}';
    }
    fields['reason']!.clear();
    final classes = List<Map<String, dynamic>>.from(
      data?['vehicle_classes'] ?? const [],
    ).where((x) => x['is_active'] == true).toList();
    final prices = Map<String, dynamic>.from(
      item?['vehicle_prices'] ?? const {},
    );
    final legacyPrice = kind == 'service' ? (item?['price'] ?? '') : '';
    for (final vehicleClass in classes) {
      final code = vehicleClass['class_code'] as String;
      vehiclePriceFields.putIfAbsent(code, TextEditingController.new);
      vehiclePriceFields[code]!.text = '${prices[code] ?? legacyPrice}';
    }
  }

  Future<void> load({bool more = false}) async {
    final generation = epoch;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.call('get_owner_catalog_items', {
        'p_branch': data?['branch'],
        'p_after': more && items.isNotEmpty ? items.last['item_id'] : null,
      });
      if (!mounted || generation != epoch) return;
      setState(() {
        data = result;
        if (!more) items.clear();
        final incoming = uniqueDropdownRows(
          List<Map<String, dynamic>>.from(result['items']),
          'item_id',
        );
        final known = items
            .map((x) => x['item_id'])
            .whereType<String>()
            .toSet();
        items.addAll(incoming.where((x) => !known.contains(x['item_id'])));
        selected = validDropdownId(selected, items, 'item_id');
        if (!more) choose(selected);
        error = null;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(
          () => error = t(
            'تعذر تحميل الكتالوج المسموح.',
            'Unable to load the authorized catalogue.',
          ),
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> uploadImage() async {
    if (busy ||
        !widget.gateway.current ||
        selected == null ||
        widget.gateway is! OwnerCatalogMedia) {
      return;
    }
    final generation = epoch;
    setState(() => busy = true);
    try {
      if (imagePending == null) {
        final path = await (widget.gateway as OwnerCatalogMedia).uploadImage(
          data!['branch'],
          selected!,
        );
        if (!mounted || generation != epoch || path == null) return;
        imagePending = {
          'p_request': newOrderRequestId(),
          'p_branch': data!['branch'],
          'p_item': selected,
          'p_expected_version': row?['image_version'] ?? 0,
          'p_path': path,
          'p_reason': fields['reason']!.text.trim(),
        };
      }
      await widget.gateway.call('attach_owner_catalog_image', imagePending!);
      if (!mounted || generation != epoch) return;
      imagePending = null;
      error = null;
    } catch (e) {
      if (mounted && generation == epoch) {
        if (e is FormatException ||
            e is PostgrestException &&
                RegExp(r'^(22|23|40|42|55|P0)[0-9A-Z]{3}$')
                    .hasMatch(e.code ?? '')) {
          imagePending = null;
        }
        error = t(
          'تعذر رفع الصورة أو ربطها. استخدم JPG/PNG حتى 8 ميجابايت، واكتب سبب التعديل. الطلب غير المؤكد يحتفظ برقمه.',
          'Unable to upload or attach image. Use JPG/PNG up to 8 MB and enter a reason. Uncertain requests retain their ID.',
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (mounted &&
        generation == epoch &&
        imagePending == null &&
        error == null) {
      await load();
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
            'p_branch': data!['branch'],
            'p_item': selected,
            'p_expected_revision': row?['revision'],
            'p_spec': {
              'item_type': kind,
              'name': fields['name']!.text.trim(),
              'name_en': fields['name_en']!.text.trim(),
              'price': num.parse(number(fields['price']!.text)),
              'duration_minutes': int.parse(
                number(fields['duration_minutes']!.text),
              ),
              'category': fields['category']!.text.trim().isEmpty
                  ? null
                  : fields['category']!.text.trim(),
              'image_url': fields['image_url']!.text.trim().isEmpty
                  ? null
                  : fields['image_url']!.text.trim(),
              'is_active': enabled,
              'is_public': published,
            },
            'p_reason': fields['reason']!.text.trim(),
          }),
        ),
      );
      final payload = pending!;
      final prices = kind == 'service'
          ? data!['vehicle_classes']
                .where((x) => x['is_active'] == true)
                .map<Map<String, dynamic>>(
                  (x) => {
                    'class_code': x['class_code'],
                    'price': num.parse(
                      number(vehiclePriceFields[x['class_code']]!.text),
                    ),
                  },
                )
                .toList()
          : <Map<String, dynamic>>[];
      final request = <String, dynamic>{...payload, 'p_vehicle_prices': prices};
      pending = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(request)) as Map,
      );
      final result = await widget.gateway.call(
        'save_owner_catalog_item_with_vehicle_prices',
        pending!,
      );
      if (!mounted || generation != epoch) return;
      if (result['item_id'] is! String || result['revision'] is! String) {
        throw StateError('Invalid catalogue receipt');
      }
      selected = result['item_id'];
      pending = null;
      error = null;
    } catch (e) {
      if (mounted && generation == epoch) {
        if (e is FormatException ||
            e is PostgrestException &&
                RegExp(r'^(22|23|40|42|55|P0)[0-9A-Z]{3}$')
                    .hasMatch(e.code ?? '')) {
          pending = null;
        }
        error = t(
          'تعذر الحفظ. راجع البيانات أو أعد تحميل الإصدار الحالي؛ الطلب غير المؤكد يحتفظ برقمه.',
          'Unable to save. Check values or reload the current revision; uncertain requests retain their ID.',
        );
      }
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (mounted && generation == epoch && pending == null && error == null) {
      await load();
    }
  }

  Future<void> addVehicleClass() async {
    if (!editable || !widget.gateway.current) return;
    final code = TextEditingController();
    final arabic = TextEditingController();
    final english = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('إضافة فئة سيارة', 'Add vehicle class')),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: code,
                decoration: InputDecoration(
                  labelText: t(
                    'رمز ثابت (مثل pickup)',
                    'Stable code (e.g. pickup)',
                  ),
                ),
              ),
              TextField(
                controller: arabic,
                decoration: InputDecoration(
                  labelText: t('الاسم بالعربية', 'Arabic name'),
                ),
              ),
              TextField(
                controller: english,
                decoration: InputDecoration(
                  labelText: t('الاسم بالإنجليزية', 'English name'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t('متابعة', 'Continue')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !widget.gateway.current) {
      code.dispose();
      arabic.dispose();
      english.dispose();
      return;
    }
    final id = newOrderRequestId();
    final generation = epoch;
    setState(() => busy = true);
    try {
      await widget.gateway.call('save_owner_vehicle_class', {
        'p_request': id,
        'p_code': code.text.trim().toLowerCase(),
        'p_name_ar': arabic.text.trim(),
        'p_name_en': english.text.trim(),
        'p_active': true,
        'p_reason': fields['reason']!.text.trim(),
      });
      if (mounted && generation == epoch) error = null;
    } catch (_) {
      if (mounted && generation == epoch) {
        error = t(
          'تعذر حفظ الفئة. اكتب سبب التعديل أولًا وتأكد من الرمز والأسماء.',
          'Could not save the class. Enter an audit reason and check the code and names.',
        );
      }
    } finally {
      code.dispose();
      arabic.dispose();
      english.dispose();
      if (mounted && generation == epoch) setState(() => busy = false);
    }
    if (mounted && generation == epoch && error == null) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        t('الكتالوج الموحد والأسعار', 'Unified catalogue and prices'),
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
                  'تعديلات الكتالوج تؤثر في المبيعات الجديدة فقط. المخزون يُدار من حركات المخزون، والفواتير الصادرة لا تتغير.',
                  'Catalogue edits affect new sales only. Stock is managed through inventory movements; issued invoices stay unchanged.',
                ),
              ),
              if (data != null) ...[
                OutlinedButton(
                  onPressed: editable
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => OwnerPosLayoutEditor(
                              gateway: widget.gateway,
                              branch: data!['branch'] as String,
                            ),
                          ),
                        )
                      : null,
                  child: Text(
                    t(
                      'تصنيفات الكاشير وترتيب الأزرار',
                      'Cashier categories and button order',
                    ),
                  ),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('owner_catalog_$selected'),
                  initialValue: selected ?? '',
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        t('إضافة خدمة أو منتج', 'Add service or product'),
                      ),
                    ),
                    for (final x in items)
                      DropdownMenuItem(
                        value: x['item_id'] as String,
                        child: Text(
                          '${ar ? x['name'] : x['name_en'] ?? x['name']}',
                        ),
                      ),
                  ],
                  onChanged: editable
                      ? (v) => setState(() => choose(v == '' ? null : v))
                      : null,
                ),
                if (data!['has_more'] == true)
                  TextButton(
                    onPressed: editable ? () => load(more: true) : null,
                    child: Text(t('تحميل المزيد', 'Load more')),
                  ),
                DropdownButtonFormField<String>(
                  key: ValueKey('owner_kind_${selected}_$kind'),
                  initialValue: kind,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: 'service',
                      child: Text(t('خدمة', 'Service')),
                    ),
                    DropdownMenuItem(
                      value: 'product',
                      child: Text(t('منتج', 'Product')),
                    ),
                  ],
                  onChanged: editable && selected == null
                      ? (v) => setState(() => kind = v!)
                      : null,
                ),
                for (final field in [
                  ('name', 'الاسم بالعربية', 'Arabic name'),
                  ('name_en', 'الاسم بالإنجليزية', 'English name'),
                  ('price', 'السعر بالجنيه المصري', 'Price in EGP'),
                  ('duration_minutes', 'المدة بالدقائق', 'Duration in minutes'),
                  ('category', 'وصف التصنيف', 'Category description'),
                  (
                    'image_url',
                    'رابط صورة الكتالوج HTTPS',
                    'Catalogue image HTTPS URL',
                  ),
                  ('reason', 'سبب التعديل', 'Reason for change'),
                ])
                  TextField(
                    key: ValueKey('owner_catalog_${field.$1}'),
                    controller: fields[field.$1],
                    onChanged: (_) => setState(() {}),
                    enabled: editable,
                    keyboardType:
                        const ['price', 'duration_minutes'].contains(field.$1)
                        ? TextInputType.number
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: t(field.$2, field.$3),
                    ),
                  ),
                if (kind == 'service') ...[
                  const SizedBox(height: 12),
                  Text(
                    t(
                      'أسعار الخدمة حسب نوع السيارة (ج.م)',
                      'Service prices by vehicle class (EGP)',
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  OutlinedButton.icon(
                    onPressed: editable ? addVehicleClass : null,
                    icon: const Icon(Icons.add),
                    label: Text(
                      t(
                        'إضافة فئة من إعدادات المالك',
                        'Add a class in owner settings',
                      ),
                    ),
                  ),
                  Text(
                    t(
                      'السعر القديم يُعرض كبداية للفئات الجديدة فقط. راجع كل سعر قبل الحفظ؛ لا يوجد رجوع تلقائي للسعر الموحد عند غياب سعر فئة.',
                      'The legacy price is shown as an initial value for each class. Review every rate before saving; missing class prices never fall back silently.',
                    ),
                  ),
                  for (final vehicleClass in List<Map<String, dynamic>>.from(
                    data!['vehicle_classes'] ?? const [],
                  ).where((x) => x['is_active'] == true))
                    TextField(
                      key: ValueKey(
                        'owner_vehicle_price_${vehicleClass['class_code']}',
                      ),
                      controller: vehiclePriceFields.putIfAbsent(
                        vehicleClass['class_code'] as String,
                        TextEditingController.new,
                      ),
                      enabled: editable,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText:
                            '${ar ? vehicleClass['name_ar'] : vehicleClass['name_en']} · EGP',
                      ),
                    ),
                ],
                if (row?['image_display_url'] is String)
                  Image.network(
                    row!['image_display_url'],
                    height: 160,
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, stack) =>
                        const Icon(Icons.image_not_supported_outlined),
                  ),
                if (widget.gateway is OwnerCatalogMedia) ...[
                  Text(
                    t(
                      'صور JPG/PNG حتى 8 ميجابايت؛ تُصغّر وتُنقّى قبل الرفع. احفظ الخدمة أو المنتج أولًا. الصورة تتغير فور الربط دون تعديل الأسعار.',
                      'JPG/PNG up to 8 MB; resized and re-encoded before upload. Save the item first. Attaching updates the image without changing prices.',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        selected != null &&
                            !busy &&
                            !invalid &&
                            pending == null &&
                            fields['reason']!.text.trim().length >= 5
                        ? uploadImage
                        : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      imagePending != null
                          ? t(
                              'إعادة ربط نفس الصورة',
                              'Retry same image attachment',
                            )
                          : t(
                              'رفع صورة الخدمة أو المنتج',
                              'Upload service or product image',
                            ),
                    ),
                  ),
                ],
                SwitchListTile(
                  title: Text(t('نشط في الكاشير', 'Active in cashier')),
                  value: enabled,
                  onChanged: editable
                      ? (v) => setState(() => enabled = v)
                      : null,
                ),
                SwitchListTile(
                  title: Text(t('منشور للعملاء', 'Published to customers')),
                  value: published,
                  onChanged: editable
                      ? (v) => setState(() => published = v)
                      : null,
                ),
                FilledButton(
                  key: const ValueKey('owner_catalog_save'),
                  onPressed: editable ? save : null,
                  child: Text(t('حفظ الكتالوج', 'Save catalogue')),
                ),
                if (pending != null)
                  FilledButton(
                    onPressed: busy ? null : save,
                    child: Text(t('إعادة نفس الطلب', 'Retry same request')),
                  ),
                OutlinedButton(
                  onPressed: editable ? () => load() : null,
                  child: Text(t('إعادة تحميل', 'Reload')),
                ),
              ],
            ],
          ),
  );
}
