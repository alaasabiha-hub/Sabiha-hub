import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hr_payroll.dart' show hrRequestId;
import 'loyalty_visit_lifecycle.dart';
import 'loyalty_redemption_rules.dart';
import 'owner_reward_controls.dart';
import 'owner_points_policy.dart';
import 'invoice_presentation.dart' show invoiceDate;
import 'owner_catalog_editor.dart' show OwnerCatalogEditor, OwnerCatalogGateway;

abstract class LoyaltyPolicyGateway {
  OwnerPointsGateway? get points => null;
  VisitLifecycleGateway? get visits => null;
  RedemptionRulesGateway? get redemption => null;
  Future<Map<String, dynamic>> read(String? branch);
  Future<void> save(Map<String, dynamic> inputs);
  Future<void> saveOffer(Map<String, dynamic> inputs) =>
      throw UnsupportedError('Visit offer saving unavailable');
}

class SupabaseLoyaltyPolicyGateway extends LoyaltyPolicyGateway {
  SupabaseLoyaltyPolicyGateway(this.client);
  final SupabaseClient client;
  @override
  late final OwnerPointsGateway points = SupabaseOwnerPointsGateway(client);
  @override
  VisitLifecycleGateway get visits => SupabaseVisitLifecycleGateway(client);
  @override
  RedemptionRulesGateway get redemption =>
      SupabaseRedemptionRulesGateway(client);
  @override
  Future<Map<String, dynamic>> read(String? branch) async =>
      Map<String, dynamic>.from(
        await client.rpc('get_loyalty_policy', params: {'p_branch': branch})
            as Map,
      );
  @override
  Future<void> save(Map<String, dynamic> inputs) async {
    await client.rpc('save_loyalty_policy', params: inputs);
  }

  @override
  Future<void> saveOffer(Map<String, dynamic> inputs) async {
    await client.rpc('save_visit_reward_offer', params: inputs);
  }
}

class LoyaltyPolicyScreen extends StatefulWidget {
  const LoyaltyPolicyScreen({super.key, required this.client, this.gateway});
  final SupabaseClient client;
  final LoyaltyPolicyGateway? gateway;
  @override
  State<LoyaltyPolicyScreen> createState() => _LoyaltyPolicyScreenState();
}

class _LoyaltyPolicyScreenState extends State<LoyaltyPolicyScreen> {
  late final LoyaltyPolicyGateway api =
      widget.gateway ?? SupabaseLoyaltyPolicyGateway(widget.client);
  Map<String, dynamic>? data;
  String? branch, offer, error, pendingSignature, pendingId;
  final Set<String> services = {};
  bool enabled = false, busy = false;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String tr(String en, String arabic) => ar ? arabic : en;
  List<Map<String, dynamic>> rows(String key) => ((data?[key] as List?) ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await api.read(branch);
      if (mounted) {
        setState(() {
          data = result;
          branch = result['branch_id'] as String;
          final current = result['current'] as Map?;
          final selectedOffer = current?['offer_id'] as String?;
          offer =
              ((result['offers'] as List?) ?? []).any(
                (o) => (o as Map)['id'] == selectedOffer,
              )
              ? selectedOffer
              : null;
          services
            ..clear()
            ..addAll(
              ((current?['eligible_service_ids'] as List?) ?? [])
                  .cast<String>(),
            );
          enabled = current?['enabled'] == true;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PostgrestException && e.code == '42501'
              ? tr(
                  'Owner access is required to read visit-reward services and policy.',
                  'تتطلب قراءة خدمات المكافآت وسياساتها صلاحية المالك النشط.',
                )
              : tr(
                  'Unable to load this branch policy or service catalogue. Refresh and check the owner session.',
                  'تعذر تحميل سياسة الفرع أو كتالوج الخدمات. حدّث الصفحة وتحقق من جلسة المالك.',
                ),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = services.toList()..sort();
      final inputs = {
        'p_branch': branch,
        'p_offer': offer,
        'p_services': selected,
        'p_enabled': enabled,
      };
      final signature = jsonEncode(inputs);
      if (signature != pendingSignature) {
        pendingSignature = signature;
        pendingId = hrRequestId();
      }
      await api.save({'p_request': pendingId, ...inputs});
      pendingSignature = null;
      pendingId = null;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> _offerForm([Map<String, dynamic>? existing]) async {
    final reference = existing?['reward_item_id'];
    if (reference != null &&
        !rows('services').any((service) => service['id'] == reference)) {
      setState(
        () => error = tr(
          'The existing reward reference belongs outside this branch. Create new branch terms instead.',
          'مرجع المكافأة الحالي خارج هذا الفرع. أنشئ شروطاً جديدة للفرع.',
        ),
      );
      return;
    }
    final name = TextEditingController(
      text: existing?['name']?.toString() ?? '',
    );
    final english = TextEditingController(
      text: existing?['name_en']?.toString() ?? '',
    );
    final threshold = TextEditingController(
      text: existing?['visits_required']?.toString() ?? '',
    );
    bool publish =
        existing?['is_public'] == true && existing?['is_active'] == true;
    String? reward = existing?['reward_item_id'] as String?;
    String? validation;
    var manageServices = false;
    List<Map<String, dynamic>> eligibleRewardServices() => rows('services')
        .where(
          (service) =>
              !publish ||
              (service['is_active'] == true && service['is_public'] == true),
        )
        .toList();
    if (reward != null &&
        !eligibleRewardServices().any((service) => service['id'] == reward)) {
      reward = null;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(
            tr(
              existing == null
                  ? 'Create actual visit reward offer'
                  : 'Edit actual visit reward offer',
              existing == null
                  ? 'إنشاء عرض زيارات فعلي'
                  : 'تعديل عرض زيارات فعلي',
            ),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: tr('Actual offer name', 'اسم العرض الفعلي'),
                    ),
                  ),
                  TextField(
                    controller: english,
                    decoration: InputDecoration(
                      labelText: tr(
                        'English name (optional)',
                        'الاسم بالإنجليزية (اختياري)',
                      ),
                    ),
                  ),
                  TextField(
                    controller: threshold,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr(
                        'Explicit number of service visits',
                        'عدد زيارات الخدمات المحدد',
                      ),
                    ),
                  ),
                  if (eligibleRewardServices().isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: reward,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: tr(
                          'Actual reward service',
                          'خدمة المكافأة الفعلية',
                        ),
                      ),
                      items: [
                        for (final service in eligibleRewardServices())
                          DropdownMenuItem(
                            value: service['id'] as String,
                            child: Text(
                              service['name'] as String,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => update(() => reward = v),
                    )
                  else
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: tr(
                          'Actual reward service',
                          'خدمة المكافأة الفعلية',
                        ),
                      ),
                      child: Text(
                        tr(
                          'No eligible service available',
                          'لا توجد خدمة مؤهلة',
                        ),
                      ),
                    ),
                  if (eligibleRewardServices().isEmpty)
                    Card(
                      key: const ValueKey('loyalty-reward-service-empty'),
                      color: const Color(0xffeef1f5),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              tr(
                                publish
                                    ? 'No active, published services are available in this branch. Add a service or publish one first.'
                                    : 'No services are registered for this branch yet. Add an actual service before creating a visit reward.',
                                publish
                                    ? 'لا توجد خدمات نشطة ومنشورة في هذا الفرع للاختيار كمكافأة. أضف خدمة أو فعّل نشرها أولاً.'
                                    : 'لا توجد خدمات مسجلة في هذا الفرع بعد. أضف خدمة فعلية قبل إنشاء عرض الزيارات.',
                              ),
                              style: const TextStyle(color: Color(0xff101820)),
                            ),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton.icon(
                                key: const ValueKey(
                                  'loyalty-manage-services-from-offer',
                                ),
                                onPressed: () {
                                  manageServices = true;
                                  Navigator.pop(ctx);
                                },
                                icon: const Icon(Icons.inventory_2_outlined),
                                label: Text(
                                  tr('Manage services', 'إدارة الخدمات'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      tr('Publish this actual offer', 'نشر هذا العرض الفعلي'),
                    ),
                    value: publish,
                    onChanged: (v) => update(() {
                      publish = v;
                      if (reward != null &&
                          !eligibleRewardServices().any(
                            (service) => service['id'] == reward,
                          )) {
                        reward = null;
                      }
                    }),
                  ),
                  Text(
                    tr(
                      'Visit count only; no price or currency conversion. Earning and redemption remain disconnected. Publishing the offer does not enable a policy automatically.',
                      'عدد زيارات فقط؛ دون سعر أو تحويل عملة. الاحتساب والاستبدال غير متصلين. نشر العرض لا يفعل السياسة تلقائياً.',
                    ),
                  ),
                  if (validation != null)
                    Text(
                      validation!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Cancel', 'إلغاء')),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(threshold.text.trim());
                if (name.text.trim().length < 2 ||
                    count == null ||
                    count < 1 ||
                    count > 100000 ||
                    reward == null ||
                    !eligibleRewardServices().any(
                      (service) => service['id'] == reward,
                    )) {
                  update(
                    () => validation = tr(
                      'Select a real eligible reward service, enter a name and a positive visit threshold.',
                      'اختر خدمة مكافأة فعلية مؤهلة، وأدخل اسماً وعدداً موجباً للزيارات.',
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx, {
                  'p_branch': branch,
                  'p_name': name.text.trim(),
                  'p_name_en': english.text.trim(),
                  'p_visits': count,
                  'p_publish': publish,
                  'p_reward_service': reward,
                  'p_offer': existing?['id'],
                });
              },
              child: Text(tr('Save actual offer', 'حفظ العرض الفعلي')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    english.dispose();
    threshold.dispose();
    if (result == null || !mounted) {
      if (manageServices && mounted) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                OwnerCatalogEditor(gateway: OwnerCatalogGateway(widget.client)),
          ),
        );
        if (mounted) await _load();
      }
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final signature = 'offer:${jsonEncode(result)}';
      if (pendingSignature != signature) {
        pendingSignature = signature;
        pendingId = hrRequestId();
      }
      await api.saveOffer({'p_request': pendingId, ...result});
      pendingSignature = null;
      pendingId = null;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xffeef1f6),
    appBar: AppBar(
      backgroundColor: const Color(0xff102342),
      foregroundColor: Colors.white,
      title: Text(tr('Service visit policy', 'سياسة زيارات الخدمات')),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: data == null && error == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (error != null)
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(error!),
                      ),
                    ),
                  if (busy) const LinearProgressIndicator(),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr('Unit: service visits', 'الوحدة: زيارات خدمات'),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(
                              api.visits == null
                                  ? 'This saves eligibility policy for new bookings only. Automatic earning and redemption are not connected yet. No money conversion, invoice changes or legacy balance imports occur.'
                                  : 'This saves eligibility for new bookings. Visit earning needs separate activation after worker verification. Redemption remains disabled; no money conversion, invoice changes or legacy balance imports occur.',
                              api.visits == null
                                  ? 'يحفظ هذا أهلية الحجوزات الجديدة فقط. الاحتساب والاستبدال التلقائي غير متصلين بعد. لا يوجد تحويل مالي أو تعديل فواتير أو استيراد أرصدة قديمة.'
                                  : 'يحفظ أهلية الحجوزات الجديدة. يتطلب احتساب الزيارات تفعيلًا مستقلًا بعد التحقق من المعالج. الاستبدال غير مفعل؛ لا تحويل مالي أو تعديل فواتير أو استيراد أرصدة قديمة.',
                            ),
                          ),
                          if (data?['current'] != null)
                            Text(
                              '${tr('Saved version threshold', 'حد الزيارات للإصدار المحفوظ')}: ${((data!['current'] as Map)['policy_snapshot'] as Map)['threshold_visits']} ${tr('visits', 'زيارات')}',
                            ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: branch,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: tr('Branch', 'الفرع'),
                            ),
                            items: [
                              for (final b in rows('branches'))
                                DropdownMenuItem(
                                  value: b['id'] as String,
                                  child: Text(
                                    b[ar ? 'name_ar' : 'name_en'] as String,
                                  ),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) {
                                    setState(() {
                                      branch = v;
                                      data = null;
                                    });
                                    _load();
                                  },
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: busy || branch == null
                                    ? null
                                    : () => _offerForm(),
                                child: Text(
                                  tr(
                                    'Create actual visit reward offer',
                                    'إنشاء عرض زيارات فعلي',
                                  ),
                                ),
                              ),
                              for (final actual in rows('offers').where(
                                (o) =>
                                    o['id'] == offer &&
                                    o['branch_id'] == branch,
                              ))
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => _offerForm(actual),
                                  child: Text(
                                    tr(
                                      'Edit selected branch offer',
                                      'تعديل عرض الفرع المحدد',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: offer,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: tr(
                                'Actual visit reward offer',
                                'عرض مكافأة زيارات فعلي',
                              ),
                            ),
                            items: [
                              for (final o in rows('offers'))
                                DropdownMenuItem(
                                  value: o['id'] as String,
                                  child: Text(
                                    '${o['name']} · ${o['visits_required']} ${tr('visits', 'زيارات')}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) => setState(() => offer = v),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            tr(
                              'Eligible services in this branch',
                              'الخدمات المؤهلة في هذا الفرع',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          for (final s in rows('services'))
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: services.contains(s['id']),
                              title: Text(s['name'] as String),
                              subtitle:
                                  s['is_active'] != true ||
                                      s['is_public'] != true
                                  ? Text(
                                      tr(
                                        'Inactive or unpublished · cannot enable',
                                        'غير نشطة أو غير منشورة · لا يمكن التفعيل',
                                      ),
                                    )
                                  : null,
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        services.add(s['id'] as String);
                                      } else {
                                        services.remove(s['id']);
                                      }
                                    }),
                            ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              tr(
                                'Capture eligibility for future bookings',
                                'تسجيل الأهلية للحجوزات المستقبلية',
                              ),
                            ),
                            subtitle: Text(
                              tr(
                                'Absent configuration stays inactive. Existing bookings are never backfilled.',
                                'يبقى غير نشط دون إعداد. لا تطبق السياسة بأثر رجعي على الحجوزات القائمة.',
                              ),
                            ),
                            value: enabled,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => enabled = v),
                          ),
                          FilledButton(
                            onPressed: busy || offer == null || services.isEmpty
                                ? null
                                : _save,
                            child: Text(
                              tr(
                                'Save new policy version',
                                'حفظ إصدار جديد للسياسة',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (api.visits != null)
                    OwnerVisitLifecyclePanel(
                      key: ValueKey(
                        '$branch-${(data?['current'] as Map?)?['version_id']}',
                      ),
                      gateway: api.visits!,
                      branch: branch,
                    ),
                  if (api.redemption != null)
                    OwnerRedemptionRulesPanel(
                      key: ValueKey(
                        'redemption-$branch-${(data?['current'] as Map?)?['version_id']}',
                      ),
                      gateway: api.redemption!,
                      onPolicyStale: _load,
                      policyVersion:
                          (data?['current'] as Map?)?['version_id'] as String?,
                    ),
                  if (api.points != null && branch != null)
                    OwnerPointsPolicyPanel(
                      key: ValueKey('owner-points-$branch'),
                      gateway: api.points!,
                      branch: branch!,
                    ),
                  if (api.redemption != null)
                    OwnerRewardReviewPanel(
                      client: widget.client,
                      branch: branch,
                    ),
                  for (final v in rows('history'))
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(
                          '${tr('Version', 'الإصدار')} ${v['version_no']} · ${v['enabled'] == true ? tr('Enabled', 'مفعل') : tr('Inactive', 'غير نشط')}',
                        ),
                        subtitle: Text(
                          '${invoiceDate({'issued_at': v['created_at']}, ar)}\n${tr('New booking snapshots', 'لقطات الحجوزات الجديدة')}: ${v['captured_bookings']}',
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}
