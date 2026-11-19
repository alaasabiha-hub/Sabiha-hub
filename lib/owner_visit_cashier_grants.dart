import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

abstract class VisitCashierGrantGateway {
  bool get current;
  Future<Map<String, dynamic>> read(String branch, String rules);
  Future<Map<String, dynamic>> save(Map<String, dynamic> args);
}

class SupabaseVisitCashierGrantGateway implements VisitCashierGrantGateway {
  SupabaseVisitCashierGrantGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  @override
  bool get current => actor != null && client.auth.currentUser?.id == actor;
  void check() {
    if (!current) throw StateError('Account changed');
  }

  @override
  Future<Map<String, dynamic>> read(String branch, String rules) async {
    check();
    final data = Map<String, dynamic>.from(
      await client.rpc(
        'get_owner_visit_cashier_grants',
        params: {'p_branch': branch, 'p_rules': rules},
      ),
    );
    check();
    return data;
  }

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> args) async {
    check();
    final data = Map<String, dynamic>.from(
      await client.rpc('save_owner_visit_cashier_grant', params: args),
    );
    check();
    return data;
  }
}

class OwnerVisitCashierGrantsPanel extends StatefulWidget {
  const OwnerVisitCashierGrantsPanel({
    super.key,
    this.client,
    this.gateway,
    required this.branch,
    required this.rules,
  }) : assert(client != null || gateway != null);
  final SupabaseClient? client;
  final VisitCashierGrantGateway? gateway;
  final String branch, rules;
  @override
  State<OwnerVisitCashierGrantsPanel> createState() => _GrantsState();
}

class _GrantsState extends State<OwnerVisitCashierGrantsPanel> {
  late VisitCashierGrantGateway gateway;
  StreamSubscription<AuthState>? auth;
  List<Map<String, dynamic>> staff = [];
  String? selected, error, notice;
  bool allowed = false, busy = false;
  final reason = TextEditingController();
  int epoch = 0;
  Map<String, dynamic>? pending;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  bool get current => mounted && gateway.current;
  @override
  void initState() {
    super.initState();
    bind();
  }

  void bind() {
    gateway =
        widget.gateway ?? SupabaseVisitCashierGrantGateway(widget.client!);
    auth = widget.client?.auth.onAuthStateChange.listen((_) {
      if (!gateway.current && mounted) {
        epoch++;
        setState(() {
          staff = [];
          selected = null;
          pending = null;
          reason.clear();
          error = null;
          notice = null;
          busy = false;
        });
      }
    });
    load();
  }

  @override
  void didUpdateWidget(covariant OwnerVisitCashierGrantsPanel old) {
    super.didUpdateWidget(old);
    if (old.branch != widget.branch ||
        old.rules != widget.rules ||
        old.gateway != widget.gateway ||
        old.client != widget.client) {
      epoch++;
      auth?.cancel();
      staff = [];
      selected = null;
      pending = null;
      allowed = false;
      reason.clear();
      error = null;
      notice = null;
      busy = false;
      bind();
    }
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    reason.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await gateway.read(widget.branch, widget.rules);
      if (!current || generation != epoch) return;
      setState(() {
        staff = [
          for (final x in (data['staff'] as List? ?? []))
            Map<String, dynamic>.from(x as Map),
        ];
        selected = null;
        allowed = false;
        pending = null;
        reason.clear();
      });
    } catch (_) {
      if (current && generation == epoch) {
        setState(
          () =>
              error = t('تعذر تحميل التفويضات.', 'Could not load delegations.'),
        );
      }
    } finally {
      if (current && generation == epoch) setState(() => busy = false);
    }
  }

  Map<String, dynamic>? get entry {
    for (final x in staff) {
      if (x['staff_id'] == selected) return x;
    }
    return null;
  }

  Future<void> save() async {
    if (!current || busy || entry == null) return;
    final row = entry!;
    if (pending == null) {
      if (reason.text.trim().length < 10) {
        setState(
          () => error = t(
            'اكتب سببًا لا يقل عن 10 أحرف.',
            'Enter a reason of at least 10 characters.',
          ),
        );
        return;
      }
      pending = {
        'p_request': newOrderRequestId(),
        'p_branch': widget.branch,
        'p_rules': widget.rules,
        'p_staff': selected,
        'p_expected_version': row['version_no'],
        'p_allowed': allowed,
        'p_reason': reason.text.trim(),
      };
    }
    final command = Map<String, dynamic>.from(pending!);
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await gateway.save(command);
      if (!current || generation != epoch) return;
      if (result['version_id'] != command['p_request'] ||
          result['redemption_activated'] != false ||
          result['prior_invoices_changed'] != false) {
        throw const FormatException('Unconfirmed delegation');
      }
      pending = null;
      await load();
      if (current && epoch == generation + 1) {
        setState(
          () => notice = t(
            'تم حفظ التفويض دون تفعيل الصرف العام.',
            'Delegation saved without enabling public redemption.',
          ),
        );
      }
    } catch (_) {
      if (current && generation == epoch) {
        setState(
          () => error = t(
            'الحفظ غير مؤكد؛ أعد نفس الطلب أو حدّث قبل التعديل.',
            'Save is unconfirmed; retry the same request or refresh before editing.',
          ),
        );
      }
    } finally {
      if (current && generation == epoch) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = current && !busy && pending == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(
                'تفويض الكاشير لمكافآت الزيارات',
                'Cashier visit-reward delegation',
              ),
              style: const TextStyle(
                color: Color(0xff071a36),
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            Text(
              t(
                'التفويض محدد للموظف والفرع وقاعدة المكافأة، ولا يفعّل الصرف العام.',
                'Delegation applies to this employee, branch and reward rule. It does not enable public redemption.',
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (!current)
              Text(
                t(
                  'تغيّر الحساب. أعد فتح الشاشة.',
                  'Account changed. Reopen this screen.',
                ),
              ),
            if (error != null) Text(error!),
            if (notice != null) Text(notice!),
            OutlinedButton(
              onPressed: current && !busy ? load : null,
              child: Text(t('تحديث التفويضات', 'Refresh delegations')),
            ),
            if (current && staff.isEmpty && !busy)
              Text(
                t(
                  'لا يوجد كاشير مؤهل لهذا الفرع.',
                  'No eligible cashier for this branch.',
                ),
              ),
            if (current && staff.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('grant-staff-$epoch'),
                initialValue: selected,
                isExpanded: true,
                decoration: InputDecoration(labelText: t('الكاشير', 'Cashier')),
                items: [
                  for (final x in staff)
                    DropdownMenuItem(
                      value: x['staff_id'] as String,
                      child: Text(x['name'] as String? ?? ''),
                    ),
                ],
                onChanged: editable
                    ? (value) => setState(() {
                        selected = value;
                        allowed = entry?['allowed'] == true;
                        error = null;
                        notice = null;
                      })
                    : null,
              ),
              if (entry != null) ...[
                Text(
                  '${t('إصدار التفويض', 'Delegation version')}: ${entry!['version_no']}',
                ),
                if (entry!['eligible'] != true)
                  Text(
                    t(
                      'الموظف غير مؤهل حاليًا؛ يمكن سحب التفويض فقط.',
                      'Employee is currently ineligible; delegation can only be revoked.',
                    ),
                  ),
                SwitchListTile(
                  title: Text(t('السماح لهذا الكاشير', 'Allow this cashier')),
                  value: allowed,
                  onChanged: editable
                      ? (value) {
                          if (!value || entry!['eligible'] == true) {
                            setState(() => allowed = value);
                          }
                        }
                      : null,
                ),
                TextField(
                  key: const ValueKey('grant-reason'),
                  controller: reason,
                  enabled: editable,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: t(
                      'سبب تغيير التفويض',
                      'Reason for delegation change',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: current && !busy ? save : null,
                  child: Text(
                    pending == null
                        ? t('حفظ التفويض', 'Save delegation')
                        : t(
                            'إعادة نفس طلب التفويض',
                            'Retry the same delegation request',
                          ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
