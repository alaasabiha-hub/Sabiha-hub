import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_points_policy.dart' show OwnerPointsGateway;
import 'invoice_presentation.dart' show invoiceDate;
import 'workflow.dart' show newOrderRequestId;

/// Owner-only permission/review controls. Never activates the runtime program.
class OwnerPointsOperationsPanel extends StatefulWidget {
  const OwnerPointsOperationsPanel({
    super.key,
    required this.gateway,
    required this.branch,
  });
  final OwnerPointsGateway gateway;
  final String branch;
  @override
  State<OwnerPointsOperationsPanel> createState() =>
      _OwnerPointsOperationsPanelState();
}

class _OwnerPointsOperationsPanelState
    extends State<OwnerPointsOperationsPanel> {
  final reason = TextEditingController();
  final reviewReasons = <String, TextEditingController>{};
  final decisions = <String, String>{};
  final entries = <Map<String, dynamic>>[];
  StreamSubscription<void>? subscription;
  Map<String, dynamic>? data, pending;
  bool busy = false, invalid = false, allowed = false;
  String? error;
  int epoch = 0, scope = 0;
  bool get active => mounted && !invalid && widget.gateway.current;
  bool get editable => active && !busy && pending == null;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    connect();
    unawaited(load());
  }

  void connect() {
    final generation = ++scope;
    subscription = widget.gateway.changes.listen((_) {
      if (mounted && generation == scope) {
        setState(() {
          invalid = true;
          epoch++;
          data = pending = null;
          entries.clear();
          reason.clear();
          for (final c in reviewReasons.values) {
            c.clear();
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant OwnerPointsOperationsPanel old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway || old.branch != widget.branch) {
      epoch++;
      scope++;
      unawaited(subscription?.cancel());
      invalid = false;
      data = pending = null;
      entries.clear();
      decisions.clear();
      reason.clear();
      error = null;
      for (final c in reviewReasons.values) {
        c.clear();
      }
      connect();
      unawaited(load());
    }
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    reason.dispose();
    for (final c in reviewReasons.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (!active) return;
    final generation = ++epoch;
    setState(() => busy = true);
    try {
      final result = await widget.gateway.call(
        'get_owner_mixed_points_operations',
        {
          'p_branch': widget.branch,
          if (more && entries.isNotEmpty) ...{
            'p_before_time': entries.last['created_at'],
            'p_before_lot': entries.last['lot_id'],
          },
        },
      );
      if (!active || generation != epoch) return;
      if (result['activation_supported'] != false ||
          result['verbal_policy'] is! Map ||
          result['reviews'] is! List) {
        throw const FormatException('Invalid owner operations scope');
      }
      data = result;
      allowed = (result['verbal_policy'] as Map)['allowed'] == true;
      if (!more) entries.clear();
      for (final row in List<Map<String, dynamic>>.from(
        result['reviews'] as List,
      )) {
        if (!entries.any((x) => x['lot_id'] == row['lot_id'])) entries.add(row);
        reviewReasons.putIfAbsent(
          row['lot_id'] as String,
          TextEditingController.new,
        );
      }
    } catch (e) {
      if (active && generation == epoch) {
        if (e is PostgrestException && e.code == 'PGRST202') {
          data = null;
        } else {
          error = t(
            'تعذر تحميل إعدادات الولاء والمراجعات.',
            'Unable to load loyalty permissions and reviews.',
          );
        }
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> save([Map<String, dynamic>? row]) async {
    if (!active || busy) return;
    final generation = epoch;
    if (pending == null) {
      final why =
          (row == null ? reason.text : reviewReasons[row['lot_id']]!.text)
              .trim();
      if (why.length < 5 ||
          why.length > 500 ||
          (row != null && !decisions.containsKey(row['lot_id']))) {
        setState(
          () => error = t(
            'اختر القرار وأدخل سببًا واضحًا.',
            'Choose the decision and enter a clear reason.',
          ),
        );
        return;
      }
      pending = {
        'name': row == null
            ? 'save_owner_mixed_points_verbal_policy'
            : 'decide_owner_mixed_points_refund_review',
        'params': {
          'p_request': newOrderRequestId(),
          'p_reason': why,
          if (row == null) ...{
            'p_branch': widget.branch,
            'p_expected_version': (data!['verbal_policy'] as Map)['version'],
            'p_allowed': allowed,
          } else ...{
            'p_lot': row['lot_id'],
            'p_decision': decisions[row['lot_id']],
          },
        },
      };
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final command = pending!;
      final result = await widget.gateway.call(
        command['name'] as String,
        Map<String, dynamic>.from(command['params'] as Map),
      );
      if (!active || generation != epoch) return;
      final params = command['params'] as Map;
      if (command['name'] == 'save_owner_mixed_points_verbal_policy') {
        if (result['version'] != (params['p_expected_version'] as int) + 1 ||
            result['allowed'] != params['p_allowed']) {
          throw const FormatException('Unverified policy save');
        }
      } else if (result['lot'] != params['p_lot'] ||
          result['decision'] != params['p_decision']) {
        throw const FormatException('Unverified review decision');
      }
      pending = null;
      reason.clear();
      await load();
    } catch (e) {
      if (active && generation == epoch) {
        error = t(
          'لم يكتمل الحفظ. عند انقطاع الاتصال أعد نفس الطلب؛ لا تغير القرار قبل التأكد.',
          'Save did not complete. After connection loss retry the same request; do not change the decision until confirmed.',
        );
        if (e is PostgrestException) pending = null;
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (invalid || !widget.gateway.current) return const SizedBox.shrink();
    return ExpansionTile(
      title: Text(
        t(
          'موافقة الكاشير ومراجعات نقاط الاسترداد',
          'Cashier approval and refund point reviews',
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
              if (data != null) ...[
                Text(
                  t(
                    'حفظ الإذن لا يفعّل برنامج النقاط أو الصرف العام.',
                    'Saving permission does not activate points earning or redemption.',
                  ),
                ),
                Text(
                  '${t('حالة الصرف العام', 'Redemption runtime')}: ${data!['redemption_runtime_enabled'] == true ? t('مفعّل', 'Enabled') : t('غير مفعّل', 'Disabled')}',
                ),
                CheckboxListTile(
                  key: const ValueKey('owner_verbal_allowed'),
                  value: allowed,
                  title: Text(
                    t(
                      'السماح للكاشير بالموافقة الشفهية بعد التحقق المستقل من الهوية',
                      'Allow cashier verbal approval after independent identity verification',
                    ),
                  ),
                  onChanged: editable
                      ? (v) => setState(() => allowed = v == true)
                      : null,
                ),
                TextField(
                  key: const ValueKey('owner_verbal_reason'),
                  controller: reason,
                  enabled: editable,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: t(
                      'سبب تعديل الإذن',
                      'Reason for permission change',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: editable ? () => save() : null,
                  child: Text(
                    t(
                      'حفظ إذن الموافقة الشفهية',
                      'Save verbal approval permission',
                    ),
                  ),
                ),
                if (entries.isEmpty)
                  Text(
                    t(
                      'لا توجد مراجعات نقاط مسجلة.',
                      'No point reviews are recorded.',
                    ),
                  ),
                for (final row in entries)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${row['invoice_number']} · ${row['points']} ${t('نقطة', 'points')}',
                          ),
                          Text(
                            invoiceDate({'issued_at': row['created_at']}, ar),
                          ),
                          Text(
                            '${t('المبلغ المسترد فعليًا', 'Actual refund')}: ${row['refund_amount']} EGP',
                          ),
                          if (row['decision'] != null)
                            Text(
                              '${row['decision'] == 'preserve_rights' ? t('أبقيت النقاط بعد المراجعة', 'Points preserved after review') : t('سويت مساهمة الخدمة المستردة', 'Refunded contribution offset')} · ${row['decision_reason']}',
                            )
                          else ...[
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'owner_points_decision_${row['lot_id']}',
                              ),
                              isExpanded: true,
                              initialValue: decisions[row['lot_id']],
                              decoration: InputDecoration(
                                labelText: t(
                                  'قرار المالك بعد المراجعة',
                                  'Owner decision after review',
                                ),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'preserve_rights',
                                  child: Text(
                                    t('الإبقاء على النقاط', 'Preserve points'),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'offset_points',
                                  child: Text(
                                    t(
                                      'تسوية نقاط المساهمة المستردة',
                                      'Offset refunded contribution points',
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: editable
                                  ? (v) => setState(() {
                                      if (v != null) {
                                        decisions[row['lot_id'] as String] = v;
                                      }
                                    })
                                  : null,
                            ),
                            TextField(
                              key: ValueKey(
                                'owner_points_reason_${row['lot_id']}',
                              ),
                              controller: reviewReasons[row['lot_id']],
                              enabled: editable,
                              maxLength: 500,
                              decoration: InputDecoration(
                                labelText: t(
                                  'سبب القرار وأساس التحقق',
                                  'Decision reason and verification basis',
                                ),
                              ),
                            ),
                            FilledButton(
                              onPressed: editable ? () => save(row) : null,
                              child: Text(
                                t(
                                  'تسجيل قرار المراجعة',
                                  'Record review decision',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (data!['has_more'] == true)
                  OutlinedButton(
                    onPressed: editable ? () => load(more: true) : null,
                    child: Text(
                      t('عرض المزيد من المراجعات', 'Load more reviews'),
                    ),
                  ),
              ],
              if (pending != null)
                FilledButton(
                  onPressed: busy ? null : () => save(),
                  child: Text(
                    t('إعادة نفس طلب المالك', 'Retry the same owner request'),
                  ),
                ),
              OutlinedButton(
                onPressed: editable ? () => load() : null,
                child: Text(t('تحديث المراجعات', 'Refresh reviews')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
