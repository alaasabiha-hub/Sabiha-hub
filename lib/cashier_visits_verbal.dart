import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_invoice_draft.dart' show CashierCartGateway;
import 'current_catalog.dart' show normalizedNumericInput;
import 'workflow.dart' show newOrderRequestId;

/// A server-funded, draft-bound approval. It is never a payment confirmation.
class CashierVisitsVerbalPanel extends StatefulWidget {
  const CashierVisitsVerbalPanel({
    super.key,
    required this.gateway,
    required this.branch,
    required this.draft,
    required this.onApproval,
    required this.onBusy,
    required this.onSelectionPending,
    this.disabled = false,
  });
  final CashierCartGateway gateway;
  final String branch, draft;
  final ValueChanged<Map<String, dynamic>?> onApproval;
  final ValueChanged<bool> onBusy, onSelectionPending;
  final bool disabled;
  @override
  State<CashierVisitsVerbalPanel> createState() =>
      _CashierVisitsVerbalPanelState();
}

class _CashierVisitsVerbalPanelState extends State<CashierVisitsVerbalPanel> {
  final units = TextEditingController(text: '1'),
      evidence = TextEditingController();
  Map<String, dynamic>? data, hold, approved, command;
  String? policy, document, method, error;
  bool busy = false, identityChecked = false, verbalChecked = false;
  bool invalid = false;
  StreamSubscription<void>? changes;
  int epoch = 0;
  String? seal;
  String sealRequest = newOrderRequestId();
  String optionKey(Map row) =>
      '${row["rules_id"]}|${row["channel_id"]}|${row["line_id"]}';
  bool get current => mounted && !invalid && widget.gateway.current;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String money(dynamic value) => value is num ? value.toStringAsFixed(2) : '—';
  List<Map<String, dynamic>> rows(String key) =>
      List<Map<String, dynamic>>.from(data?[key] as List? ?? []);
  void clearScope() {
    epoch++;
    data = hold = approved = command = null;
    policy = document = method = seal = error = null;
    evidence.clear();
    units.text = '1';
    identityChecked = verbalChecked = busy = false;
    sealRequest = newOrderRequestId();
  }

  void listenScope() {
    changes = widget.gateway.changes.listen((_) {
      if (mounted) {
        setState(() {
          clearScope();
          invalid = true;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    listenScope();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant CashierVisitsVerbalPanel old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway ||
        old.branch != widget.branch ||
        old.draft != widget.draft) {
      changes?.cancel();
      clearScope();
      invalid = false;
      listenScope();
      unawaited(load());
    }
  }

  @override
  void dispose() {
    epoch++;
    changes?.cancel();
    units.dispose();
    evidence.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++epoch;
    try {
      final result = await widget.gateway.call(
        'get_cashier_mixed_visits_context',
        {'p_branch': widget.branch, 'p_draft': widget.draft},
      );
      if (!current || generation != epoch) return;
      setState(() {
        data = result;
        hold = result['hold'] is Map
            ? Map<String, dynamic>.from(result['hold'] as Map)
            : null;
        approved = result['approval'] is Map
            ? Map<String, dynamic>.from(result['approval'] as Map)
            : null;
        if (!rows('options').any((row) => optionKey(row) == policy)) {
          policy = null;
        }
        if (!rows('documents').any((row) => row['invoice_id'] == document)) {
          document = null;
        }
        if (hold == null) {
          approved = null;
          identityChecked = verbalChecked = false;
        }
      });
      widget.onApproval(approved);
      widget.onSelectionPending(hold != null && approved == null);
    } catch (e) {
      if (!current || generation != epoch) return;
      if (e is PostgrestException && e.code == 'PGRST202') return;
      setState(
        () => error = t(
          'تعذر التحقق من الولاء.',
          'Loyalty could not be verified.',
        ),
      );
    }
  }

  Future<void> act(String kind) async {
    if (!current || busy || widget.disabled) return;
    final generation = epoch;
    setState(() {
      busy = true;
      error = null;
    });
    widget.onBusy(true);
    try {
      if (command == null) {
        if (kind == 'reserve') {
          final normalized = normalizedNumericInput(units.text.trim());
          if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(normalized) ||
              policy == null ||
              data?['redemption_enabled'] != true) {
            throw const FormatException('Exact eligible visit units required');
          }
          final choice = rows('options')
              .singleWhere((row) => optionKey(row) == policy);
          if (data?['intent_id'] is String) {
            seal = data!['intent_id'] as String;
          } else {
            final result = await widget.gateway.call(
              'seal_cashier_loyalty_draft',
              {
                'p_request': sealRequest,
                'p_branch': widget.branch,
                'p_draft': widget.draft,
                'p_expected_draft_version': data!['draft_version'],
                'p_expected_binding_version': data!['binding_version'],
              },
            );
            if (!current || generation != epoch) return;
            if (result['intent_id'] != sealRequest ||
                result['seal_only'] != true) {
              throw const FormatException('Unverified seal');
            }
            seal = result['intent_id'] as String;
          }
          command = {
            'kind': kind,
            'name': 'reserve_cashier_mixed_visits',
            'params': {
              'p_request': newOrderRequestId(),
              'p_branch': widget.branch,
              'p_intent': seal,
              'p_rules': choice['rules_id'],
              'p_channel': choice['channel_id'],
              'p_policy': choice['policy_id'],
              'p_line': choice['line_id'],
              'p_units': normalized,
            },
          };
        } else if (kind == 'approve') {
          if (hold == null ||
              !identityChecked ||
              !verbalChecked ||
              data?['redemption_enabled'] != true ||
              hold?['reservation_live'] != true ||
              document == null ||
              method == null ||
              evidence.text.trim().length < 10) {
            throw const FormatException(
              'Independent identity and explicit assent required',
            );
          }
          command = {
            'kind': kind,
            'name': 'confirm_cashier_mixed_visits_verbal',
            'params': {
              'p_request': newOrderRequestId(),
              'p_branch': widget.branch,
              'p_group': hold!['group_id'],
              'p_fingerprint': hold!['fingerprint'],
              'p_identity_method': method,
              'p_identity_invoice': document,
              'p_note': evidence.text.trim(),
              'p_language': ar ? 'ar' : 'en',
              'p_notice': hold![ar ? 'verbal_notice_ar' : 'verbal_notice_en'],
              'p_identity_verified': true,
              'p_verbal_confirmed': true,
            },
          };
        } else if (kind == 'release') {
          if (hold == null) return;
          command = {
            'kind': kind,
            'name': 'release_cashier_mixed_visits',
            'params': {
              'p_request': newOrderRequestId(),
              'p_branch': widget.branch,
              'p_group': hold!['group_id'],
              'p_reason': t(
                'تحرير حجز مكافأة الزيارات قبل إصدار الفاتورة بناءً على طلب العميل',
                'Cashier releases unissued visit reward selection at customer request',
              ),
            },
          };
        }
      }
      final pending = command!;
      widget.onSelectionPending(true);
      final result = await widget.gateway.call(
        pending['name'] as String,
        Map<String, dynamic>.from(pending['params'] as Map),
      );
      if (!current || generation != epoch) return;
      if (pending['kind'] == 'reserve') {
        if (result['balance_reserved'] != true ||
            result['payment_confirmed'] != false ||
            result['group_id'] != (pending['params'] as Map)['p_request'] ||
            result['fingerprint'] is! String ||
            result['quote'] is! Map ||
            result['verbal_notice_ar'] is! String ||
            result['verbal_notice_en'] is! String) {
          throw const FormatException('Unverified hold');
        }
        hold = result;
        widget.onSelectionPending(true);
      } else if (pending['kind'] == 'approve') {
        if (result['accepted'] != true ||
            result['payment_confirmed'] != false ||
            result['approval_method'] != 'cashier_attested_verbal' ||
            result['consent_id'] != (pending['params'] as Map)['p_request']) {
          throw const FormatException('Unverified verbal approval');
        }
        approved = {
          'group_id': hold!['group_id'],
          'consent_id': result['consent_id'],
        };
        widget.onApproval(Map.unmodifiable(approved!));
        widget.onSelectionPending(false);
      } else {
        if (result['released'] != true) {
          throw const FormatException('Unverified release');
        }
        hold = approved = null;
        policy = null;
        units.text = '1';
        seal = null;
        sealRequest = newOrderRequestId();
        identityChecked = verbalChecked = false;
        evidence.clear();
        document = method = null;
        widget.onApproval(null);
        widget.onSelectionPending(false);
      }
      command = null;
    } catch (e) {
      if (current && generation == epoch) {
        error = t(
          'لم يكتمل التأكيد. راجع الهوية والسياسة والرصيد. عند انقطاع الاتصال أعد محاولة نفس الطلب.',
          'Confirmation did not complete. Check identity, policy and visits. After a connection failure retry the same request.',
        );
        if (e is PostgrestException || e is FormatException) command = null;
        widget.onSelectionPending(
          command != null || hold != null && approved == null,
        );
      }
    } finally {
      if (current && generation == epoch) {
        setState(() => busy = false);
        widget.onBusy(false);
        if (command == null) unawaited(load());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (invalid || data?['enabled'] != true) return const SizedBox.shrink();
    final usable = !busy && !widget.disabled && command == null;
    final quote = hold?['quote'] is Map
        ? Map<String, dynamic>.from(hold!['quote'] as Map)
        : null;
    return Card(
      color: const Color(0xfff5f7fa),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('مكافآت الزيارات', 'Visit rewards'),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xff071a36),
              ),
            ),
            Text(
              t(
                'الهاتف وحده لا يثبت الهوية. الموافقة شفهية عند الكاشير؛ لا يلزم تطبيق أو رمز.',
                'A phone alone does not verify identity. Approval is verbal at the cashier; no app or code is required.',
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (data?['redemption_enabled'] != true)
              Text(
                t(
                  'الاستبدال معطل؛ يمكن تحرير الحجز السابق فقط.',
                  'Redemption is disabled; an earlier hold can only be released.',
                ),
              ),
            OutlinedButton(
              onPressed: usable ? load : null,
              child: Text(t('تحديث مكافآت الزيارات', 'Refresh visit rewards')),
            ),
            if (error != null) Text(error!),
            if (command != null)
              OutlinedButton(
                onPressed: busy ? null : () => act(command!['kind'] as String),
                child: Text(
                  t('إعادة محاولة نفس الطلب', 'Retry the same request'),
                ),
              ),
            if (data?['seal_expired'] == true && hold == null)
              Text(
                t(
                  'انتهت صلاحية المراجعة. أعد حفظ المسودة وتأكيد السيارة قبل استبدال الزيارات.',
                  'Review expired. Save a new draft version and confirm the car before redeeming visits.',
                ),
              ),
            if (data?['state'] != 'ready')
              Text(
                t(
                  'لا توجد زيارات مؤهلة أو يلزم ربط السيارة أو مراجعة المالك.',
                  'No eligible visits are available, or vehicle binding or owner review is required.',
                ),
              ),
            if (hold == null &&
                data?['state'] == 'ready' &&
                data?['redemption_enabled'] == true) ...[
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: policy,
                decoration: InputDecoration(
                  labelText: t(
                    'رصيد بشروطه الأصلية',
                    'Balance at original terms',
                  ),
                ),
                items: [
                  for (final b in rows('options'))
                    DropdownMenuItem(
                      value: optionKey(b),
                      child: Text(
                        '${ar ? b['name'] : b['name_en'] ?? b['name']} · ${b['available_visits']} ${t('زيارة', 'visits')} · ${t('حتى', 'up to')} ${b['maximum_units']}',
                      ),
                    ),
                ],
                onChanged: usable ? (v) => setState(() => policy = v) : null,
              ),
              TextField(
                key: const ValueKey('visits_quantity'),
                controller: units,
                enabled: usable,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t(
                    'عدد وحدات الخدمة المجانية',
                    'Free service units',
                  ),
                ),
              ),
              OutlinedButton(
                onPressed:
                    usable &&
                        data?['seal_expired'] != true &&
                        data?['redemption_enabled'] == true
                    ? () => act('reserve')
                    : null,
                child: Text(
                  t(
                    'حجز الزيارات ومعاينة السعر',
                    'Reserve visits and preview price',
                  ),
                ),
              ),
            ],
            if (hold != null && quote == null) ...[
              Text(
                data?['state'] == 'delegation_revoked_release_required'
                    ? t(
                        'تم سحب التفويض أو تغييره. حرّر الحجز السابق قبل المتابعة.',
                        'Delegation was revoked or changed. Release the earlier hold before continuing.',
                      )
                    : t(
                        'يوجد حجز مكافأة لنسخة سابقة. حرّره قبل متابعة المسودة الحالية.',
                        'A reward hold belongs to an earlier draft version. Release it before continuing.',
                      ),
              ),
              OutlinedButton(
                key: const ValueKey('visits_release_stale'),
                onPressed: usable ? () => act('release') : null,
                child: Text(t('تحرير الحجز السابق', 'Release earlier hold')),
              ),
            ],
            if (hold != null && quote != null) ...[
              Text('${t('الزيارات', 'Visits')}: ${hold!['required_visits']}'),
              Text(
                '${t('خصم مكافأة الزيارات', 'Visit reward discount')}: ${money((quote['visit_reward'] as Map?)?['payable_reduction'])} EGP',
              ),
              Text(
                '${t('الإجمالي النهائي', 'Final total')}: ${money(quote['total'])} EGP',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (approved == null) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const ValueKey('visits_identity_method'),
                  initialValue: method,
                  decoration: InputDecoration(
                    labelText: t(
                      'التحقق المستقل من الهوية',
                      'Independent identity verification',
                    ),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'original_service_document_and_vehicle',
                      child: Text(
                        t(
                          'وثيقة خدمة أصلية ومطابقة السيارة',
                          'Original service document and matching car',
                        ),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'in_person_identity_and_registered_vehicle',
                      child: Text(
                        t(
                          'إثبات الهوية حضوريًا والسيارة المسجلة',
                          'In-person identity and registered vehicle',
                        ),
                      ),
                    ),
                  ],
                  onChanged: usable ? (v) => setState(() => method = v) : null,
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const ValueKey('visits_identity_record'),
                  initialValue: document,
                  decoration: InputDecoration(
                    labelText: t(
                      'سجل الخدمة الأصلي',
                      'Original service record',
                    ),
                  ),
                  items: [
                    for (final doc in rows('documents'))
                      DropdownMenuItem(
                        value: doc['invoice_id'] as String,
                        child: Text('${doc['number']}'),
                      ),
                  ],
                  onChanged: usable
                      ? (v) => setState(() => document = v)
                      : null,
                ),
                TextField(
                  key: const ValueKey('visits_identity_note'),
                  controller: evidence,
                  enabled: usable,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: t(
                      'ملاحظة التحقق دون أرقام هوية أو بيانات حساسة',
                      'Verification note without identity numbers or sensitive data',
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('visits_identity_checked'),
                  value: identityChecked,
                  onChanged: usable
                      ? (v) => setState(() => identityChecked = v == true)
                      : null,
                  title: Text(
                    t(
                      'تحققت من صاحب الرصيد بوثيقة مستقلة والسيارة، وليس الهاتف وحده.',
                      'I checked the balance owner using independent documents and the car, not the phone alone.',
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('visits_verbal_checked'),
                  value: verbalChecked,
                  onChanged: usable
                      ? (v) => setState(() => verbalChecked = v == true)
                      : null,
                  title: Text(
                    t(
                      'عرضت الزيارات والخصم والإجمالي وحصلت على موافقة العميل الشفهية.',
                      'I showed the visits, discount and total and received the customer’s verbal approval.',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed:
                      usable &&
                          identityChecked &&
                          verbalChecked &&
                          data?['redemption_enabled'] == true &&
                          hold?['reservation_live'] == true
                      ? () => act('approve')
                      : null,
                  child: Text(
                    t(
                      'تأكيد موافقة العميل الشفهية',
                      'Confirm customer verbal approval',
                    ),
                  ),
                ),
              ] else
                Text(
                  t(
                    'الموافقة الشفهية خاصة بهذه الفاتورة فقط، وليست إثبات دفع.',
                    'Verbal approval applies to this invoice only; it is not proof of payment.',
                  ),
                ),
              OutlinedButton(
                onPressed: usable ? () => act('release') : null,
                child: Text(
                  t(
                    'إلغاء الاستبدال قبل إصدار الفاتورة',
                    'Cancel redemption before invoice issuance',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
