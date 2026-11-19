import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'invoice_presentation.dart';
import 'workflow.dart';

class PaymentCheckoutScreen extends StatefulWidget {
  final SupabaseClient client;
  final String invoiceId;
  final bool sandboxEnabled;
  const PaymentCheckoutScreen({
    super.key,
    required this.client,
    required this.invoiceId,
    this.sandboxEnabled = const bool.fromEnvironment(
      'ENABLE_PAYMOB_SANDBOX',
      defaultValue: false,
    ),
  });
  @override
  State<PaymentCheckoutScreen> createState() => _PaymentCheckoutState();
}

class _PaymentCheckoutState extends State<PaymentCheckoutScreen> {
  Map<String, dynamic>? quote;
  String? error, status;
  bool busy = false;
  final request = newOrderRequestId(), form = GlobalKey<FormState>();
  final billing = <String, TextEditingController>{
    for (final key in [
      'first_name',
      'last_name',
      'email',
      'phone_number',
      'country',
      'city',
      'street',
      'building',
      'floor',
      'apartment',
    ])
      key: TextEditingController(),
  };
  bool get hasRewardRecord => invoiceHasRewardRecord(quote ?? {});
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in billing.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = Map<String, dynamic>.from(
        await widget.client.rpc(
          'invoice_payment_quote',
          params: {'p_invoice': widget.invoiceId},
        ),
      );
      Map<String, dynamic> state = {};
      if (!invoiceHasRewardRecord(data)) {
        state = Map<String, dynamic>.from(
          await widget.client.rpc(
            'get_paymob_sandbox_status',
            params: {'p_invoice': widget.invoiceId},
          ),
        );
      }
      if (mounted) {
        setState(() {
          quote = data;
          status = state['status'];
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'الفاتورة غير متاحة أو غير مصرح بها',
            'Invoice unavailable or not authorized',
          ),
        );
      }
    }
  }

  Future<void> checkout() async {
    if (hasRewardRecord ||
        quote?['collectible'] == false ||
        busy ||
        !widget.sandboxEnabled ||
        !(form.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.client.functions.invoke(
        'paymob-sandbox',
        body: {
          'invoice_id': widget.invoiceId,
          'request_id': request,
          'billing_data': billing.map((k, v) => MapEntry(k, v.text.trim())),
        },
      );
      final data = Map<String, dynamic>.from(result.data as Map);
      final url = Uri.tryParse('${data['checkout_url'] ?? ''}');
      if (result.status != 200 ||
          url == null ||
          url.scheme != 'https' ||
          url.host != 'accept.paymob.com' ||
          url.path != '/unifiedcheckout/') {
        throw StateError('Unavailable');
      }
      await launchUrl(url, mode: LaunchMode.externalApplication);
      // A browser/SDK return never confirms a payment. Read verified server state.
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'الدفع التجريبي غير متاح. لم يتم تأكيد أي تحصيل.',
            'Sandbox checkout unavailable. No collection was confirmed.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('خيارات الدفع', 'Payment options'))),
    body: quote == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Text(error!),
          )
        : hasRewardRecord
        ? ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                invoiceNumber(quote!),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(invoiceState(quote!['payment_status'], ar)),
              Text(
                '${t('السعر قبل المكافأة', 'Before reward')}: ${quote!['gross_amount']} EGP',
              ),
              Text(
                '${t('خصم المكافأة', 'Reward discount')}: ${quote!['discount']} EGP',
              ),
              Text('${t('المستحق', 'Amount due')}: 0.00 EGP'),
              Text(
                invoiceHasRewardCoverage(quote!)
                    ? t(
                        'لا توجد دفعة نقدية أو ببطاقة مستحقة لهذه الفاتورة.',
                        'No cash or card payment is due for this invoice.',
                      )
                    : t(
                        'أُلغيت المكافأة. لم يتم تسجيل تحصيل.',
                        'The reward was cancelled. No collection was recorded.',
                      ),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: Text(
                  t('تحديث الحالة من الخادم', 'Refresh server status'),
                ),
              ),
            ],
          )
        : Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  invoiceNumber(quote!),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '${t('السعر الأساسي', 'Base price')}: ${quote!['base_amount']} EGP',
                ),
                Text(
                  '${t('رسوم على العميل', 'Customer fee')}: ${quote!['customer_fee']} EGP',
                ),
                Text(
                  '${t('إجمالي الكاش', 'Cash total')}: ${quote!['cash_total']} EGP',
                ),
                Text(
                  '${t('إجمالي البطاقة', 'Card total')}: ${quote!['card_total']} EGP',
                ),
                const SizedBox(height: 14),
                Text(
                  t(
                    'النقدي يبقى معلقًا حتى تأكيد الكاشير. المركز يتحمل عمولة البوابة.',
                    'Cash stays pending until cashier confirmation. The centre absorbs gateway fees.',
                  ),
                ),
                const Divider(),
                Text(
                  t(
                    widget.sandboxEnabled ? 'Paymob — تجربة Sandbox فقط، دون تحصيل حقيقي' : 'سيتم تفعيل خدمة الدفع الإلكتروني قريبًا',
                    widget.sandboxEnabled ? 'Paymob — Sandbox only, no real collection' : 'Online payment will be available soon',
                  ),
                ),
                if (status != null && status != 'not_started')
                  Text(invoiceState(status, ar)),
                if (widget.sandboxEnabled) ...[
                  for (final entry in billing.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: TextFormField(
                        controller: entry.value,
                        decoration: InputDecoration(
                          labelText: _billingLabel(entry.key),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? t(
                                'مطلوب — استخدم بيانات حقيقية',
                                'Required — use real billing details',
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy || quote?['collectible'] == false
                        ? null
                        : checkout,
                    child: Text(
                      t('فتح الدفع التجريبي', 'Open Sandbox checkout'),
                    ),
                  ),
                ],
                TextButton(
                  onPressed: busy ? null : load,
                  child: Text(
                    t('تحديث الحالة من الخادم', 'Refresh server status'),
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
  );
  String _billingLabel(String key) {
    const labels = {
      'first_name': ('الاسم الأول', 'First name'),
      'last_name': ('اسم العائلة', 'Last name'),
      'email': ('البريد الإلكتروني', 'Email'),
      'phone_number': ('الهاتف', 'Phone'),
      'country': ('كود الدولة', 'Country code'),
      'city': ('المدينة', 'City'),
      'street': ('الشارع', 'Street'),
      'building': ('المبنى', 'Building'),
      'floor': ('الدور', 'Floor'),
      'apartment': ('الوحدة', 'Apartment'),
    };
    final l = labels[key]!;
    return t(l.$1, l.$2);
  }
}
