import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

String _t(BuildContext c, String ar, String en) =>
    Localizations.localeOf(c).languageCode == 'en' ? en : ar;

abstract class ServiceQualityGateway {
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params);
}

class SupabaseServiceQualityGateway implements ServiceQualityGateway {
  SupabaseServiceQualityGateway(this.client)
    : actor = client.auth.currentUser?.id,
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? actor, token;
  bool get valid =>
      actor != null &&
      token != null &&
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession?.accessToken == token;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (!valid ||
        !const {
          'get_service_quality',
          'submit_service_quality',
          'get_service_quality_policy',
          'save_service_quality_policy',
        }.contains(name)) {
      throw StateError('Quality scope changed');
    }
    final data = await client.rpc(name, params: params);
    if (!valid) throw StateError('Quality scope changed');
    return Map<String, dynamic>.from(data as Map);
  }
}

/// Frozen operational checklist; this screen never changes work/payment status.
class ServiceQualityScreen extends StatefulWidget {
  const ServiceQualityScreen({
    super.key,
    required this.order,
    required this.gateway,
  });
  final String order;
  final ServiceQualityGateway gateway;
  @override
  State<ServiceQualityScreen> createState() => _ServiceQualityScreenState();
}

class _ServiceQualityScreenState extends State<ServiceQualityScreen> {
  Map<String, dynamic>? data, pending;
  final note = TextEditingController();
  final answers = <String, bool?>{};
  bool busy = false, failed = false;
  int epoch = 0;
  StreamSubscription<AuthState>? auth;
  void watch() {
    auth?.cancel();
    final gateway = widget.gateway;
    if (gateway is SupabaseServiceQualityGateway) {
      auth = gateway.client.auth.onAuthStateChange.listen((_) {
        if (!gateway.valid && mounted) {
          epoch++;
          setState(() {
            data = null;
            pending = null;
            busy = false;
            failed = true;
          });
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    watch();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant ServiceQualityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.order != widget.order ||
        oldWidget.gateway != widget.gateway) {
      watch();
      epoch++;
      data = null;
      pending = null;
      answers.clear();
      note.clear();
      unawaited(load());
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    epoch++;
    note.dispose();
    super.dispose();
  }

  List<Map> items(Map<String, dynamic> value) {
    if (value['order_id'] != widget.order ||
        value['required'] is! bool ||
        value['can_submit'] is! bool ||
        value['items'] is! List ||
        value['checks'] is! List) {
      throw const FormatException('Quality context');
    }
    final rows = List<Map>.from(value['items'] as List);
    if (rows.length > 30 ||
        (value['required'] == true && rows.isEmpty) ||
        rows.map((v) => v['id']).toSet().length != rows.length ||
        rows.any(
          (v) =>
              !RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch('${v['id']}') ||
              v['ar'] is! String ||
              (v['ar'] as String).trim().isEmpty ||
              v['en'] is! String ||
              (v['en'] as String).trim().isEmpty,
        )) {
      throw const FormatException('Quality items');
    }
    return rows;
  }

  Future<void> load() async {
    final scope = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      data = null;
    });
    try {
      final value = await widget.gateway.call('get_service_quality', {
        'p_order': widget.order,
      });
      items(value);
      if (!mounted || scope != epoch) return;
      setState(() {
        data = value;
        busy = false;
      });
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          failed = true;
          data = null;
        });
      }
    }
  }

  Future<void> submit() async {
    if (busy || data?['can_submit'] != true) return;
    final rows = items(data!);
    if (pending == null && rows.any((v) => answers[v['id']] == null)) return;
    pending ??= {
      'p_request': newOrderRequestId(),
      'p_order': widget.order,
      'p_answers': {for (final v in rows) v['id']: answers[v['id']]},
      'p_note': note.text.trim(),
    };
    final scope = epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final result = await widget.gateway.call(
        'submit_service_quality',
        Map.of(pending!),
      );
      if (result['request_id'] != pending!['p_request'] ||
          result['passed'] is! bool) {
        throw const FormatException('Quality result');
      }
      if (!mounted || scope != epoch) return;
      pending = null;
      answers.clear();
      note.clear();
      await load();
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = data == null ? <Map>[] : items(data!);
    final locked = busy || pending != null;
    return PopScope(
      canPop: pending == null && !busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_t(context, 'فحص جودة الخدمة', 'Service quality check')),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              _t(
                context,
                'يُسجل الفحص فقط؛ إكمال الخدمة والتسليم والدفع خطوات مستقلة.',
                'Records inspection only; service completion, delivery and payment are separate steps.',
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (failed)
              Text(
                _t(
                  context,
                  'تعذر تأكيد النتيجة. أعد المحاولة بنفس الطلب؛ لن تتغير إجابات الطلب المعلق.',
                  'Could not confirm the result. Retry the same request; pending answers stay unchanged.',
                ),
              ),
            if (data == null && !busy)
              OutlinedButton(
                onPressed: load,
                child: Text(_t(context, 'إعادة التحميل', 'Reload')),
              ),
            if (data != null && data!['required'] == false)
              Text(
                _t(
                  context,
                  'لا توجد قائمة إلزامية مجمدة لهذه الزيارة. تبقى فحوص الاستلام والصور منفصلة.',
                  'No mandatory checklist was frozen for this visit. Reception and photo inspections remain separate.',
                ),
              ),
            for (final row in rows)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row[Localizations.localeOf(context).languageCode == 'en'
                                ? 'en'
                                : 'ar']
                            as String,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Semantics(
                            identifier: 'quality-pass-${row['id']}',
                            child: ChoiceChip(
                              label: Text(_t(context, 'ناجح', 'Passed')),
                              selected: answers[row['id']] == true,
                              onSelected: locked || data?['can_submit'] != true
                                  ? null
                                  : (_) => setState(() {
                                      answers[row['id'] as String] = true;
                                    }),
                            ),
                          ),
                          Semantics(
                            identifier: 'quality-fail-${row['id']}',
                            child: ChoiceChip(
                              label: Text(
                                _t(context, 'يحتاج معالجة', 'Needs correction'),
                              ),
                              selected: answers[row['id']] == false,
                              onSelected: locked || data?['can_submit'] != true
                                  ? null
                                  : (_) => setState(() {
                                      answers[row['id'] as String] = false;
                                    }),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (data?['required'] == true)
              TextField(
                controller: note,
                enabled: !locked && data?['can_submit'] == true,
                maxLength: 1000,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: _t(context, 'ملاحظات الفحص', 'Inspection notes'),
                ),
              ),
            if (data?['can_submit'] == true)
              FilledButton(
                onPressed:
                    busy ||
                        (pending == null &&
                            rows.any((v) => answers[v['id']] == null))
                    ? null
                    : submit,
                child: Text(
                  pending != null
                      ? _t(
                          context,
                          'إعادة نفس طلب الفحص',
                          'Retry same inspection request',
                        )
                      : _t(
                          context,
                          'تسجيل نتيجة الفحص',
                          'Record inspection result',
                        ),
                ),
              ),
            if (data != null) ...[
              const Divider(),
              Text(
                _t(context, 'سجل الفحوص الأخير', 'Recent inspection history'),
              ),
              for (final c in data!['checks'] as List)
                ListTile(
                  title: Text(
                    c['passed'] == true
                        ? _t(context, 'ناجح', 'Passed')
                        : _t(context, 'يحتاج معالجة', 'Needs correction'),
                  ),
                  subtitle: Text(
                    '${c['note'] ?? ''}\n${c['current_crew'] == true ? _t(context, 'الطاقم الحالي', 'Current crew') : _t(context, 'طاقم سابق؛ يلزم فحص جديد', 'Previous crew; new inspection required')}',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Owner-only policy editor. Both languages required; changes affect future starts.
class ServiceQualityPolicyScreen extends StatefulWidget {
  const ServiceQualityPolicyScreen({
    super.key,
    required this.branch,
    required this.gateway,
  });
  final String branch;
  final ServiceQualityGateway gateway;
  @override
  State<ServiceQualityPolicyScreen> createState() =>
      _ServiceQualityPolicyScreenState();
}

class _ServiceQualityPolicyScreenState
    extends State<ServiceQualityPolicyScreen> {
  final ar = TextEditingController(),
      en = TextEditingController(),
      reason = TextEditingController();
  Map<String, dynamic>? data, pending;
  bool busy = true, failed = false, enabled = false, versionConflict = false;
  int epoch = 0;
  StreamSubscription<AuthState>? auth;
  void watch() {
    auth?.cancel();
    final gateway = widget.gateway;
    if (gateway is SupabaseServiceQualityGateway) {
      auth = gateway.client.auth.onAuthStateChange.listen((_) {
        if (!gateway.valid && mounted) {
          epoch++;
          setState(() {
            data = null;
            pending = null;
            busy = false;
            failed = true;
          });
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    watch();
    unawaited(load());
  }

  @override
  void dispose() {
    auth?.cancel();
    epoch++;
    ar.dispose();
    en.dispose();
    reason.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ServiceQualityPolicyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branch != widget.branch ||
        oldWidget.gateway != widget.gateway) {
      watch();
      epoch++;
      data = null;
      pending = null;
      ar.clear();
      en.clear();
      reason.clear();
      unawaited(load());
    }
  }

  Future<void> load() async {
    final scope = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      versionConflict = false;
      data = null;
    });
    try {
      final value = await widget.gateway.call('get_service_quality_policy', {
        'p_branch': widget.branch,
      });
      if (value['version'] is! int ||
          value['enabled'] is! bool ||
          value['items'] is! List ||
          value['future_starts_only'] != true) {
        throw const FormatException('Policy');
      }
      final rows = List<Map>.from(value['items'] as List);
      if (rows.length > 30 ||
          rows.any((v) => v['ar'] is! String || v['en'] is! String)) {
        throw const FormatException('Policy items');
      }
      if (!mounted || scope != epoch) return;
      ar.text = rows.map((v) => v['ar']).join('\n');
      en.text = rows.map((v) => v['en']).join('\n');
      setState(() {
        data = value;
        enabled = value['enabled'] as bool;
        busy = false;
      });
    } catch (_) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          failed = true;
        });
      }
    }
  }

  Future<void> save() async {
    if (busy || data == null) return;
    if (pending == null) {
      final aa = ar.text.trim().isEmpty
          ? <String>[]
          : ar.text.trim().split('\n').map((v) => v.trim()).toList();
      final ee = en.text.trim().isEmpty
          ? <String>[]
          : en.text.trim().split('\n').map((v) => v.trim()).toList();
      if (aa.length != ee.length ||
          aa.length > 30 ||
          (enabled && aa.isEmpty) ||
          [...aa, ...ee].any((v) => v.isEmpty || v.length > 200) ||
          reason.text.trim().length < 5) {
        setState(() {
          failed = true;
        });
        return;
      }
      pending = {
        'p_request': newOrderRequestId(),
        'p_branch': widget.branch,
        'p_expected_version': data!['version'],
        'p_enabled': enabled,
        'p_items': [
          for (var i = 0; i < aa.length; i++)
            {'id': 'item_${i + 1}', 'ar': aa[i], 'en': ee[i]},
        ],
        'p_reason': reason.text.trim(),
      };
    }
    final scope = epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final result = await widget.gateway.call(
        'save_service_quality_policy',
        jsonDecode(jsonEncode(pending)) as Map<String, dynamic>,
      );
      if (result['request_id'] != pending!['p_request'] ||
          result['version'] != (pending!['p_expected_version'] as int) + 1) {
        throw const FormatException('Policy receipt');
      }
      if (!mounted || scope != epoch) return;
      pending = null;
      reason.clear();
      await load();
    } catch (error) {
      if (mounted && scope == epoch) {
        setState(() {
          busy = false;
          failed = true;
          versionConflict =
              error is PostgrestException && error.code == '40001';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = busy || pending != null || data == null;
    return PopScope(
      canPop: pending == null && !busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _t(context, 'سياسة فحص الجودة', 'Quality checklist policy'),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              _t(
                context,
                'للمالك فقط. تطبق النسخة الجديدة على الخدمات التي تبدأ لاحقًا؛ لا تغير شروط الزيارات السابقة.',
                'Owner only. New versions apply to later service starts and never change earlier visit requirements.',
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (failed)
              Text(
                _t(
                  context,
                  'تعذر الحفظ أو البيانات غير مكتملة. طابق البنود العربية والإنجليزية واذكر سببًا. الطلب المعلق يُعاد كما هو.',
                  'Could not save or input is incomplete. Match Arabic and English items and provide a reason. Pending requests retry unchanged.',
                ),
              ),
            if (versionConflict && pending != null)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () {
                        pending = null;
                        reason.clear();
                        unawaited(load());
                      },
                child: Text(
                  _t(
                    context,
                    'تجاهل الطلب المرفوض وتحميل النسخة الحالية',
                    'Discard rejected request and load current version',
                  ),
                ),
              ),
            if (data == null && !busy)
              OutlinedButton(
                onPressed: load,
                child: Text(_t(context, 'إعادة التحميل', 'Reload')),
              ),
            if (data != null)
              Text('${_t(context, 'الإصدار', 'Version')}: ${data!['version']}'),
            SwitchListTile(
              title: Text(
                _t(
                  context,
                  'إلزام الفحص للخدمات الجديدة',
                  'Require checklist for new starts',
                ),
              ),
              value: enabled,
              onChanged: lock
                  ? null
                  : (v) => setState(() {
                      enabled = v;
                    }),
            ),
            TextField(
              controller: ar,
              enabled: !lock,
              maxLines: 8,
              maxLength: 6030,
              decoration: InputDecoration(
                labelText: _t(
                  context,
                  'البنود العربية؛ بند في كل سطر',
                  'Arabic items; one per line',
                ),
              ),
            ),
            TextField(
              controller: en,
              enabled: !lock,
              maxLines: 8,
              maxLength: 6030,
              decoration: InputDecoration(
                labelText: _t(
                  context,
                  'البنود الإنجليزية بنفس الترتيب',
                  'English items in matching order',
                ),
              ),
            ),
            TextField(
              controller: reason,
              enabled: !lock,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: _t(context, 'سبب التغيير', 'Reason for change'),
              ),
            ),
            FilledButton(
              onPressed: busy || data == null ? null : save,
              child: Text(
                pending == null
                    ? _t(context, 'حفظ نسخة جديدة', 'Save new version')
                    : _t(
                        context,
                        'إعادة نفس طلب الحفظ',
                        'Retry same save request',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
