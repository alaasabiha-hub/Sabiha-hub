import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_points_verbal.dart';
import 'cashier_visits_verbal.dart';
import 'cashier_invoice_draft.dart' show CashierCartGateway;
import 'invoice_presentation.dart';
import 'workflow.dart' show newOrderRequestId;

class CashierCheckoutPanel extends StatefulWidget {
  const CashierCheckoutPanel({
    super.key,
    required this.gateway,
    required this.branch,
    required this.draft,
    required this.version,
    required this.hasServices,
    required this.onMutationBusy,
    required this.onIssued,
    this.bindingRevision = 0,
    this.externalBusy = false,
    this.onOpenInvoice,
    this.onOpenWork,
    this.onManageShifts,
    this.onDownloadRefund,
  });
  final CashierCartGateway gateway;
  final String branch, draft;
  final int version, bindingRevision;
  final bool hasServices, externalBusy;
  final ValueChanged<bool> onMutationBusy;
  final VoidCallback onIssued;
  final Future<void> Function(String token, String role)? onOpenInvoice;
  final Future<void> Function(String order)? onOpenWork;
  final Future<void> Function(String role)? onManageShifts;
  final Future<void> Function(String request, String paper)? onDownloadRefund;
  @override
  State<CashierCheckoutPanel> createState() => _CashierCheckoutPanelState();
}

class _CashierCheckoutPanelState extends State<CashierCheckoutPanel> {
  final reason = TextEditingController();
  final quantities = <String, TextEditingController>{};
  final selected = <String>{};
  final restock = <String, bool>{};
  Map<String, dynamic>? data, preview, pending, pointsApproval, visitsApproval;
  List<Map<String, dynamic>> previewLines = [];
  String? shift, error;
  String paper = 'A4';
  DateTime? day;
  TimeOfDay? time;
  bool busy = true,
      ack = false,
      pointsSelectionPending = false,
      visitsSelectionPending = false;
  int epoch = 0;
  bool get active => mounted && widget.gateway.current;
  bool get editable =>
      active && !busy && !widget.externalBusy && pending == null;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  String money(dynamic value) => value is num ? value.toStringAsFixed(2) : '—';
  String shiftTime(dynamic raw) {
    final date = DateTime.tryParse('$raw');
    if (date == null) return t('الوقت غير مسجل', 'Time not recorded');
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatMediumDate(date)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  Map<String, dynamic>? get invoice => data?['invoice'] is Map
      ? Map<String, dynamic>.from(data!['invoice'] as Map)
      : null;
  List<Map<String, dynamic>> rows(String key) =>
      List<Map<String, dynamic>>.from(data?[key] as List? ?? []);
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant CashierCheckoutPanel old) {
    super.didUpdateWidget(old);
    if (old.bindingRevision != widget.bindingRevision &&
        pending == null &&
        !busy) {
      pointsApproval = null;
      pointsSelectionPending = false;
      visitsApproval = null;
      visitsSelectionPending = false;
      unawaited(load());
    }
  }

  @override
  void dispose() {
    epoch++;
    reason.dispose();
    for (final c in quantities.values) {
      c.dispose();
    }
    super.dispose();
  }

  String failure(Object e) => e is PostgrestException && e.code == '40001'
      ? t(
          'تغيرت البيانات. حدّثها وراجع المعاينة قبل التأكيد.',
          'Data changed. Refresh and review the preview before confirming.',
        )
      : t(
          'تعذر التأكيد. راجع العميل والسيارة والموعد والسعة والصلاحيات والوردية.',
          'Unable to confirm. Check the customer, car, time, capacity, permissions and shift.',
        );
  void resetPreview() {
    preview = null;
    previewLines = [];
    ack = false;
  }

  Future<Map<String, dynamic>> readState() async {
    final result = await widget.gateway.call('get_cashier_checkout_state', {
      'p_branch': widget.branch,
      'p_draft': widget.draft,
    });
    if (result['kind'] != 'cashier_checkout_state_v1' ||
        result['draft_id'] != widget.draft ||
        result['draft_version'] != widget.version ||
        result['branch_id'] != widget.branch) {
      throw StateError('Invalid checkout context');
    }
    return result;
  }

  Future<void> load() async {
    if (!active || pending != null) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await readState();
      if (!active || generation != epoch) return;
      data = result;
      if (result['state'] == 'issued') widget.onIssued();
      final local = DateTime.parse(result['local_now'] as String)
          .add(const Duration(minutes: 10));
      day ??= DateTime(local.year, local.month, local.day);
      time ??= TimeOfDay.fromDateTime(local);
      final shifts = rows('open_shifts');
      if (!shifts.any((s) => s['id'] == shift)) {
        shift = shifts.length == 1 ? shifts.single['id'] as String : null;
      }
      selected.clear();
      restock.clear();
      resetPreview();
      for (final c in quantities.values) {
        c.dispose();
      }
      quantities.clear();
      for (final row in rows('refundable_lines')) {
        final id = row['line_id'] as String;
        quantities[id] = TextEditingController(text: '1');
        restock[id] = false;
      }
    } catch (e) {
      if (active && generation == epoch) error = failure(e);
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  String digits(String s) =>
      s.trim().replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (m) {
        final c = m[0]!.runes.single;
        return '${c >= 0x6f0 ? c - 0x6f0 : c - 0x660}';
      });
  List<Map<String, dynamic>> refundSelection() {
    final result = <Map<String, dynamic>>[];
    for (final row in rows('refundable_lines')) {
      final id = row['line_id'] as String;
      if (!selected.contains(id)) continue;
      final n = int.tryParse(digits(quantities[id]!.text));
      if (n == null || n < 1 || n > (row['refundable_quantity'] as num)) {
        throw const FormatException('Invalid original quantity');
      }
      result.add({
        'line_id': id,
        'quantity': n,
        'restock': row['item_type'] == 'product' && restock[id] == true,
      });
    }
    if (result.isEmpty) throw const FormatException('Select original lines');
    return result;
  }

  Future<void> previewRefund() async {
    if (!editable || invoice == null) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
      resetPreview();
    });
    try {
      final lines = refundSelection();
      final result = await widget.gateway.call('preview_cashier_refund_lines', {
        'p_invoice': invoice!['id'],
        'p_lines': lines,
      });
      if (!active || generation != epoch) return;
      if (result['quote_only'] != true ||
          result['financial_event_created'] != false ||
          result['amount'] is! num ||
          result['quote_hash'] is! String) {
        throw StateError('Invalid refund preview');
      }
      preview = result;
      previewLines = List<Map<String, dynamic>>.from(
        jsonDecode(jsonEncode(lines)) as List,
      );
    } catch (e) {
      if (active && generation == epoch) error = failure(e);
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  // A proxy/connection failure may arrive after a committed operation. Only
  // explicit database rejections establish rollback; all other sent requests
  // retain their exact idempotency key and payload for reconciliation.
  bool definiteRejection(Object error) =>
      error is PostgrestException &&
      RegExp(r'^(22|23|40|42|55|P0)[0-9A-Z]{3}$').hasMatch(error.code ?? '');

  Future<void> mutate(
    String kind, {
    Map<String, dynamic>? stop,
    Map<String, dynamic>? terminal,
  }) async {
    if (!active || busy || widget.externalBusy) return;
    final generation = ++epoch;
    widget.onMutationBusy(true);
    setState(() {
      busy = true;
      error = null;
    });
    var sent = false;
    try {
      if (pending == null) {
        Map<String, dynamic> params;
        String name;
        if (kind == 'issue') {
          final current = await readState();
          if (!active || generation != epoch) return;
          if (current['state'] == 'issued') {
            data = current;
            widget.onIssued();
            return;
          }
          final binding = Map<String, dynamic>.from(current['binding'] as Map);
          if (binding['state'] != 'bound' ||
              !([
                'app_customer',
                'offline_profile',
              ].contains((binding['subject'] as Map)['kind'])) ||
              ((binding['subject'] as Map)['kind'] == 'offline_profile' &&
                  current['offline_profile_issue_supported'] != true)) {
            throw const FormatException(
              'Current app customer and owned car required',
            );
          }
          params = {
            'p_request': newOrderRequestId(),
            'p_branch': widget.branch,
            'p_draft': widget.draft,
            'p_expected_draft_version': widget.version,
            'p_expected_binding_version': binding['binding_version'],
          };
          name = 'issue_cashier_invoice';
          if (widget.hasServices) {
            if (day == null || time == null) {
              throw const FormatException('Choose the centre appointment');
            }
            final resolved = await widget.gateway.call(
              'resolve_cashier_start_time',
              {
                'p_branch': widget.branch,
                'p_day':
                    '${day!.year}-${day!.month.toString().padLeft(2, '0')}-${day!.day.toString().padLeft(2, '0')}',
                'p_time':
                    '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}:00',
              },
            );
            if (!active || generation != epoch) return;
            params['p_start'] = resolved['start_at'];
            name = 'issue_cashier_mixed_invoice';
            if (pointsApproval != null && visitsApproval != null) {
              throw const FormatException('Choose one loyalty method only');
            }
            if (pointsApproval != null) {
              params = {
                'p_request': params['p_request'],
                'p_branch': widget.branch,
                'p_start': params['p_start'],
                'p_reservation': pointsApproval!['reservation_id'],
                'p_consent': pointsApproval!['consent_id'],
              };
              name = 'issue_cashier_points_invoice';
            }
            if (visitsApproval != null) {
              params = {
                'p_request': params['p_request'],
                'p_branch': widget.branch,
                'p_start': params['p_start'],
                'p_group': visitsApproval!['group_id'],
                'p_consent': visitsApproval!['consent_id'],
              };
              name = 'issue_cashier_visit_invoice';
            }
          }
        } else if ((kind == 'stop' || kind == 'stop_unpaid')) {
          if (stop == null) {
            throw const FormatException(
              'Explicit service stop confirmation required',
            );
          }
          name = kind == 'stop_unpaid'
              ? 'cancel_unpaid_cashier_service'
              : 'cancel_cashier_service';
          params = {'p_request': newOrderRequestId(), ...stop};
        } else if (kind == 'terminal') {
          if (terminal == null ||
              shift == null ||
              invoice == null ||
              invoice!['payment_status'] != 'unpaid' ||
              data?['terminal_manual_enabled'] != true) {
            throw const FormatException(
              'Verified receipt and an unpaid invoice required',
            );
          }
          name = 'confirm_cashier_terminal_payment';
          params = {
            'p_request': newOrderRequestId(),
            'p_shift': shift,
            'p_invoice': invoice!['id'],
            'p_expected_amount': invoice!['payable'] ?? invoice!['total'],
            'p_credit_version': invoice!['credit_version'],
            ...terminal,
          };
        } else if (kind == 'cash') {
          if (shift == null ||
              invoice == null ||
              invoice!['payment_status'] != 'unpaid') {
            throw const FormatException(
              'Open shift and unpaid invoice required',
            );
          }
          final adjusted = invoice!['credit_version'] is String;
          name = adjusted
              ? 'confirm_cashier_adjusted_cash'
              : 'confirm_cashier_cash_payment';
          params = {
            'p_request': newOrderRequestId(),
            'p_shift': shift,
            'p_invoice': invoice!['id'],
            if (adjusted) 'p_expected_payable': invoice!['payable'],
            if (adjusted) 'p_credit_version': invoice!['credit_version'],
          };
        } else {
          if (!ack ||
              preview == null ||
              shift == null ||
              reason.text.trim().length < 5) {
            throw const FormatException('Review original refund and reason');
          }
          name = kind == 'refund_terminal'
              ? 'confirm_cashier_terminal_refund'
              : 'confirm_cashier_refund';
          if (kind == 'refund_terminal' && terminal == null) {
            throw const FormatException(
              'Verified external refund receipt required',
            );
          }
          params = {
            'p_request': newOrderRequestId(),
            'p_shift': shift,
            'p_invoice': invoice!['id'],
            'p_lines': previewLines,
            'p_reason': reason.text.trim(),
            'p_quote_hash': preview!['quote_hash'],
            if (kind == 'refund_terminal') ...terminal!,
          };
        }
        pending = Map<String, dynamic>.from(
          jsonDecode(jsonEncode({'kind': kind, 'name': name, 'params': params}))
              as Map,
        );
      }
      sent = true;
      final result = await widget.gateway.call(
        pending!['name'] as String,
        Map<String, dynamic>.from(pending!['params'] as Map),
      );
      if (!active || generation != epoch) return;
      final action = pending!['kind'];
      final params = pending!['params'] as Map;
      if (action == 'issue') {
        if (result['issued'] != true || result['invoice_id'] is! String) {
          throw StateError('Invalid issue receipt');
        }
        widget.onIssued();
      } else if ((action == 'stop' || action == 'stop_unpaid')) {
        if (result['request_id'] != params['p_request'] ||
            result['order_id'] != params['p_order'] ||
            result['status'] != 'cancelled' ||
            result['financial_refund_performed'] != false ||
            (action == 'stop_unpaid' &&
                result['unpaid_credit_applied'] != true)) {
          throw StateError('Invalid service stop receipt');
        }
      } else if (action == 'cash' || action == 'terminal') {
        if (result['invoice_id'] != params['p_invoice'] ||
            result['sale_recorded'] != true ||
            result['payment_id'] is! String) {
          throw StateError('Invalid cash receipt');
        }
      } else if (result['refund_id'] != params['p_request'] ||
          result['invoice_id'] != params['p_invoice']) {
        throw StateError('Invalid refund receipt');
      }
      pending = null;
      resetPreview();
    } catch (e) {
      if (active && generation == epoch) {
        if (definiteRejection(e) || !sent) {
          pending = null;
          error = failure(e);
        } else {
          error = t(
            'لم تتضح نتيجة الطلب. أعد نفس الطلب دون تغيير بياناته.',
            'The result is uncertain. Retry the same request without changing its details.',
          );
        }
      }
    } finally {
      if (active && generation == epoch) {
        setState(() => busy = false);
        widget.onMutationBusy(pending != null);
      }
    }
    if (active && pending == null) await load();
  }

  Future<void> requestServiceStop(Map<String, dynamic> row) async {
    if (!editable ||
        (row['can_cancel'] != true && row['can_cancel_unpaid'] != true)) {
      return;
    }
    final unpaid = row['can_cancel_unpaid'] == true;
    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => _ServiceStopDialog(
        ar: ar,
        unpaidAmount: unpaid
            ? money(row['unpaid_credit_preview_amount'])
            : null,
        physicalRequired: row['physical_clearance_required'] == true,
      ),
    );
    if (!active || !editable || confirmed == null) return;
    await mutate(
      unpaid ? 'stop_unpaid' : 'stop',
      stop: {
        'p_order': row['order_id'],
        'p_expected_status': row['status'],
        ...confirmed,
      },
    );
  }

  Future<void> pickDay() async {
    if (!editable || data == null) return;
    final first = DateTime.parse(data!['local_today'] as String);
    final initial = day != null && day!.isAfter(first) ? day! : first;
    final result = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime(first.year + 2, 12, 31),
    );
    if (active && result != null) setState(() => day = result);
  }

  Future<void> pickTime() async {
    if (!editable) return;
    final result = await showTimePicker(
      context: context,
      initialTime: time ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (active && result != null) setState(() => time = result);
  }

  Future<void> verifyTerminalReceipt({bool forRefund = false}) async {
    if (!editable || data?['terminal_manual_enabled'] != true) return;
    final terminal = TextEditingController(),
        reference = TextEditingController();
    var checked = false;
    final evidence = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(
            forRefund
                ? t('تأكيد إيصال استرداد البطاقة', 'Verify card refund receipt')
                : t(
                    'تأكيد إيصال ماكينة البطاقة',
                    'Verify card terminal receipt',
                  ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${t('المبلغ المستحق', 'Amount due')}: ${money(forRefund ? (preview?['amount']) : (invoice?['payable'] ?? invoice?['total']))} EGP',
              ),
              Text(
                t(
                  forRefund
                      ? 'نفّذ الاسترداد على الماكينة وتحقق من إيصال نجاحه أولًا. لا تدخل بيانات البطاقة.'
                      : 'نفّذ الدفع على الماكينة وتحقق من نجاحه وإيصالها أولًا. لا تدخل بيانات البطاقة.',
                  forRefund
                      ? 'Complete the refund on the terminal and verify its successful receipt first. Do not enter card details.'
                      : 'Complete payment on the terminal and verify its successful receipt first. Do not enter card details.',
                ),
              ),
              if (!forRefund)
                TextField(
                  controller: terminal,
                  onChanged: (_) => update(() {}),
                  decoration: InputDecoration(
                    labelText: t('معرّف الماكينة', 'Terminal ID'),
                  ),
                ),
              TextField(
                controller: reference,
                onChanged: (_) => update(() {}),
                decoration: InputDecoration(
                  labelText: t(
                    'مرجع العملية في الإيصال',
                    'Receipt transaction reference',
                  ),
                ),
              ),
              CheckboxListTile(
                value: checked,
                onChanged: (value) => update(() => checked = value == true),
                title: Text(
                  t(
                    forRefund
                        ? 'تحققت من نجاح الاسترداد وإيصال الماكينة'
                        : 'تحققت من نجاح العملية وإيصال الماكينة',
                    forRefund
                        ? 'I verified successful refund and the terminal receipt'
                        : 'I verified successful payment and the terminal receipt',
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed:
                  checked &&
                      (forRefund ||
                          RegExp(r'^[A-Za-z0-9_-]{2,60}$')
                              .hasMatch(terminal.text.trim())) &&
                      RegExp(r'^[A-Za-z0-9._-]{4,80}$')
                          .hasMatch(reference.text.trim()) &&
                      !RegExp(r'[0-9]{12}').hasMatch(reference.text)
                  ? () => Navigator.pop(dialogContext, <String, dynamic>{
                      if (!forRefund) 'p_terminal': terminal.text.trim(),
                      'p_reference': reference.text.trim(),
                      'p_verified': true,
                      'p_language': ar ? 'ar' : 'en',
                    })
                  : null,
              child: Text(
                forRefund
                    ? t('تسجيل الاسترداد المؤكد', 'Record verified refund')
                    : t('تسجيل الدفع المؤكد', 'Record verified payment'),
              ),
            ),
          ],
        ),
      ),
    );
    // Controllers belong to the dialog route until its exit animation completes.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    terminal.dispose();
    reference.dispose();
    if (evidence != null && active) {
      await mutate(
        forRefund ? 'refund_terminal' : 'terminal',
        terminal: evidence,
      );
    }
  }

  Future<void> openWork(String id) async {
    if (!editable || widget.onOpenWork == null) return;
    await widget.onOpenWork!(id);
    if (active) await load();
  }

  @override
  Widget build(BuildContext context) {
    final inv = invoice;
    final bound = data?['binding'] is Map ? (data!['binding'] as Map) : null;
    final appCustomer =
        bound?['state'] == 'bound' &&
        ((bound?['subject'] as Map?)?['kind'] == 'app_customer' ||
            ((bound?['subject'] as Map?)?['kind'] == 'offline_profile' &&
                data?['offline_profile_issue_supported'] == true));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('إتمام البيع والفاتورة', 'Checkout and invoice'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null) Text(error!),
            OutlinedButton(
              onPressed: editable ? load : null,
              child: Text(t('تحديث بيانات البيع', 'Refresh checkout')),
            ),
            if (pending != null)
              FilledButton(
                key: const ValueKey('checkout_retry'),
                onPressed: !busy && !widget.externalBusy
                    ? () => mutate(pending!['kind'] as String)
                    : null,
                child: Text(
                  t('إعادة نفس طلب البيع', 'Retry the same checkout request'),
                ),
              ),
            if (data != null && inv == null) ...[
              if (!appCustomer)
                Text(
                  t(
                    'أكد حساب العميل وسيارته أولًا. إصدار الملف بدون تطبيق ينتظر ربط تاريخه.',
                    'Confirm the app customer and car first. Offline-profile issuance awaits its history integration.',
                  ),
                ),
              if (widget.hasServices) ...[
                Text(
                  t(
                        'موعد الخدمات بتوقيت المركز: ',
                        'Service appointment in centre timezone: ',
                      ) +
                      (data!['time_zone'] == 'Africa/Cairo'
                          ? t('القاهرة', 'Cairo')
                          : '${data!['time_zone']}'),
                ),
                OutlinedButton(
                  onPressed: editable ? pickDay : null,
                  child: Text(
                    day == null
                        ? t('اختيار التاريخ', 'Choose date')
                        : MaterialLocalizations.of(context)
                              .formatMediumDate(day!),
                  ),
                ),
                OutlinedButton(
                  onPressed: editable ? pickTime : null,
                  child: Text(
                    time == null
                        ? t('اختيار الوقت', 'Choose time')
                        : time!.format(context),
                  ),
                ),
                Text(
                  t(
                    'لن تُصدر الفاتورة إذا تعارض الموعد أو تجاوز ساعات العمل والسعة.',
                    'The invoice cannot be issued if the appointment conflicts or exceeds hours or capacity.',
                  ),
                ),
              ],
              if (widget.hasServices && appCustomer)
                CashierPointsVerbalPanel(
                  key: ValueKey(
                    'points-${widget.draft}-${widget.version}-${widget.bindingRevision}',
                  ),
                  gateway: widget.gateway,
                  branch: widget.branch,
                  draft: widget.draft,
                  disabled:
                      !editable ||
                      visitsApproval != null ||
                      visitsSelectionPending,
                  onSelectionPending: (v) {
                    if (active) setState(() => pointsSelectionPending = v);
                  },
                  onApproval: (v) {
                    if (active) setState(() => pointsApproval = v);
                  },
                  onBusy: (v) {
                    if (active) {
                      setState(() => busy = v);
                      widget.onMutationBusy(v);
                    }
                  },
                ),
              if (widget.hasServices && appCustomer)
                CashierVisitsVerbalPanel(
                  key: ValueKey(
                    'visits-${widget.branch}-${widget.draft}-${widget.version}-${widget.bindingRevision}-${identityHashCode(widget.gateway)}',
                  ),
                  gateway: widget.gateway,
                  branch: widget.branch,
                  draft: widget.draft,
                  disabled:
                      !editable ||
                      pointsApproval != null ||
                      pointsSelectionPending,
                  onSelectionPending: (v) {
                    if (active) setState(() => visitsSelectionPending = v);
                  },
                  onApproval: (v) {
                    if (active) setState(() => visitsApproval = v);
                  },
                  onBusy: (v) {
                    if (active) {
                      setState(() => busy = v);
                      widget.onMutationBusy(v);
                    }
                  },
                ),
              FilledButton(
                key: const ValueKey('checkout_issue'),
                onPressed:
                    editable &&
                        appCustomer &&
                        !pointsSelectionPending &&
                        !visitsSelectionPending
                    ? () => mutate('issue')
                    : null,
                child: Text(
                  t(
                    'إصدار الفاتورة دون تحصيل',
                    'Issue invoice without collecting payment',
                  ),
                ),
              ),
            ],
            if (inv != null) ...[
              Text('${inv['number']}'),
              Text(
                '${t('إجمالي الفاتورة', 'Invoice total')}: ${money(inv['total'])} EGP',
              ),
              Text(
                '${t('حالة الدفع', 'Payment status')}: ${invoiceState(inv['payment_status'], ar)}',
              ),
              Text(
                '${t('المبلغ المسترد', 'Refunded amount')}: ${money(inv['refunded_amount'])} EGP',
              ),
              if (widget.onOpenInvoice != null)
                OutlinedButton(
                  onPressed: editable
                      ? () => widget.onOpenInvoice!(
                          inv['token'] as String,
                          data!['role'] as String,
                        )
                      : null,
                  child: Text(
                    t(
                      'عرض الفاتورة وتنزيل PDF',
                      'View invoice and download PDF',
                    ),
                  ),
                ),
              Text(
                t(
                  'الدفع الإلكتروني غير متاح حاليًا.',
                  'Electronic payment is currently unavailable.',
                ),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(
                  rows('open_shifts').map((e) => e['id']).join(','),
                ),
                isExpanded: true,
                initialValue: shift,
                decoration: InputDecoration(
                  labelText: t(
                    'وردية التحصيل والاسترداد',
                    'Collection and refund shift',
                  ),
                ),
                items: [
                  for (final row in rows('open_shifts'))
                    DropdownMenuItem(
                      value: row['id'] as String,
                      child: Text(
                        '${row['cashier_name']} · ${shiftTime(row['opened_local'])}',
                      ),
                    ),
                ],
                onChanged: editable ? (v) => setState(() => shift = v) : null,
              ),
              if (rows('open_shifts').isEmpty)
                Text(
                  t(
                    'افتح وردية كاشير قبل التحصيل أو الاسترداد.',
                    'Open a cashier shift before collection or refund.',
                  ),
                ),
              if (widget.onManageShifts != null)
                TextButton(
                  onPressed: editable
                      ? () async {
                          await widget.onManageShifts!(data!['role'] as String);
                          if (active) await load();
                        }
                      : null,
                  child: Text(
                    t('إدارة ورديات الكاشير', 'Manage cashier shifts'),
                  ),
                ),
              if (inv['credit_version'] is String) ...[
                Text(
                  '${t('قيمة الفاتورة الأصلية', 'Original invoice total')}: ${money(inv['total'])} EGP',
                ),
                Text(
                  '${t('تسويات الخدمات غير المدفوعة', 'Unpaid service credits')}: ${money(inv['unpaid_credit_amount'])} EGP',
                ),
                Text(
                  '${t('المستحق بعد التسويات', 'Amount due after credits')}: ${money(inv['payable'])} EGP',
                ),
              ],
              if (inv['payment_status'] == 'unpaid')
                FilledButton(
                  key: const ValueKey('checkout_cash'),
                  onPressed: editable && shift != null
                      ? () => mutate('cash')
                      : null,
                  child: Text(
                    t('تأكيد استلام النقدي', 'Confirm cash received'),
                  ),
                ),
              if (inv['payment_status'] == 'unpaid') ...[
                OutlinedButton.icon(
                  key: const ValueKey('checkout_terminal'),
                  onPressed:
                      editable &&
                          shift != null &&
                          data?['terminal_manual_enabled'] == true
                      ? verifyTerminalReceipt
                      : null,
                  icon: const Icon(Icons.credit_card),
                  label: Text(t('دفع فيزا / بطاقة', 'Pay by card / terminal')),
                ),
                if (data?['terminal_manual_enabled'] != true)
                  Text(
                    t(
                      'تأكيد البطاقة معطل حتى تجهيز الماكينة وحساب التاجر واعتماد التشغيل.',
                      'Card confirmation is disabled until terminal, merchant account and activation are approved.',
                    ),
                  ),
              ],
              for (final row in rows('work'))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${ar ? row['name'] : row['name_en'] ?? row['name']}',
                  ),
                  subtitle: Text(
                    '${row['reference']} · ${invoiceState(row['status'], ar)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: t('متابعة تنفيذ الخدمة', 'Open service work'),
                        onPressed:
                            editable &&
                                row['can_open'] == true &&
                                widget.onOpenWork != null
                            ? () => openWork(row['order_id'] as String)
                            : null,
                        icon: const Icon(Icons.assignment_outlined),
                      ),
                      if (row['can_cancel'] == true ||
                          row['can_cancel_unpaid'] == true)
                        IconButton(
                          key: ValueKey('checkout_stop_${row['order_id']}'),
                          tooltip: t(
                            'إلغاء الخدمة غير المكتملة',
                            'Cancel unfinished service',
                          ),
                          onPressed: editable
                              ? () => requestServiceStop(row)
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                        ),
                    ],
                  ),
                ),
              if (rows('refundable_lines').isNotEmpty &&
                  data!['can_refund'] == true) ...[
                Text(
                  t(
                    'استرداد بنود الفاتورة الأصلية',
                    'Refund original invoice lines',
                  ),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  t(
                    'الخدمات غير المنتهية تحتاج مسار إلغاء أو توقف؛ لن تُلغى أو تُفرغ سعتها هنا.',
                    'Unfinished services need coordinated cancellation or stop; this action does not cancel work or release capacity.',
                  ),
                ),
                for (final row in rows('refundable_lines')) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${ar ? row['name'] : row['name_en'] ?? row['name']}',
                    ),
                    subtitle: Text(
                      '${t('الكمية المتاحة', 'Available quantity')}: ${row['refundable_quantity']}',
                    ),
                    value: selected.contains(row['line_id']),
                    onChanged:
                        editable && (row['refundable_quantity'] as num) > 0
                        ? (v) => setState(() {
                            v == true
                                ? selected.add(row['line_id'] as String)
                                : selected.remove(row['line_id']);
                            resetPreview();
                          })
                        : null,
                  ),
                  if (selected.contains(row['line_id'])) ...[
                    TextField(
                      key: ValueKey('refund-qty-${row['line_id']}'),
                      controller: quantities[row['line_id']],
                      enabled: editable,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: t('كمية الاسترداد', 'Refund quantity'),
                      ),
                      onChanged: (_) => setState(resetPreview),
                    ),
                    if (row['item_type'] == 'product')
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          t(
                            'أؤكد استلام المنتج وفحص صلاحيته للبيع قبل إعادته للمخزون',
                            'I confirm the product was received and checked as fit for resale before restocking',
                          ),
                        ),
                        value: restock[row['line_id']] ?? false,
                        onChanged: editable
                            ? (v) => setState(() {
                                restock[row['line_id'] as String] = v ?? false;
                                resetPreview();
                              })
                            : null,
                      ),
                  ],
                ],
                TextField(
                  controller: reason,
                  enabled: editable,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: t('سبب الاسترداد', 'Refund reason'),
                  ),
                  onChanged: (_) => setState(() => ack = false),
                ),
                OutlinedButton(
                  key: const ValueKey('checkout_refund_preview'),
                  onPressed: editable && selected.isNotEmpty
                      ? previewRefund
                      : null,
                  child: Text(
                    t('معاينة الاسترداد من الخادم', 'Preview original refund'),
                  ),
                ),
                if (preview != null) ...[
                  Text(
                    '${t('المبلغ المعتمد للاسترداد', 'Approved refund amount')}: ${money(preview!['amount'])} EGP',
                  ),
                  for (final row in List<Map<String, dynamic>>.from(
                    preview!['lines'] as List,
                  ))
                    Text(
                      '${ar ? row['name'] : row['name_en'] ?? row['name']} · ${row['quantity']} · ${money(row['amount'])} EGP · ${row['restock'] == true ? t('إضافة للمخزون', 'Return to stock') : t('دون زيادة المخزون', 'No stock increase')}',
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      t(
                        'راجعت البنود والمبلغ وقرار رجوع المخزون',
                        'I reviewed the lines, amount and stock-return decision',
                      ),
                    ),
                    value: ack,
                    onChanged: editable
                        ? (v) => setState(() => ack = v ?? false)
                        : null,
                  ),
                  FilledButton(
                    key: const ValueKey('checkout_refund_confirm'),
                    onPressed:
                        editable &&
                            ack &&
                            shift != null &&
                            reason.text.trim().length >= 5
                        ? () => inv['payment_method'] == 'card_terminal'
                              ? verifyTerminalReceipt(forRefund: true)
                              : mutate('refund')
                        : null,
                    child: Text(
                      preview!['amount'] == 0
                          ? t(
                              'تسجيل الإيصال دون حركة نقدية',
                              'Record receipt without cash movement',
                            )
                          : t('تأكيد رد المبلغ النقدي', 'Confirm cash refund'),
                    ),
                  ),
                ],
              ],
              if (rows('refunds').isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  initialValue: paper,
                  decoration: InputDecoration(
                    labelText: t(
                      'مقاس إيصال الاسترداد',
                      'Refund receipt paper',
                    ),
                  ),
                  items: [
                    for (final value in ['A4', '58', '80'])
                      DropdownMenuItem(
                        value: value,
                        child: Text(value == 'A4' ? 'A4' : '$value mm'),
                      ),
                  ],
                  onChanged: editable
                      ? (v) => setState(() => paper = v!)
                      : null,
                ),
                for (final row in rows('refunds'))
                  OutlinedButton(
                    onPressed: editable && widget.onDownloadRefund != null
                        ? () => widget.onDownloadRefund!(
                            row['refund_id'] as String,
                            paper,
                          )
                        : null,
                    child: Text(
                      '${t('تنزيل إيصال', 'Download receipt')} ${row['number']} · ${money(row['amount'])} EGP',
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

class _ServiceStopDialog extends StatefulWidget {
  const _ServiceStopDialog({
    required this.ar,
    required this.physicalRequired,
    this.unpaidAmount,
  });
  final String? unpaidAmount;
  final bool ar, physicalRequired;
  @override
  State<_ServiceStopDialog> createState() => _ServiceStopDialogState();
}

class _ServiceStopDialogState extends State<_ServiceStopDialog> {
  final reason = TextEditingController();
  bool clear = false, reviewed = false;
  String t(String a, String e) => widget.ar ? a : e;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('إلغاء الخدمة غير المكتملة', 'Cancel unfinished service')),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.unpaidAmount != null)
              Text(
                t(
                  'سيتم تخفيض المستحق بمقدار ${widget.unpaidAmount} EGP دون رد نقدي، مع حفظ الفاتورة الأصلية.',
                  'Amount due will decrease by ${widget.unpaidAmount} EGP without a cash refund; the original invoice is preserved.',
                ),
              )
            else
              Text(
                t(
                  'سيتم إيقاف هذه الخدمة وحجزها فقط. رد المبلغ يتطلب معاينة وتأكيدًا منفصلين؛ لا تتغير المنتجات أو الخدمات الأخرى.',
                  'Only this service and its booking will stop. A money refund requires separate preview and confirmation; other services and products remain unchanged.',
                ),
              ),
            TextField(
              key: const ValueKey('service_stop_reason'),
              controller: reason,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: t('سبب الإلغاء', 'Cancellation reason'),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.physicalRequired)
              CheckboxListTile(
                title: Text(
                  t(
                    'أؤكد خروج السيارة وتحرير المعدات ومكان العمل فعليًا',
                    'I confirm the vehicle, equipment and work bay are physically clear',
                  ),
                ),
                value: clear,
                onChanged: (v) => setState(() => clear = v ?? false),
              ),
            CheckboxListTile(
              title: Text(
                t(
                  'راجعت إيقاف الخدمة وعدم رد المبلغ تلقائيًا',
                  'I reviewed stopping the service without an automatic refund',
                ),
              ),
              value: reviewed,
              onChanged: (v) => setState(() => reviewed = v ?? false),
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
        key: const ValueKey('service_stop_confirm'),
        onPressed:
            reason.text.trim().length >= 5 &&
                reviewed &&
                (!widget.physicalRequired || clear)
            ? () => Navigator.pop(context, {
                'p_reason': reason.text.trim(),
                'p_physical_clearance': clear,
              })
            : null,
        child: Text(t('تأكيد إيقاف الخدمة', 'Confirm service stop')),
      ),
    ],
  );
}
