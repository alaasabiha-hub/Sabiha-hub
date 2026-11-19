import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class OwnerCouponGateway {
  bool get current;
  Future<String> defaultBranch();
  Future<List<Map<String, dynamic>>> services(String branch);
  Future<List<Map<String, dynamic>>> coupons(String branch);
  Future<void> save({String? couponId, required Map<String, dynamic> values});
}

class SupabaseOwnerCouponGateway implements OwnerCouponGateway {
  SupabaseOwnerCouponGateway(this.client)
    : _actor = client.auth.currentUser?.id,
      _token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? _actor, _token;
  @override
  bool get current =>
      _actor != null &&
      _token != null &&
      client.auth.currentUser?.id == _actor &&
      client.auth.currentSession?.accessToken == _token;

  void _requireCurrent() {
    if (!current) throw StateError('Owner session changed');
  }

  @override
  Future<String> defaultBranch() async {
    _requireCurrent();
    final result = await client.rpc('default_branch_id');
    _requireCurrent();
    if (result is! String || result.isEmpty) {
      throw StateError('Active branch unavailable');
    }
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> services(String branch) async {
    _requireCurrent();
    final result = Map<String, dynamic>.from(
      await client.rpc(
        'get_owner_catalog_items',
        params: {'p_branch': branch, 'p_after': null},
      ) as Map,
    );
    _requireCurrent();
    if (result['branch'] != branch || result['items'] is! List) {
      throw StateError('Unverified branch catalogue');
    }
    return (result['items'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .where((item) => item['item_type'] == 'service')
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> coupons(String branch) async {
    _requireCurrent();
    final result = await client
        .from('business_coupons')
        .select()
        .eq('branch_id', branch)
        .order('created_at', ascending: false)
        .limit(100);
    _requireCurrent();
    return List<Map<String, dynamic>>.from(result);
  }

  @override
  Future<void> save({
    String? couponId,
    required Map<String, dynamic> values,
  }) async {
    _requireCurrent();
    if (couponId == null) {
      await client.from('business_coupons').insert({
        ...values,
        'created_by': _actor,
      });
    } else {
      final result = await client
          .from('business_coupons')
          .update(values)
          .eq('coupon_id', couponId)
          .eq('branch_id', values['branch_id'] as String)
          .select('coupon_id')
          .maybeSingle();
      if (result == null || result['coupon_id'] != couponId) {
        throw StateError('Coupon was not updated in the selected branch');
      }
    }
    _requireCurrent();
  }
}

class OwnerCouponsScreen extends StatefulWidget {
  const OwnerCouponsScreen({super.key, required this.client, this.gateway});
  final SupabaseClient client;
  final OwnerCouponGateway? gateway;
  @override
  State<OwnerCouponsScreen> createState() => _OwnerCouponsScreenState();
}

class _OwnerCouponsScreenState extends State<OwnerCouponsScreen> {
  late final OwnerCouponGateway api =
      widget.gateway ?? SupabaseOwnerCouponGateway(widget.client);
  String? branch, error;
  List<Map<String, dynamic>> services = [], coupons = [];
  bool loading = false;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (loading || !api.current) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final selectedBranch = branch ?? await api.defaultBranch();
      final loaded = await Future.wait([
        api.services(selectedBranch),
        api.coupons(selectedBranch),
      ]);
      if (!mounted || !api.current) return;
      setState(() {
        branch = selectedBranch;
        services = loaded[0];
        coupons = loaded[1];
      });
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          error = e.code == '42501' ? 'denied' : 'load';
          coupons = [];
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'load');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> edit([Map<String, dynamic>? coupon]) async {
    if (!api.current || branch == null) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CouponEditor(
        branch: branch!,
        services: services,
        initial: coupon,
        arabic: ar,
      ),
    );
    if (values == null || !mounted || !api.current) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await api.save(couponId: coupon?['coupon_id'] as String?, values: values);
      if (mounted) {
        setState(() => loading = false);
        await load();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PostgrestException && e.code == '42501'
              ? 'denied'
              : 'save',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
    child: Scaffold(
      backgroundColor: const Color(0xfff1f3f6),
      appBar: AppBar(
        backgroundColor: const Color(0xff071a36),
        foregroundColor: Colors.white,
        title: Text(t('كوبونات الخصم', 'Discount coupons')),
        actions: [
          IconButton(
            tooltip: t('تحديث', 'Refresh'),
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            children: [
              if (loading) const LinearProgressIndicator(),
              Expanded(
                child: error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              error == 'denied'
                                  ? t(
                                      'إدارة الكوبونات متاحة للمالك النشط فقط.',
                                      'Coupon management requires an active owner session.',
                                    )
                                  : t(
                                      'تعذر تحميل أو حفظ الكوبونات. تحقق من الاتصال والصلاحيات.',
                                      'Unable to load or save coupons. Check connection and permissions.',
                                    ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xff071a36)),
                            ),
                            TextButton(
                              onPressed: load,
                              child: Text(t('إعادة المحاولة', 'Retry')),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: load,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      t(
                                        'تُراجع صلاحية كل كوبون وحدوده على الخادم عند تطبيقه. تعرض هذه القائمة كوبونات الفرع النشط؛ لا يكفي إخفاء الكوبون في الواجهة لمنع استخدامه.',
                                        'Coupon eligibility and usage limits are rechecked on the server at checkout. This list is scoped to the active branch; hiding a coupon in the UI alone never enforces eligibility.',
                                      ),
                                      style: const TextStyle(
                                        color: Color(0xff101820),
                                        height: 1.4,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: FilledButton.icon(
                                        onPressed:
                                            branch == null || !api.current
                                            ? null
                                            : () => edit(),
                                        icon: const Icon(Icons.add),
                                        label: Text(
                                          t('إنشاء كوبون', 'Create coupon'),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (coupons.isEmpty)
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text(
                                    t(
                                      'لا توجد كوبونات لهذا الفرع حتى الآن.',
                                      'There are no coupons for this branch yet.',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            for (final coupon in coupons)
                              Card(
                                child: ListTile(
                                  title: Text(
                                    '${coupon['title']}',
                                    style: const TextStyle(
                                      color: Color(0xff071a36),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${coupon['code']} · ${coupon['discount_type'] == 'percentage' ? '${coupon['discount_value']}%' : '${coupon['discount_value']} EGP'} · ${coupon['is_active'] == true && coupon['is_public'] == true ? t('نشط ومنشور', 'Active & published') : t('موقوف أو غير منشور', 'Inactive or unpublished')}',
                                    style: const TextStyle(
                                      color: Color(0xff344252),
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: t(
                                      'تعديل وإيقاف/تفعيل',
                                      'Edit / deactivate / activate',
                                    ),
                                    color: const Color(0xff174b83),
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: loading || !api.current
                                        ? null
                                        : () => edit(coupon),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CouponEditor extends StatefulWidget {
  const _CouponEditor({
    required this.branch,
    required this.services,
    required this.initial,
    required this.arabic,
  });
  final String branch;
  final List<Map<String, dynamic>> services;
  final Map<String, dynamic>? initial;
  final bool arabic;
  @override
  State<_CouponEditor> createState() => _CouponEditorState();
}

class _CouponEditorState extends State<_CouponEditor> {
  late final code = TextEditingController(
    text: '${widget.initial?['code'] ?? ''}',
  );
  late final title = TextEditingController(
    text: '${widget.initial?['title'] ?? ''}',
  );
  late final description = TextEditingController(
    text: '${widget.initial?['description'] ?? ''}',
  );
  late final value = TextEditingController(
    text: '${widget.initial?['discount_value'] ?? ''}',
  );
  late final cap = TextEditingController(
    text: '${widget.initial?['max_discount'] ?? ''}',
  );
  late final minimum = TextEditingController(
    text: '${widget.initial?['minimum_subtotal'] ?? 0}',
  );
  late final uses = TextEditingController(
    text: '${widget.initial?['max_redemptions'] ?? ''}',
  );
  late final perCustomer = TextEditingController(
    text: '${widget.initial?['per_customer_limit'] ?? 1}',
  );
  late final selectedServices = <String>{
    ...((widget.initial?['included_item_ids'] as List?)?.cast<String>() ?? []),
  };
  late DateTime? startsAt = DateTime.tryParse(
    '${widget.initial?['starts_at'] ?? ''}',
  )?.toLocal();
  late DateTime? endsAt = DateTime.tryParse(
    '${widget.initial?['ends_at'] ?? ''}',
  )?.toLocal();
  late String discountType =
      '${widget.initial?['discount_type'] ?? 'percentage'}';
  late bool active = widget.initial?['is_active'] != false;
  late bool published = widget.initial?['is_public'] != false;
  late bool firstPurchase = widget.initial?['first_purchase_only'] == true;
  String? validation;
  String t(String a, String e) => widget.arabic ? a : e;
  double? number(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));
  int? integer(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> chooseDate(bool start) async {
    final now = DateTime.now();
    final existing = start ? startsAt : endsAt;
    final picked = await showDatePicker(
      context: context,
      initialDate: existing ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null && mounted) {
      setState(() {
        if (start) {
          startsAt = DateTime(picked.year, picked.month, picked.day);
        } else {
          endsAt = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      code,
      title,
      description,
      value,
      cap,
      minimum,
      uses,
      perCustomer,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void submit() {
    final normalizedCode = code.text.trim().toUpperCase();
    final amount = number(value);
    final maxDiscount = cap.text.trim().isEmpty ? null : number(cap);
    final minSubtotal = number(minimum);
    final maxUses = uses.text.trim().isEmpty ? null : integer(uses);
    final limit = integer(perCustomer);
    final itemIds = selectedServices.toList()..sort();
    if (!RegExp(r'^[A-Z0-9_-]{3,40}$').hasMatch(normalizedCode) ||
        title.text.trim().isEmpty ||
        title.text.trim().length > 120 ||
        amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        (discountType == 'percentage' && amount > 100) ||
        (cap.text.trim().isNotEmpty &&
            (maxDiscount == null ||
                !maxDiscount.isFinite ||
                maxDiscount < 0)) ||
        minSubtotal == null ||
        !minSubtotal.isFinite ||
        minSubtotal < 0 ||
        (uses.text.trim().isNotEmpty && (maxUses == null || maxUses < 1)) ||
        limit == null ||
        limit < 1 ||
        (startsAt != null && endsAt != null && !endsAt!.isAfter(startsAt!))) {
      setState(
        () => validation = t(
          'راجع الرمز والقيمة والحدود المدخلة.',
          'Check the code, value and usage limits.',
        ),
      );
      return;
    }
    Navigator.pop(context, {
      'branch_id': widget.branch,
      'code': normalizedCode,
      'title': title.text.trim(),
      'description': description.text.trim().isEmpty
          ? null
          : description.text.trim(),
      'discount_type': discountType,
      'discount_value': amount,
      'max_discount': maxDiscount,
      'minimum_subtotal': minSubtotal,
      'max_redemptions': maxUses,
      'per_customer_limit': limit,
      'starts_at': startsAt?.toUtc().toIso8601String(),
      'ends_at': endsAt?.toUtc().toIso8601String(),
      'included_item_ids': itemIds.isEmpty ? null : itemIds,
      'first_purchase_only': firstPurchase,
      'is_active': active,
      'is_public': published,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      t(
        widget.initial == null ? 'إنشاء كوبون' : 'تعديل كوبون',
        widget.initial == null ? 'Create coupon' : 'Edit coupon',
      ),
    ),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: code,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: t('رمز الكوبون', 'Coupon code'),
              ),
            ),
            TextField(
              controller: title,
              decoration: InputDecoration(
                labelText: t('الاسم الظاهر', 'Display title'),
              ),
            ),
            TextField(
              controller: description,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: t('الوصف (اختياري)', 'Description (optional)'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: discountType,
              decoration: InputDecoration(
                labelText: t('نوع الخصم', 'Discount type'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'percentage',
                  child: Text(t('نسبة مئوية', 'Percentage')),
                ),
                DropdownMenuItem(
                  value: 'fixed',
                  child: Text(t('مبلغ ثابت EGP', 'Fixed amount EGP')),
                ),
              ],
              onChanged: (v) =>
                  setState(() => discountType = v ?? 'percentage'),
            ),
            TextField(
              controller: value,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t(
                  discountType == 'percentage'
                      ? 'قيمة النسبة (حتى 100)'
                      : 'قيمة الخصم EGP',
                  discountType == 'percentage'
                      ? 'Discount percentage (up to 100)'
                      : 'Discount amount EGP',
                ),
              ),
            ),
            TextField(
              controller: cap,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t(
                  'سقف الخصم EGP (اختياري)',
                  'Maximum discount EGP (optional)',
                ),
              ),
            ),
            TextField(
              controller: minimum,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t('الحد الأدنى للسلة EGP', 'Minimum basket EGP'),
              ),
            ),
            TextField(
              controller: uses,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t(
                  'إجمالي الاستخدامات (اختياري)',
                  'Total uses (optional)',
                ),
              ),
            ),
            TextField(
              controller: perCustomer,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t('الحد لكل عميل', 'Limit per customer'),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => chooseDate(true),
                  icon: const Icon(Icons.event_available),
                  label: Text(
                    '${t('بداية الصلاحية', 'Starts')}: ${startsAt == null ? t('دون حد', 'No limit') : MaterialLocalizations.of(context).formatMediumDate(startsAt!)}',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => chooseDate(false),
                  icon: const Icon(Icons.event_busy),
                  label: Text(
                    '${t('نهاية الصلاحية', 'Expires')}: ${endsAt == null ? t('دون حد', 'No limit') : MaterialLocalizations.of(context).formatMediumDate(endsAt!)}',
                  ),
                ),
                if (startsAt != null || endsAt != null)
                  TextButton(
                    onPressed: () => setState(() {
                      startsAt = null;
                      endsAt = null;
                    }),
                    child: Text(t('مسح التاريخ', 'Clear dates')),
                  ),
              ],
            ),
            if (widget.services.isNotEmpty) ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    t(
                      'الخدمات المؤهلة (اتركها فارغة لكل البنود)',
                      'Eligible services (leave empty for all items)',
                    ),
                  ),
                ),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final s in widget.services)
                    FilterChip(
                      label: Text('${s['name']}'),
                      selected: selectedServices.contains('${s['item_id']}'),
                      onSelected: (selected) => setState(() {
                        selected
                            ? selectedServices.add('${s['item_id']}')
                            : selectedServices.remove('${s['item_id']}');
                      }),
                    ),
                ],
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('لأول عملية شراء فقط', 'First purchase only')),
              value: firstPurchase,
              onChanged: (v) => setState(() => firstPurchase = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('تفعيل الاستخدام', 'Active')),
              value: active,
              onChanged: (v) => setState(() => active = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('إظهار للعملاء', 'Visible to customers')),
              value: published,
              onChanged: (v) => setState(() => published = v),
            ),
            if (validation != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  validation!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('إلغاء', 'Cancel')),
      ),
      FilledButton(onPressed: submit, child: Text(t('حفظ', 'Save'))),
    ],
  );
}
