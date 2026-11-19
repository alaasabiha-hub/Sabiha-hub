import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'current_catalog.dart';
import 'dropdown_options.dart';
import 'workflow.dart' show newOrderRequestId;

String _t(BuildContext c, String ar, String en) =>
    Localizations.localeOf(c).languageCode == 'ar' ? ar : en;

class OfferManagementScreen extends StatefulWidget {
  final SupabaseClient client;
  const OfferManagementScreen({super.key, required this.client});
  @override
  State<OfferManagementScreen> createState() => _OfferManagementScreenState();
}

class _OfferManagementScreenState extends State<OfferManagementScreen> {
  Map<String, dynamic>? data;
  bool failed = false;
  List<Map<String, dynamic>> rows(String key) {
    final result = List<Map<String, dynamic>>.from(data?[key] ?? []);
    // The owner promotions RPC can repeat a catalogue item when joined to
    // branch or class-price rows. Dropdown values must be unique in Flutter.
    return key == 'services'
        ? uniqueDropdownRows(result, 'item_id')
        : result;
  }
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = Map<String, dynamic>.from(
        await widget.client.rpc('get_owner_promotions'),
      );
      if (mounted) {
        setState(() {
          data = result;
          failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          data = null;
          failed = true;
        });
      }
    }
  }

  Future<void> edit({
    Map<String, dynamic>? service,
    Map<String, dynamic>? offer,
    bool promotion = false,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PromotionEditor(
        client: widget.client,
        services: rows('services'),
        initialService: service,
        initialOffer: offer,
        promotion: promotion,
      ),
    );
    if (saved == true) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _t(context, 'الخدمات والأسعار والعروض', 'Services, prices & offers'),
      ),
    ),
    body: data == null
        ? Center(
            child: failed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _t(
                          context,
                          'تعذر التحميل أو لا تملك صلاحية المالك.',
                          'Unable to load, or owner permission required.',
                        ),
                      ),
                      TextButton(
                        onPressed: load,
                        child: Text(_t(context, 'إعادة المحاولة', 'Retry')),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          )
        : RefreshIndicator(
            onRefresh: load,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  _t(
                    context,
                    'إدارة الفرع الأساسي الحالي. تُحفظ الأسعار الفعلية للخدمة ويؤكدها الخادم عند الحجز.',
                    'Manage the current default branch. Actual service prices are confirmed by the server at booking.',
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add),
                      label: Text(_t(context, 'إضافة خدمة', 'Add service')),
                    ),
                    FilledButton.icon(
                      onPressed: rows('services').isEmpty
                          ? null
                          : () => edit(promotion: true),
                      icon: const Icon(Icons.local_offer_outlined),
                      label: Text(
                        _t(
                          context,
                          'إضافة عرض مرتبط بخدمة',
                          'Add linked offer',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  _t(context, 'الخدمات والأسعار', 'Services & prices'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final service in rows('services'))
                  Card(
                    child: ListTile(
                      title: Text('${service['name']}'),
                      subtitle: Text(
                        'EGP ${service['price']} · ${service['is_active'] == true ? _t(context, 'مفعّلة', 'Active') : _t(context, 'موقوفة', 'Inactive')}',
                      ),
                      trailing: IconButton(
                        tooltip: _t(context, 'تعديل الخدمة', 'Edit service'),
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => edit(service: service),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  _t(context, 'العروض والباقات', 'Offers & packages'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final offer in rows('offers'))
                  Card(
                    child: ListTile(
                      title: Text('${offer['name']}'),
                      subtitle: Text(
                        offer['is_active'] == true && offer['is_public'] == true
                            ? _t(context, 'مفعّل ومنشور', 'Active & published')
                            : _t(
                                context,
                                'موقوف أو غير منشور',
                                'Inactive or unpublished',
                              ),
                      ),
                      trailing: IconButton(
                        tooltip: _t(context, 'تعديل العرض', 'Edit offer'),
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => edit(promotion: true, offer: offer),
                      ),
                    ),
                  ),
              ],
            ),
          ),
  );
}

class _PromotionEditor extends StatefulWidget {
  final SupabaseClient client;
  final List<Map<String, dynamic>> services;
  final Map<String, dynamic>? initialService, initialOffer;
  final bool promotion;
  const _PromotionEditor({
    required this.client,
    required this.services,
    this.initialService,
    this.initialOffer,
    required this.promotion,
  });
  @override
  State<_PromotionEditor> createState() => _PromotionEditorState();
}

class _PromotionEditorState extends State<_PromotionEditor> {
  final form = GlobalKey<FormState>();
  final request = newOrderRequestId();
  final name = TextEditingController(),
      english = TextEditingController(),
      description = TextEditingController(),
      descriptionEn = TextEditingController(),
      price = TextEditingController(),
      duration = TextEditingController();
  final offerName = TextEditingController(),
      offerEn = TextEditingController(),
      offerDescription = TextEditingController(),
      offerDescriptionEn = TextEditingController(),
      comparison = TextEditingController();
  Map<String, dynamic>? service;
  String resource = 'wash', category = 'package', image = 'wash';
  bool active = true,
      published = true,
      offerActive = false,
      offerPublished = false,
      busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final offer = widget.initialOffer;
    if (widget.initialService != null) {
      select(widget.initialService!);
    } else if (offer?['catalog_item_id'] != null) {
      for (final s in widget.services) {
        if (s['item_id'] == offer!['catalog_item_id']) select(s);
      }
    }
    if (service == null) duration.text = '60';
    offerName.text = '${offer?['name'] ?? ''}';
    offerEn.text = '${offer?['name_en'] ?? ''}';
    offerDescription.text = '${offer?['description'] ?? ''}';
    offerDescriptionEn.text = '${offer?['description_en'] ?? ''}';
    comparison.text = '${offer?['compare_price'] ?? ''}';
    category = offer?['presentation_category'] ?? 'package';
    image = offer?['image_asset'] ?? 'wash';
    offerActive = offer?['is_active'] == true;
    offerPublished = offer?['is_public'] == true;
  }

  void select(Map<String, dynamic> row) {
    service = row;
    name.text = '${row['name']}';
    english.text = '${row['name_en'] ?? ''}';
    description.text = '${row['description'] ?? ''}';
    descriptionEn.text = '${row['description_en'] ?? ''}';
    price.text = '${row['price']}';
    duration.text = '${row['duration_minutes']}';
    resource = row['resource_key'] ?? 'wash';
    active = row['is_active'] == true;
    published = row['is_public'] == true;
  }

  @override
  void dispose() {
    for (final c in [
      name,
      english,
      description,
      descriptionEn,
      price,
      duration,
      offerName,
      offerEn,
      offerDescription,
      offerDescriptionEn,
      comparison,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    TextEditingController controller,
    String ar,
    String en, {
    bool required = true,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: _t(context, ar, en)),
      validator: (v) {
        if (required && (v ?? '').trim().isEmpty) {
          return _t(context, 'مطلوب', 'Required');
        }
        if (numeric &&
            (v ?? '').isNotEmpty &&
            num.tryParse(normalizedNumericInput(v!)) == null) {
          return _t(context, 'أدخل رقمًا صحيحًا', 'Enter a number');
        }
        return null;
      },
    ),
  );
  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    if (widget.promotion && service == null) {
      setState(
        () => error = _t(
          context,
          'اختر الخدمة الفعلية المرتبطة.',
          'Select the linked actual service.',
        ),
      );
      return;
    }
    final serviceData = <String, dynamic>{
      'item_id': service?['item_id'],
      'updated_at': service?['updated_at'],
      'name': name.text.trim(),
      'name_en': english.text.trim(),
      'description': description.text.trim(),
      'description_en': descriptionEn.text.trim(),
      'price': num.parse(normalizedNumericInput(price.text)),
      'duration_minutes': int.tryParse(normalizedNumericInput(duration.text)),
      'resource_key': resource,
      'is_active': active,
      'is_public': published,
    };
    final offerData = widget.promotion
        ? <String, dynamic>{
            'offer_id': widget.initialOffer?['offer_id'],
            'updated_at': widget.initialOffer?['updated_at'],
            'name': offerName.text.trim(),
            'name_en': offerEn.text.trim(),
            'description': offerDescription.text.trim(),
            'description_en': offerDescriptionEn.text.trim(),
            'category': category,
            'compare_price': comparison.text.trim().isEmpty
                ? null
                : num.parse(normalizedNumericInput(comparison.text)),
            'image_asset': image,
            'is_active': offerActive,
            'is_public': offerPublished,
            'starts_at': widget.initialOffer?['starts_at'],
            'ends_at': widget.initialOffer?['ends_at'],
          }
        : null;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.client.rpc(
        'save_service_promotion',
        params: {
          'p_request': request,
          'p_service': serviceData,
          'p_offer': offerData,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = _t(
            context,
            'لم يتم تأكيد الحفظ. تحقق من القيم أو حدّث البيانات إذا عدّلها مستخدم آخر، ثم أعد المحاولة.',
            'Save not confirmed. Check values, or refresh if another user changed them, then retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        widget.promotion
            ? _t(context, 'عرض وباقة مرتبطة بالحجز', 'Offer linked to booking')
            : _t(context, 'خدمة وسعر فعلي', 'Service & actual price'),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: IgnorePointer(
              ignoring: busy,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.promotion) ...[
                    DropdownButtonFormField<String>(
                      initialValue: service?['item_id'],
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _t(
                          context,
                          'الخدمة المرتبطة',
                          'Linked service',
                        ),
                      ),
                      items: [
                        for (final s in widget.services)
                          DropdownMenuItem(
                            value: '${s['item_id']}',
                            child: Text(
                              '${s['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) {
                        setState(() {
                          select(
                            widget.services.firstWhere(
                              (s) => s['item_id'] == id,
                            ),
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    field(
                      offerName,
                      'اسم العرض بالعربية',
                      'Offer name in Arabic',
                    ),
                    field(
                      offerEn,
                      'اسم العرض بالإنجليزية',
                      'Offer name in English',
                      required: false,
                    ),
                    field(
                      offerDescription,
                      'وصف العرض بالعربية',
                      'Offer description in Arabic',
                      required: false,
                    ),
                    field(
                      offerDescriptionEn,
                      'وصف العرض بالإنجليزية',
                      'Offer description in English',
                      required: false,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _t(context, 'قسم العرض', 'Offer category'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'package',
                          child: Text(
                            _t(context, 'باقات العناية', 'Care packages'),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'limited',
                          child: Text(
                            _t(context, 'عروض محدودة', 'Limited offers'),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'reward',
                          child: Text(_t(context, 'مكافآت', 'Rewards')),
                        ),
                      ],
                      onChanged: (v) => category = v!,
                    ),
                    const SizedBox(height: 12),
                    field(
                      comparison,
                      'السعر السابق الموثق للمقارنة فقط EGP',
                      'Verified previous price for comparison only EGP',
                      required: false,
                      numeric: true,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: image,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _t(context, 'صورة الباقة', 'Package photo'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'wash',
                          child: Text(_t(context, 'غسيل', 'Wash')),
                        ),
                        DropdownMenuItem(
                          value: 'interior',
                          child: Text(
                            _t(context, 'عناية داخلية', 'Interior care'),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'complete',
                          child: Text(
                            _t(context, 'عناية متكاملة', 'Complete care'),
                          ),
                        ),
                      ],
                      onChanged: (v) => image = v!,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_t(context, 'تفعيل العرض', 'Offer active')),
                      value: offerActive,
                      onChanged: (v) => setState(() => offerActive = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _t(
                          context,
                          'نشر العرض للعملاء',
                          'Publish offer to customers',
                        ),
                      ),
                      value: offerPublished,
                      onChanged: (v) => setState(() => offerPublished = v),
                    ),
                    Text(
                      _t(
                        context,
                        'سعر الخدمة أدناه هو السعر الفعلي لكل حجوزاتها؛ لا يُطبق الكوبون تلقائيًا من هذه الشاشة.',
                        'The service price below applies to all its bookings; this screen does not automatically apply a coupon.',
                      ),
                    ),
                    const Divider(),
                  ],
                  field(name, 'اسم الخدمة بالعربية', 'Service name in Arabic'),
                  field(
                    english,
                    'اسم الخدمة بالإنجليزية',
                    'Service name in English',
                    required: false,
                  ),
                  field(
                    description,
                    'وصف الخدمة بالعربية',
                    'Service description in Arabic',
                    required: false,
                  ),
                  field(
                    descriptionEn,
                    'وصف الخدمة بالإنجليزية',
                    'Service description in English',
                    required: false,
                  ),
                  field(
                    price,
                    'سعر الخدمة الفعلي EGP',
                    'Actual service price EGP',
                    numeric: true,
                  ),
                  field(
                    duration,
                    'مدة الخدمة بالدقائق',
                    'Duration in minutes',
                    numeric: true,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: resource,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _t(
                        context,
                        'مورد الجدولة',
                        'Scheduling resource',
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'wash',
                        child: Text(_t(context, 'غسيل', 'Wash')),
                      ),
                      DropdownMenuItem(
                        value: 'polish',
                        child: Text(_t(context, 'تلميع', 'Polish')),
                      ),
                    ],
                    onChanged: (v) => resource = v!,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_t(context, 'تفعيل الخدمة', 'Service active')),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_t(context, 'نشر الخدمة', 'Publish service')),
                    value: published,
                    onChanged: (v) => setState(() => published = v),
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(_t(context, 'إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(
            busy
                ? _t(context, 'جارٍ الحفظ…', 'Saving…')
                : _t(context, 'حفظ', 'Save'),
          ),
        ),
      ],
    ),
  );
}
