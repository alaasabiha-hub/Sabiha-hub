// Operational customer/car selection only; never verifies identity or spends loyalty.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cashier_invoice_draft.dart' show CashierCartGateway;
import 'workflow.dart' show newOrderRequestId;

class CashierCustomerBinding extends StatefulWidget {
  const CashierCustomerBinding({
    super.key,
    required this.gateway,
    required this.branch,
    required this.draft,
    required this.version,
    required this.onMutationBusy,
  });
  final CashierCartGateway gateway;
  final String branch, draft;
  final int version;
  final ValueChanged<bool> onMutationBusy;
  @override
  State<CashierCustomerBinding> createState() => _CashierCustomerBindingState();
}

class _CashierCustomerBindingState extends State<CashierCustomerBinding> {
  final phone = TextEditingController();
  int epoch = 0, bindingVersion = 0;
  bool busy = true, loaded = false;
  String? error, state;
  List<Map<String, dynamic>> candidates = [];
  Map<String, dynamic>? selected, pending, snapshot;
  bool get active => mounted && widget.gateway.current;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    phone.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++epoch;
    try {
      final result = await widget.gateway.call('get_cashier_draft_subject', {
        'p_branch': widget.branch,
        'p_draft': widget.draft,
      });
      if (!active || generation != epoch) return;
      bindingVersion = result['binding_version'] as int;
      state = result['state'] as String;
      if (result['subject'] is Map) {
        snapshot = Map<String, dynamic>.from(result['subject'] as Map);
        final car = Map<String, dynamic>.from(snapshot!['car'] as Map);
        selected = {
          'kind': snapshot!['kind'],
          'id': snapshot!['id'],
          'car_id': car['id'],
        };
      }
      loaded = true;
    } catch (_) {
      if (active && generation == epoch) {
        error = t(
          'تعذر قراءة ربط العميل والسيارة.',
          'Unable to read the customer and car selection.',
        );
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    if (!active || busy || pending != null || !loaded) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      error = null;
      candidates = [];
      selected = null;
    });
    try {
      final result = await widget.gateway.call('find_cashier_customers', {
        'p_branch': widget.branch,
        'p_phone': phone.text.trim(),
      });
      if (!active || generation != epoch) return;
      if (result['automatic_account_link'] != false ||
          result['loyalty_redemption_authorized'] != false) {
        throw StateError('Unverified selection scope');
      }
      candidates = List<Map<String, dynamic>>.from(
        result['candidates'] as List,
      );
      if (candidates.isEmpty) {
        error = t(
          'لا يوجد ملف مطابق. استخدم تسجيل العميل الحالي دون إيميل.',
          'No matching profile. Use the existing customer registration without email.',
        );
      }
    } catch (_) {
      if (active && generation == epoch) {
        error = t(
          'تعذر البحث. أدخل رقم هاتف مصريًا كاملًا وتحقق من الصلاحيات.',
          'Search unavailable. Enter a complete Egyptian phone and check permissions.',
        );
      }
    } finally {
      if (active && generation == epoch) setState(() => busy = false);
    }
  }

  Future<void> bind() async {
    if (!active || busy || !loaded || (selected == null && pending == null)) {
      return;
    }
    final generation = ++epoch;
    pending ??= {
      'p_request': newOrderRequestId(),
      'p_branch': widget.branch,
      'p_draft': widget.draft,
      'p_expected_draft_version': widget.version,
      'p_expected_binding_version': bindingVersion,
      'p_kind': selected!['kind'],
      'p_subject': selected!['id'],
      'p_car': selected!['car_id'],
    };
    widget.onMutationBusy(true);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.call(
        'bind_cashier_draft_subject',
        Map<String, dynamic>.from(pending!),
      );
      if (!active || generation != epoch) return;
      if (result['draft_id'] != widget.draft ||
          result['draft_version'] != widget.version ||
          result['binding_version'] != bindingVersion + 1 ||
          result['can_issue'] != false) {
        throw StateError('Unverified binding receipt');
      }
      snapshot = Map<String, dynamic>.from(result['subject'] as Map);
      bindingVersion = result['binding_version'] as int;
      state = 'bound';
      pending = null;
    } catch (e) {
      if (active && generation == epoch) {
        error = t(
          'تعذر تأكيد الربط. لا توجد فاتورة أو عملية خصم نقاط.',
          'Selection could not be confirmed. No invoice or loyalty debit occurred.',
        );
        if (e is PostgrestException) {
          pending = null;
          loaded = false;
        }
      }
    } finally {
      if (active && generation == epoch) {
        setState(() => busy = false);
        // An unknown ACK keeps the parent cart frozen until exact replay resolves it.
        widget.onMutationBusy(pending != null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t(
              'العميل والسيارة لهذه المسودة',
              'Customer and car for this draft',
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            t(
              'اختيار ملف العميل لا يثبت الهوية ولا يسمح باستبدال نقاط الولاء.',
              'Selecting a customer does not verify identity or authorize loyalty redemption.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          if (!loaded && !busy)
            OutlinedButton(
              onPressed: () => setState(() {
                busy = true;
                unawaited(load());
              }),
              child: Text(t('إعادة قراءة الربط', 'Reload selection')),
            ),
          if (snapshot != null)
            Text(
              '${snapshot!['name']} — ${(snapshot!['car'] as Map)['plate_number']}',
            ),
          if (state == 'bound')
            Text(
              t(
                'العميل والسيارة مرتبطان بالنسخة المحفوظة.',
                'Customer and car are bound to this saved version.',
              ),
            ),
          if (state == 'stale')
            Text(
              t(
                'تغيرت بنود المسودة؛ أكد العميل والسيارة من جديد.',
                'Draft items changed; confirm the customer and car again.',
              ),
            ),
          TextField(
            controller: phone,
            enabled: !busy && loaded && pending == null,
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() {
              selected = null;
              candidates = [];
            }),
            decoration: InputDecoration(
              labelText: t('رقم هاتف العميل', 'Customer phone'),
            ),
          ),
          OutlinedButton(
            onPressed: !busy && loaded && pending == null ? search : null,
            child: Text(t('البحث عن العميل', 'Find customer')),
          ),
          for (final customer in candidates) ...[
            Text(
              '${customer['name']} — ${customer['kind'] == 'app_customer' ? t('حساب التطبيق', 'App account') : t('ملف بدون تطبيق', 'Offline profile')}',
            ),
            for (final car in List<Map<String, dynamic>>.from(
              customer['cars'] as List,
            ))
              OutlinedButton(
                onPressed: !busy && pending == null
                    ? () => setState(
                        () => selected = {
                          'kind': customer['kind'],
                          'id': customer['id'],
                          'car_id': car['id'],
                        },
                      )
                    : null,
                child: Text(
                  '${car['plate_number']} — ${car['brand'] ?? ''} ${car['model'] ?? ''}${selected?['id'] == customer['id'] && selected?['car_id'] == car['id'] ? ' ✓' : ''}',
                ),
              ),
          ],
          FilledButton(
            onPressed: !busy && loaded && (selected != null || pending != null)
                ? bind
                : null,
            child: Text(
              pending != null
                  ? t(
                      'إعادة نفس طلب ربط العميل',
                      'Retry the same customer selection',
                    )
                  : t('تأكيد العميل والسيارة', 'Confirm customer and car'),
            ),
          ),
        ],
      ),
    ),
  );
}
