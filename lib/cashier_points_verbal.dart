import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_invoice_draft.dart' show CashierCartGateway;
import 'workflow.dart' show newOrderRequestId;

/// A server-funded, draft-bound approval. It is never a payment confirmation.
class CashierPointsVerbalPanel extends StatefulWidget {
  const CashierPointsVerbalPanel({
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
  State<CashierPointsVerbalPanel> createState() =>
      _CashierPointsVerbalPanelState();
}

class _CashierPointsVerbalPanelState extends State<CashierPointsVerbalPanel> {
  final points = TextEditingController(), evidence = TextEditingController();
  Map<String, dynamic>? data, hold, approved, command;
  String? policy, document, method, error;
  bool busy = false, identityChecked = false, verbalChecked = false;
  bool invalid = false;
  StreamSubscription<void>? changes;
  int epoch = 0;
  String? seal;
  final sealRequest = newOrderRequestId();
  bool get current => mounted && !invalid && widget.gateway.current;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String money(dynamic value) => value is num ? value.toStringAsFixed(2) : '—';
  List<Map<String, dynamic>> rows(String key) =>
      List<Map<String, dynamic>>.from(data?[key] as List? ?? []);
  @override
  void initState() {
    super.initState();
    changes = widget.gateway.changes.listen((_) {
      if (mounted) {
        setState(() {
          invalid = true;
          data = hold = approved = null;
          epoch++;
        });
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    changes?.cancel();
    points.dispose();
    evidence.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++epoch;
    try {
      final result = await widget.gateway.call(
        'get_cashier_mixed_points_context',
        {'p_branch': widget.branch, 'p_draft': widget.draft},
      );
      if (!current || generation != epoch) return;
      setState(() {
        data = result;
        if (result['hold'] is Map) {
          hold = Map<String, dynamic>.from(result['hold'] as Map);
          if (result['approval'] is Map) {
            approved = Map<String, dynamic>.from(result['approval'] as Map);
          }
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
          final normalized = points.text.trim().replaceAllMapped(
            RegExp(r'[٠-٩۰-۹]'),
            (m) {
              final c = m[0]!.runes.single;
              return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
            },
          );
          if (policy == null ||
              !RegExp(r'^[1-9][0-9]{0,8}$').hasMatch(normalized)) {
            throw const FormatException('Exact integer points required');
          }
          if (data?['seal_expired'] == true) {
            throw const FormatException(
              'Save and confirm a fresh draft version',
            );
          }
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
            'name': 'reserve_cashier_mixed_points',
            'params': {
              'p_request': newOrderRequestId(),
              'p_branch': widget.branch,
              'p_intent': seal,
              'p_earning_policy': policy,
              'p_points': normalized,
            },
          };
        } else if (kind == 'approve') {
          if (hold == null ||
              !identityChecked ||
              !verbalChecked ||
              document == null ||
              method == null ||
              evidence.text.trim().length < 10) {
            throw const FormatException(
              'Independent identity and explicit assent required',
            );
          }
          command = {
            'kind': kind,
            'name': 'confirm_cashier_mixed_points_verbal',
            'params': {
              'p_request': newOrderRequestId(),
              'p_branch': widget.branch,
              'p_reservation': hold!['reservation_id'],
              'p_fingerprint': hold!['fingerprint'],
              'p_identity_method': method,
              'p_identity_invoice': document,
              'p_evidence_note': evidence.text.trim(),
              'p_language': ar ? 'ar' : 'en',
              'p_notice': hold![ar ? 'verbal_notice_ar' : 'verbal_notice_en'],
              'p_confirmed': true,
            },
          };
        } else if (kind == 'release') {
          if (hold == null) return;
          command = {
            'kind': kind,
            'name': 'release_cashier_mixed_points',
            'params': {
              'p_request': newOrderRequestId(),
              'p_reservation': hold!['reservation_id'],
              'p_reason': 'Cashier releases unissued points selection at customer request',
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
            result['reservation_id'] !=
                (pending['params'] as Map)['p_request'] ||
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
          'reservation_id': hold!['reservation_id'],
          'consent_id': result['consent_id'],
        };
        widget.onApproval(Map.unmodifiable(approved!));
        widget.onSelectionPending(false);
      } else {
        if (result['released'] != true) {
          throw const FormatException('Unverified release');
        }
        hold = approved = null;
        widget.onApproval(null);
        widget.onSelectionPending(false);
      }
      command = null;
    } catch (e) {
      if (current && generation == epoch) {
        error = t(
          'لم يكتمل التأكيد. راجع الهوية والسياسة والرصيد. عند انقطاع الاتصال أعد محاولة نفس الطلب.',
          'Confirmation did not complete. Check identity, policy and points. After a connection failure retry the same request.',
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
              t('استبدال نقاط الولاء', 'Redeem loyalty points'),
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
                  'انتهت صلاحية المراجعة. أعد حفظ المسودة وتأكيد السيارة قبل استبدال النقاط.',
                  'Review expired. Save a new draft version and confirm the car before redeeming points.',
                ),
              ),
            if (data?['state'] != 'ready')
              Text(
                t(
                  'لا توجد نقاط متاحة أو يلزم ربط السيارة أو مراجعة المالك.',
                  'No points are available, or vehicle binding or owner review is required.',
                ),
              ),
            if (hold == null && data?['state'] == 'ready') ...[
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
                  for (final b in rows('buckets'))
                    DropdownMenuItem(
                      value: b['earning_policy_id'] as String,
                      child: Text(
                        '${b['available_points']} ${t('نقطة', 'points')} · ${b['point_value_egp']} EGP',
                      ),
                    ),
                ],
                onChanged: usable ? (v) => setState(() => policy = v) : null,
              ),
              TextField(
                key: const ValueKey('points_quantity'),
                controller: points,
                enabled: usable,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('عدد النقاط', 'Points to use'),
                ),
              ),
              OutlinedButton(
                onPressed: usable && data?['seal_expired'] != true
                    ? () => act('reserve')
                    : null,
                child: Text(
                  t(
                    'حجز النقاط ومعاينة السعر',
                    'Reserve points and preview price',
                  ),
                ),
              ),
            ],
            if (hold != null && quote != null) ...[
              Text('${t('النقاط', 'Points')}: ${quote['loyalty_points']}'),
              Text(
                '${t('خصم الولاء', 'Loyalty discount')}: ${money(quote['loyalty_payable_reduction'])} EGP',
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
                  key: const ValueKey('points_identity_method'),
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
                  key: const ValueKey('points_identity_record'),
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
                  key: const ValueKey('points_identity_note'),
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
                  key: const ValueKey('points_identity_checked'),
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
                  key: const ValueKey('points_verbal_checked'),
                  value: verbalChecked,
                  onChanged: usable
                      ? (v) => setState(() => verbalChecked = v == true)
                      : null,
                  title: Text(
                    t(
                      'عرضت النقاط والخصم والإجمالي وحصلت على موافقة العميل الشفهية.',
                      'I showed the points, discount and total and received the customer’s verbal approval.',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: usable && identityChecked && verbalChecked
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
                    'سُجلت الموافقة لهذه الفاتورة فقط. الخصم النهائي للنقاط بعد تأكيد التحصيل.',
                    'Approval is recorded for this invoice only. Points commit after verified collection.',
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
