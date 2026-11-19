import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

abstract class OwnerTaxGateway {
  bool get current;
  Stream<void> get changes;
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

class SupabaseOwnerTaxGateway implements OwnerTaxGateway {
  SupabaseOwnerTaxGateway(this.client) : session = client.auth.currentSession;
  final SupabaseClient client;
  final Session? session;
  @override
  bool get current =>
      session != null &&
      client.auth.currentSession?.accessToken == session!.accessToken &&
      client.auth.currentUser?.id == session!.user.id;
  @override
  Stream<void> get changes => client.auth.onAuthStateChange
      .where((event) => !matchesInitialAuthReplay(event, session))
      .map((_) {});
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!current ||
        !const {
          'get_owner_tax_invoice_settings',
          'propose_owner_tax_classification',
          'review_owner_tax_classification',
          'pause_owner_tax_classification',
          'save_owner_tax_invoice_defaults',
        }.contains(name)) {
      throw StateError('Owner tax session unavailable');
    }
    final value = await client
        .rpc(name, params: params)
        .timeout(const Duration(seconds: 25));
    if (!current) throw StateError('Owner session changed');
    return Map<String, dynamic>.from(value as Map);
  }
}

String _number(String value) => value
    .trim()
    .replaceAll('٫', '.')
    .replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (m) {
      final c = m[0]!.runes.single;
      return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
    });
String _taxMode(BuildContext context, String? mode) {
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  return switch (mode) {
    'inclusive' => ar ? 'شامل الضريبة' : 'Tax inclusive',
    'exclusive' => ar ? 'غير شامل الضريبة' : 'Tax exclusive',
    'exempt' => ar ? 'معفى بتصنيف موثّق' : 'Documented exemption',
    'non_taxable' => ar ? 'غير خاضع بتصنيف موثّق' : 'Documented non-taxable',
    _ => ar ? 'غير مهيأ' : 'Not configured',
  };
}

class OwnerTaxInvoiceSettingsScreen extends StatefulWidget {
  const OwnerTaxInvoiceSettingsScreen({
    super.key,
    required this.gateway,
    required this.branch,
  });
  final OwnerTaxGateway gateway;
  final String branch;
  @override
  State<OwnerTaxInvoiceSettingsScreen> createState() =>
      _OwnerTaxInvoiceSettingsScreenState();
}

class _OwnerTaxInvoiceSettingsScreenState
    extends State<OwnerTaxInvoiceSettingsScreen> {
  final search = TextEditingController();
  StreamSubscription<void>? auth;
  Map<String, dynamic>? data, pending;
  List<Map<String, dynamic>> rows = [];
  BuildContext? ownedDialog;
  int epoch = 0;
  bool busy = false, invalid = false;
  String? error;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  bool get active => mounted && !invalid && widget.gateway.current;
  bool get editable => active && !busy && pending == null;
  @override
  void initState() {
    super.initState();
    auth = widget.gateway.changes.listen((_) => invalidate());
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant OwnerTaxInvoiceSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.branch != widget.branch) {
      invalidate();
    }
  }

  void invalidate() {
    if (!mounted) return;
    epoch++;
    if (ownedDialog?.mounted == true) Navigator.of(ownedDialog!).pop();
    ownedDialog = null;
    setState(() {
      invalid = true;
      busy = false;
      rows = [];
      data = pending = null;
      error = null;
      search.clear();
    });
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    search.dispose();
    super.dispose();
  }

  String failure(Object e) => e is PostgrestException && e.code == '40001'
      ? t(
          'تغير إصدار الإعدادات. حدّث البيانات وراجعها قبل إعادة المحاولة.',
          'The settings version changed. Refresh and review before retrying.',
        )
      : t(
          'تعذر التنفيذ. راجع الصلاحية والتصنيف والأدلة والمراجعة المطلوبة.',
          'Unable to continue. Check permissions, classification, evidence and required review.',
        );
  Future<void> load({bool more = false}) async {
    if (!editable) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.call(
        'get_owner_tax_invoice_settings',
        {
          'p_branch': widget.branch,
          'p_search': search.text.trim(),
          'p_after': more && rows.isNotEmpty ? rows.last['item_id'] : null,
        },
      );
      if (!active || generation != epoch) return;
      if (result['owner_only'] != true ||
          result['eta_submission_enabled'] != false ||
          result['notice_version'] != 'tax-review-v1') {
        throw StateError('Invalid owner tax context');
      }
      final items = List<Map<String, dynamic>>.from(result['items'] as List);
      data = result;
      rows = more ? [...rows, ...items] : items;
    } catch (e) {
      if (active && generation == epoch) {
        if (e is PostgrestException && e.code == '42501') {
          invalidate();
          return;
        }
        error = failure(e);
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Future<T?> modal<T>(Widget child) async {
    final generation = epoch;
    try {
      final result = await showDialog<T>(
        context: context,
        builder: (ctx) {
          ownedDialog = ctx;
          return child;
        },
      );
      return active && generation == epoch ? result : null;
    } finally {
      ownedDialog = null;
    }
  }

  Future<void> command(String name, Map<String, dynamic> params) async {
    if (!editable) return;
    pending = {
      'name': name,
      'params': jsonDecode(
        jsonEncode({
          'p_request': newOrderRequestId(),
          'p_branch': widget.branch,
          ...params,
        }),
      ),
    };
    await retry();
  }

  Future<void> retry() async {
    if (!active || busy || pending == null) return;
    final generation = epoch;
    var accepted = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = pending!;
      final params = Map<String, dynamic>.from(saved['params'] as Map);
      final name = saved['name'] as String;
      final result = await widget.gateway.call(name, params);
      if (!active || generation != epoch) return;
      final valid = switch (name) {
        'propose_owner_tax_classification' =>
          result['state'] == 'pending_review' && result['active'] == false,
        'review_owner_tax_classification' =>
          result['state'] ==
                  (params['p_decision'] == 'approve'
                      ? 'owner_reviewed'
                      : 'rejected') &&
              result['eta_accepted'] == false &&
              result['legally_verified_by_software'] == false,
        'pause_owner_tax_classification' =>
          result['state'] == 'paused' &&
              result['zero_tax_fallback'] == false &&
              result['active_version'] ==
                  (params['p_expected_version'] as int) + 1,
        'save_owner_tax_invoice_defaults' =>
          result['version'] == (params['p_expected_version'] as int) + 1 &&
              result['requires_item_review'] == true &&
              result['changes_existing_invoices'] == false,
        _ => false,
      };
      if (!valid) throw StateError('Unverified tax command receipt');
      pending = null;
      accepted = true;
    } catch (e) {
      if (active && generation == epoch) {
        if (e is PostgrestException && e.code == '42501') {
          invalidate();
          return;
        }
        error = failure(e);
        if (e is PostgrestException) pending = null;
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
    if (accepted && active) await load();
  }

  Future<void> propose(Map<String, dynamic> row) async {
    if (!editable) return;
    final spec = await modal<Map<String, dynamic>>(
      _TaxClassificationDialog(
        initial: row['active_classification'] is Map
            ? Map<String, dynamic>.from(row['active_classification'] as Map)
            : null,
        defaults: data?['defaults'] is Map
            ? Map<String, dynamic>.from(data!['defaults'] as Map)
            : null,
      ),
    );
    if (!active || spec == null) return;
    await command('propose_owner_tax_classification', {
      'p_item': row['item_id'],
      'p_expected_version': row['active_version'],
      'p_spec': spec,
    });
  }

  Future<void> review(
    Map<String, dynamic> proposal,
    bool approve,
    int currentVersion,
  ) async {
    if (!editable) return;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final notice = data![ar ? 'notice_ar' : 'notice_en'] as String;
    final decision = await modal<Map<String, dynamic>>(
      _TaxReviewDialog(
        title: t(
          approve ? 'مراجعة التصنيف واعتماده' : 'رفض التصنيف',
          approve
              ? 'Review and approve classification'
              : 'Reject classification',
        ),
        notice: approve ? notice : null,
        spec: Map<String, dynamic>.from(proposal['spec'] as Map),
      ),
    );
    if (!active || decision == null) return;
    await command('review_owner_tax_classification', {
      'p_proposal': proposal['proposal_id'],
      'p_expected_version': approve ? proposal['base_version'] : currentVersion,
      'p_decision': approve ? 'approve' : 'reject',
      'p_reason': decision['reason'],
      'p_ack': approve
          ? {
              'version': 'tax-review-v1',
              'language': ar ? 'ar' : 'en',
              'text': notice,
              'reviewed': true,
            }
          : null,
    });
  }

  Future<void> pause(Map<String, dynamic> row) async {
    if (!editable) return;
    final decision = await modal<Map<String, dynamic>>(
      _TaxReviewDialog(
        title: t('إيقاف التصنيف', 'Pause classification'),
        notice: null,
        explanation: t(
          'الإيقاف يمنع استخدام تصنيف غير مراجع؛ لا يحوّل الضريبة إلى صفر ولا يغيّر فاتورة سابقة.',
          'Pausing blocks unreviewed classification use; it never sets tax to zero or changes an existing invoice.',
        ),
      ),
    );
    if (!active || decision == null) return;
    await command('pause_owner_tax_classification', {
      'p_item': row['item_id'],
      'p_expected_version': row['active_version'],
      'p_reason': decision['reason'],
    });
  }

  Future<void> defaults() async {
    if (!editable) return;
    final old = data?['defaults'] is Map
        ? Map<String, dynamic>.from(data!['defaults'] as Map)
        : null;
    final selected = await modal<Map<String, dynamic>>(
      _TaxDefaultsDialog(initial: old),
    );
    if (!active || selected == null) return;
    await command('save_owner_tax_invoice_defaults', {
      'p_expected_version': old?['version'] ?? 0,
      'p_display_mode': selected['mode'],
      'p_default_rate': selected['rate'],
      'p_reason': selected['reason'],
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('إعدادات الضرائب والفواتير', 'Tax & Invoice Settings')),
    ),
    body: invalid || !widget.gateway.current
        ? Center(
            child: Text(
              t(
                'يلزم تسجيل دخول المالك من جديد.',
                'The owner must sign in again.',
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  'للمالك فقط. التصنيف يحتاج أساسًا موثقًا ومراجعة منفصلة؛ لا نسب افتراضية قانونية ولا إرسال ETA.',
                  'Owner only. Classification needs documented basis and separate review; no assumed legal default rate or ETA submission.',
                ),
              ),
              if (data?['invoice_issuance_integrated'] == false)
                Text(
                  t(
                    'إعدادات قيد الربط بمسار الإصدار؛ لا تغيّر الفواتير أو أسعار العميل الحالية.',
                    'Settings are awaiting issuance integration; existing invoices and current customer prices are unchanged.',
                  ),
                ),
              if (data?['invoice_issuance_integrated'] == true &&
                  data?['invoice_issuance_scope'] ==
                      'reviewed_cashier_registered_customer_only')
                Text(
                  t(
                    'التصنيف المعتمد يطبّق على فواتير نقطة البيع الجديدة للعملاء المسجلين، دون إعادة حساب الفواتير السابقة.',
                    'Reviewed tax applies to new point-of-sale invoices for registered customers; earlier invoices are not recalculated.',
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
              if (pending != null)
                FilledButton(
                  onPressed: busy ? null : retry,
                  child: Text(
                    t(
                      'إعادة نفس طلب الإعدادات',
                      'Retry the same settings request',
                    ),
                  ),
                ),
              Card(
                key: const ValueKey('owner-branch-tax-price-display'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        t(
                          'طريقة عرض واحتساب الأسعار — هذا الفرع',
                          'Price display and tax calculation — this branch',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        t(
                          'الافتراضي الحالي: ${_taxMode(context, (data?['defaults'] as Map?)?['display_mode'] as String?)}',
                          'Current default: ${_taxMode(context, (data?['defaults'] as Map?)?['display_mode'] as String?)}',
                        ),
                      ),
                      Text(
                        t(
                          'الأسعار شاملة ضريبة القيمة المضافة',
                          'Prices include value-added tax',
                        ),
                      ),
                      Text(
                        t(
                          'الأسعار غير شاملة ضريبة القيمة المضافة',
                          'Prices exclude value-added tax',
                        ),
                      ),
                      Text(
                        t(
                          'هذا هو الافتراضي لهذا الفرع ويُستخدم عند اقتراح تصنيف بند جديد. طريقة البند الفعلية لا تتغير إلا بتصنيف موثق ومراجَع؛ لا تُفترض نسبة أو معاملة قانونية ولا تتغير الفواتير السابقة.',
                          'This branch default preselects the mode when proposing a new item classification. A line uses only its separately documented and reviewed tax classification; no rate or legal treatment is assumed, and prior invoices never change.',
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: editable ? defaults : null,
                        child: Text(
                          t(
                            'تعديل طريقة الأسعار الافتراضية لهذا الفرع',
                            'Change this branch’s default price method',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TextField(
                controller: search,
                enabled: editable,
                decoration: InputDecoration(
                  labelText: t(
                    'بحث الخدمات والمنتجات',
                    'Search services and products',
                  ),
                ),
                onSubmitted: (_) => load(),
              ),
              OutlinedButton(
                onPressed: editable ? () => load() : null,
                child: Text(t('بحث', 'Search')),
              ),
              for (final row in rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          Localizations.localeOf(context).languageCode == 'ar'
                              ? '${row['name']}'
                              : '${row['name_en'] ?? row['name']}',
                        ),
                        Text(
                          _taxMode(
                            context,
                            (row['active_classification'] as Map?)?['tax_mode']
                                as String?,
                          ),
                        ),
                        if (row['active_classification'] is Map)
                          Text(
                            '${(row['active_classification'] as Map)['rate_percent']}% · ${(row['active_classification'] as Map)['eta_subtype']}',
                          ),
                        Text(
                          '${t('الإصدار', 'Version')}: ${row['active_version']}',
                        ),
                        OutlinedButton(
                          onPressed: editable ? () => propose(row) : null,
                          child: Text(
                            t(
                              'اقتراح تصنيف موثّق',
                              'Propose documented classification',
                            ),
                          ),
                        ),
                        if (row['active_classification'] != null)
                          TextButton(
                            onPressed: editable ? () => pause(row) : null,
                            child: Text(
                              t('إيقاف التصنيف', 'Pause classification'),
                            ),
                          ),
                        for (final p in List<Map<String, dynamic>>.from(
                          row['pending_proposals'] as List,
                        )) ...[
                          Text(t('بانتظار المراجعة', 'Awaiting review')),
                          Text(
                            '${_taxMode(context, (p['spec'] as Map)['tax_mode'] as String?)} · ${(p['spec'] as Map)['rate_percent']}%',
                          ),
                          if (p['base_version'] != row['active_version'])
                            Text(
                              t(
                                'اقتراح قديم؛ يمكن رفضه أو تقديم اقتراح جديد.',
                                'Stale proposal; reject it or submit a new one.',
                              ),
                            ),
                          FilledButton(
                            onPressed:
                                editable &&
                                    p['base_version'] == row['active_version']
                                ? () => review(
                                    p,
                                    true,
                                    row['active_version'] as int,
                                  )
                                : null,
                            child: Text(
                              t('مراجعة واعتماد', 'Review and approve'),
                            ),
                          ),
                          TextButton(
                            onPressed: editable
                                ? () => review(
                                    p,
                                    false,
                                    row['active_version'] as int,
                                  )
                                : null,
                            child: Text(
                              t('رفض مع السبب', 'Reject with reason'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              if (data?['has_more'] == true)
                OutlinedButton(
                  onPressed: editable ? () => load(more: true) : null,
                  child: Text(t('تحميل المزيد', 'Load more')),
                ),
            ],
          ),
  );
}

class _TaxClassificationDialog extends StatefulWidget {
  const _TaxClassificationDialog({this.initial, this.defaults});
  final Map<String, dynamic>? initial, defaults;
  @override
  State<_TaxClassificationDialog> createState() =>
      _TaxClassificationDialogState();
}

class _TaxClassificationDialogState extends State<_TaxClassificationDialog> {
  late String? mode =
      widget.initial?['tax_mode'] as String? ??
      widget.defaults?['display_mode'] as String?;
  late String? subtype = widget.initial?['eta_subtype'] as String?;
  late final rate = TextEditingController(
    text:
        '${widget.initial?['rate_percent'] ?? widget.defaults?['default_rate'] ?? ''}',
  );
  late final basis = TextEditingController(
    text: widget.initial?['legal_basis'] as String? ?? '',
  );
  late final evidence = TextEditingController(
    text: widget.initial?['evidence_reference'] as String? ?? '',
  );
  String? error;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  List<String> get codes => mode == 'exempt'
      ? ['V003', 'V005', 'V006', 'V007', 'V008']
      : mode == 'non_taxable'
      ? ['V004']
      : ['V009', 'V010'];
  @override
  void dispose() {
    rate.dispose();
    basis.dispose();
    evidence.dispose();
    super.dispose();
  }

  void submit() {
    final v = _number(rate.text), n = num.tryParse(_number(rate.text));
    final zero = mode == 'exempt' || mode == 'non_taxable';
    if (mode == null ||
        subtype == null ||
        !codes.contains(subtype) ||
        !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(v) ||
        n == null ||
        !n.isFinite ||
        n < 0 ||
        n > 999 ||
        (zero ? n != 0 : n <= 0) ||
        basis.text.trim().length < 5 ||
        evidence.text.trim().length < 5) {
      setState(
        () => error = t(
          'راجع أساس السعر والمعدل والتصنيف والأساس القانوني ومرجع الأدلة.',
          'Check price basis, rate, subtype, legal basis and evidence reference.',
        ),
      );
      return;
    }
    Navigator.pop(context, {
      'tax_mode': mode,
      'rate_percent': n,
      'eta_subtype': subtype,
      'legal_basis': basis.text.trim(),
      'evidence_reference': evidence.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('اقتراح تصنيف موثّق', 'Propose documented classification')),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(
                'الحفظ يرسل اقتراحًا للمراجعة، ولا يفعّل إعفاءً أو نسبة تلقائيًا.',
                'Saving creates a review proposal; it does not automatically activate an exemption or rate.',
              ),
            ),
            if (error != null) Text(error!),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: mode,
              decoration: InputDecoration(
                labelText: t(
                  'أساس السعر والتصنيف',
                  'Price basis and classification',
                ),
              ),
              items: [
                for (final m in [
                  'exclusive',
                  'inclusive',
                  'exempt',
                  'non_taxable',
                ])
                  DropdownMenuItem(value: m, child: Text(_taxMode(context, m))),
              ],
              onChanged: (v) => setState(() {
                mode = v;
                if (!codes.contains(subtype)) subtype = null;
              }),
            ),
            TextField(
              controller: rate,
              decoration: InputDecoration(
                labelText: t('النسبة الصريحة %', 'Explicit rate %'),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(mode),
              isExpanded: true,
              initialValue: subtype,
              decoration: InputDecoration(
                labelText: t('التصنيف الضريبي', 'Tax subtype'),
              ),
              items: [
                for (final c in codes)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => subtype = v),
            ),
            TextField(
              controller: basis,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: t('الأساس القانوني', 'Legal basis'),
              ),
            ),
            TextField(
              controller: evidence,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t(
                  'مرجع الأدلة أو مراجعة المختص',
                  'Evidence or specialist review reference',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('رجوع', 'Back')),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(t('حفظ الاقتراح', 'Save proposal')),
      ),
    ],
  );
}

class _TaxReviewDialog extends StatefulWidget {
  const _TaxReviewDialog({
    required this.title,
    this.notice,
    this.explanation,
    this.spec,
  });
  final String title;
  final String? notice, explanation;
  final Map<String, dynamic>? spec;
  @override
  State<_TaxReviewDialog> createState() => _TaxReviewDialogState();
}

class _TaxReviewDialogState extends State<_TaxReviewDialog> {
  final reason = TextEditingController();
  bool confirmed = false;
  String? error;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  void submit() {
    if (reason.text.trim().length < 5 ||
        (widget.notice != null && !confirmed)) {
      setState(
        () => error = t(
          'أدخل السبب وأكّد المراجعة المطلوبة.',
          'Enter a reason and confirm the required review.',
        ),
      );
      return;
    }
    Navigator.pop(context, {'reason': reason.text.trim()});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.explanation != null) Text(widget.explanation!),
            if (widget.spec != null) ...[
              Text(_taxMode(context, widget.spec!['tax_mode'] as String?)),
              Text(
                '${widget.spec!['rate_percent']}% · ${widget.spec!['eta_subtype']}',
              ),
              Text('${widget.spec!['legal_basis']}'),
              Text('${widget.spec!['evidence_reference']}'),
            ],
            if (error != null) Text(error!),
            TextField(
              controller: reason,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t('سبب القرار', 'Decision reason'),
              ),
            ),
            if (widget.notice != null)
              CheckboxListTile(
                title: Text(widget.notice!),
                value: confirmed,
                onChanged: (v) => setState(() => confirmed = v == true),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('رجوع', 'Back')),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(t('تأكيد القرار', 'Confirm decision')),
      ),
    ],
  );
}

class _TaxDefaultsDialog extends StatefulWidget {
  const _TaxDefaultsDialog({this.initial});
  final Map<String, dynamic>? initial;
  @override
  State<_TaxDefaultsDialog> createState() => _TaxDefaultsDialogState();
}

class _TaxDefaultsDialogState extends State<_TaxDefaultsDialog> {
  late String? mode = widget.initial?['display_mode'] as String?;
  late final rate = TextEditingController(
    text: '${widget.initial?['default_rate'] ?? ''}',
  );
  final reason = TextEditingController();
  String? error;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  @override
  void dispose() {
    rate.dispose();
    reason.dispose();
    super.dispose();
  }

  void submit() {
    final text = _number(rate.text), n = num.tryParse(_number(rate.text));
    if (mode == null ||
        reason.text.trim().length < 5 ||
        (text.isNotEmpty &&
            (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text) ||
                n == null ||
                !n.isFinite ||
                n <= 0 ||
                n > 999))) {
      setState(
        () => error = t(
          'حدد أساس العرض والسبب ونسبة موجبة أو اتركها غير مهيأة.',
          'Select a display basis and reason; use a positive suggestion or leave it unconfigured.',
        ),
      );
      return;
    }
    Navigator.pop(context, {
      'mode': mode,
      'rate': text.isEmpty ? null : n,
      'reason': reason.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      t(
        'طريقة عرض واحتساب الأسعار لهذا الفرع',
        'Price display and tax calculation for this branch',
      ),
    ),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t(
                'النسبة المقترحة لا تتجاوز مراجعة كل بند، ولا تعني خضوع جميع المعاملات لنفس الضريبة.',
                'The suggestion never bypasses individual item review or implies all transactions have the same tax.',
              ),
            ),
            Text(
              t(
                'يُحفظ هذا الاختيار كافتراضي للفرع فقط. لا يعيد حساب الفواتير الصادرة ولا يفعّل تصنيفًا ضريبيًا تلقائيًا.',
                'This is saved as the branch default only. It does not recalculate issued invoices or automatically activate an item tax classification.',
              ),
            ),
            if (error != null) Text(error!),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: mode,
                decoration: InputDecoration(
                  labelText: t(
                    'الأسعار شاملة أم غير شاملة لضريبة القيمة المضافة؟',
                    'Are entered prices tax inclusive or tax exclusive?',
                  ),
                ),
              items: [
                for (final m in ['exclusive', 'inclusive'])
                  DropdownMenuItem(value: m, child: Text(_taxMode(context, m))),
              ],
              onChanged: (v) => setState(() => mode = v),
            ),
            TextField(
              controller: rate,
              decoration: InputDecoration(
                labelText: t(
                  'نسبة مقترحة اختيارية %',
                  'Optional suggested rate %',
                ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            TextField(
              controller: reason,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t('سبب التغيير', 'Reason for change'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('رجوع', 'Back')),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(t('حفظ الإعدادات', 'Save settings')),
      ),
    ],
  );
}

/// Main-app launcher resolves the actual single centre without altering selection.
class OwnerTaxInvoiceSettingsEntry extends StatefulWidget {
  const OwnerTaxInvoiceSettingsEntry({super.key, required this.client});
  final SupabaseClient client;
  @override
  State<OwnerTaxInvoiceSettingsEntry> createState() =>
      _OwnerTaxInvoiceSettingsEntryState();
}

class _OwnerTaxInvoiceSettingsEntryState
    extends State<OwnerTaxInvoiceSettingsEntry> {
  late final gateway = SupabaseOwnerTaxGateway(widget.client);
  late final Future<String> branch = resolveBranch();
  Future<String> resolveBranch() async {
    if (!gateway.current) throw StateError('Owner session unavailable');
    final value = await widget.client
        .rpc('default_branch_id')
        .timeout(const Duration(seconds: 20));
    if (!gateway.current || value is! String || value.isEmpty) {
      throw StateError('Centre unavailable');
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return StreamBuilder<void>(
      stream: gateway.changes,
      builder: (context, _) => FutureBuilder<String>(
        future: branch,
        builder: (context, snapshot) {
          if (gateway.current && snapshot.hasData) {
            return OwnerTaxInvoiceSettingsScreen(
              gateway: gateway,
              branch: snapshot.data!,
            );
          }
          return Scaffold(
            appBar: AppBar(
              title: Text(
                ar ? 'إعدادات الضرائب والفواتير' : 'Tax & Invoice Settings',
              ),
            ),
            body: Center(
              child: !gateway.current
                  ? Text(
                      ar
                          ? 'يلزم تسجيل دخول المالك من جديد.'
                          : 'The owner must sign in again.',
                    )
                  : snapshot.hasError
                  ? Text(
                      ar
                          ? 'تعذر فتح إعدادات المركز. تحقق من الصلاحية والاتصال.'
                          : 'Unable to open centre settings. Check permissions and connection.',
                    )
                  : const CircularProgressIndicator(),
            ),
          );
        },
      ),
    );
  }
}
