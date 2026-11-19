import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show InvoiceDocumentsScreen, matchesInitialAuthReplay;
import 'invoice_presentation.dart' show invoiceState;

abstract class OwnerRewardIssuerGateway {
  bool get current;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  );
}

class SupabaseOwnerRewardIssuerGateway implements OwnerRewardIssuerGateway {
  SupabaseOwnerRewardIssuerGateway(this.client)
    : actor = client.auth.currentUser?.id,
      token = client.auth.currentSession?.accessToken;
  final SupabaseClient client;
  final String? actor, token;
  @override
  bool get current =>
      actor != null &&
      token != null &&
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession?.accessToken == token;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    if (!current ||
        !const {
          'get_owner_reward_issuer_context',
          'list_owner_reward_issues',
          'get_owner_reward_issue',
        }.contains(name)) {
      throw StateError('Unavailable owner read');
    }
    final data = await client
        .rpc(name, params: parameters)
        .timeout(const Duration(seconds: 25));
    if (!current) throw StateError('Session changed');
    return Map<String, dynamic>.from(data as Map);
  }
}

class OwnerRewardIssuerScreen extends StatefulWidget {
  const OwnerRewardIssuerScreen({
    super.key,
    required this.client,
    this.gateway,
    this.invoiceBuilder,
  });
  final SupabaseClient client;
  final OwnerRewardIssuerGateway? gateway;
  final Widget Function(BuildContext, String)? invoiceBuilder;
  @override
  State<OwnerRewardIssuerScreen> createState() =>
      _OwnerRewardIssuerScreenState();
}

class _OwnerRewardIssuerScreenState extends State<OwnerRewardIssuerScreen> {
  late OwnerRewardIssuerGateway gateway;
  StreamSubscription<AuthState>? auth;
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic>? receipt;
  bool busy = false,
      invalid = false,
      failed = false,
      ready = false,
      more = false;
  int epoch = 0;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  bool active(int generation) =>
      mounted && !invalid && gateway.current && generation == epoch;
  @override
  void initState() {
    super.initState();
    gateway = widget.gateway ?? SupabaseOwnerRewardIssuerGateway(widget.client);
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final replay = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (replay || event.event == AuthChangeEvent.initialSession) return;
      if (mounted) {
        setState(() {
          invalid = true;
          epoch++;
          rows = [];
          receipt = null;
          busy = false;
          ready = false;
        });
      }
    });
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    auth?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OwnerRewardIssuerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.gateway != widget.gateway) {
      invalid = true;
      epoch++;
      rows = [];
      receipt = null;
      busy = false;
      ready = false;
    }
  }

  Future<void> load({bool append = false}) async {
    if (busy || invalid || !gateway.current) return;
    if (append && (!ready || rows.isEmpty || !more)) return;
    final cursor = append ? rows.last : null;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      receipt = null;
      if (!append) {
        ready = false;
        rows = [];
        more = false;
      }
    });
    try {
      final context = await gateway.call('get_owner_reward_issuer_context', {});
      if (!active(generation)) return;
      // This release is explicitly read-only. Unknown future capabilities fail closed.
      if (context['module'] != 'owner_reward_issuer_v1' ||
          context['owner_only'] != true ||
          context['spending_enabled'] != false ||
          context['can_prepare'] != false ||
          context['can_issue'] != false ||
          context['activation_available'] != false ||
          context['currency'] != 'EGP' ||
          context['unit'] != 'service_visits') {
        throw StateError('Unverified owner capabilities');
      }
      final data = await gateway.call('list_owner_reward_issues', {
        'p_before_created_at': cursor?['created_at'],
        'p_before_request': cursor?['request_id'],
        'p_limit': 25,
      });
      if (!active(generation)) return;
      if (data['spending_enabled'] != false ||
          data['items'] is! List ||
          (data['items'] as List).length > 25) {
        throw StateError('Unverified receipt list');
      }
      final actual = (data['items'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      for (final row in actual) {
        if (!_uuid.hasMatch('${row['request_id']}') ||
            !const {'prepared', 'issued', 'closed'}.contains(row['state']) ||
            DateTime.tryParse('${row['created_at']}') == null) {
          throw StateError('Invalid receipt');
        }
      }
      setState(() {
        final merged = append ? [...rows, ...actual] : actual;
        if (merged.map((row) => row['request_id']).toSet().length !=
            merged.length) {
          throw StateError('Repeated receipt cursor');
        }
        rows = merged;
        more = actual.length == 25;
        ready = true;
      });
    } catch (_) {
      if (active(generation)) {
        setState(() {
          failed = true;
          rows = [];
          receipt = null;
        });
      }
    } finally {
      if (active(generation)) setState(() => busy = false);
    }
  }

  Future<void> open(Map<String, dynamic> row) async {
    if (busy || !ready || invalid || !gateway.current) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      receipt = null;
    });
    try {
      final data = await gateway.call('get_owner_reward_issue', {
        'p_request': row['request_id'],
      });
      if (!active(generation)) return;
      if (data['request_id'] != row['request_id'] ||
          data['issuer_public_enabled'] != false ||
          !const {'prepared', 'issued', 'closed'}.contains(data['state'])) {
        throw StateError('Unverified receipt');
      }
      if (data['state'] == 'issued') {
        final result = data['result'];
        if (result is! Map ||
            result['currency'] != 'EGP' ||
            result['amount_due'] is! num ||
            result['amount_due'] != 0 ||
            result['gross_amount'] is! num ||
            !(result['gross_amount'] as num).isFinite ||
            result['gross_amount'] <= 0 ||
            result['reward_discount'] != result['gross_amount'] ||
            result['collectible'] != false ||
            !_uuid.hasMatch('${result['invoice_token']}')) {
          throw StateError('Unverified issued coverage');
        }
      }
      setState(() => receipt = data);
    } catch (_) {
      if (active(generation)) {
        setState(() {
          failed = true;
          receipt = null;
        });
      }
    } finally {
      if (active(generation)) setState(() => busy = false);
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  String stateName(Object? value) => switch (value) {
    'prepared' => t('محضّر ولم يصدر', 'Prepared, not issued'),
    'issued' => t('صادرة', 'Issued'),
    'closed' => t('مغلق', 'Closed'),
    _ => t('غير متاح', 'Unavailable'),
  };
  String money(num value) {
    var text = value.toStringAsFixed(2);
    if (ar) {
      text = text
          .replaceAllMapped(
            RegExp('[0-9]'),
            (m) => '٠١٢٣٤٥٦٧٨٩'[int.parse(m[0]!)],
          )
          .replaceAll('.', '٫');
    }
    return ar ? '$text جنيه مصري' : 'EGP $text';
  }

  String date(Object? value) {
    final parsed = DateTime.tryParse('$value')?.toLocal();
    if (parsed == null) return t('التاريخ غير متاح', 'Date unavailable');
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(parsed)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(parsed))}';
  }

  @override
  Widget build(BuildContext context) {
    final result = receipt?['result'] as Map?;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xff071a36),
        foregroundColor: Colors.white,
        title: Text(t('مكافآت زيارات الاستقبال', 'Reception visit rewards')),
        actions: [
          IconButton(
            onPressed: busy || invalid ? null : load,
            icon: const Icon(Icons.refresh),
            tooltip: t('تحديث', 'Refresh'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            t(
              'الصرف العام معطل. تعرض هذه الصفحة الإيصالات المصرح بها فقط، ولا تتيح تفعيل الصرف أو إصدار مكافأة جديدة.',
              'Public spending is disabled. This page shows authorized receipts only; it cannot activate spending or issue a new reward.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (invalid)
            Text(
              t(
                'تغيرت الجلسة. أعد فتح الصفحة بالحساب المصرح له.',
                'Session changed. Reopen with an authorized account.',
              ),
            ),
          if (failed)
            Text(
              t(
                'تعذر تحميل البيانات المصرح بها. لم تنفذ عملية مالية.',
                'Authorized data could not be loaded. No financial operation was performed.',
              ),
            ),
          if (ready && rows.isEmpty && !busy)
            Text(
              t(
                'لا توجد إيصالات مكافآت متاحة.',
                'No reward receipts are available.',
              ),
            ),
          for (final row in rows)
            Card(
              child: ListTile(
                title: Text(
                  row['invoice_number'] as String? ??
                      t('طلب مكافأة محفوظ', 'Saved reward request'),
                ),
                subtitle: Text(
                  '${stateName(row['state'])}\n${date(row['created_at'])}',
                ),
                onTap: busy || invalid ? null : () => open(row),
              ),
            ),
          if (ready && more)
            OutlinedButton(
              onPressed: busy || invalid ? null : () => load(append: true),
              child: Text(t('عرض إيصالات أقدم', 'Load older receipts')),
            ),
          if (receipt != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(stateName(receipt!['state'])),
                    if (result != null && receipt!['state'] == 'issued') ...[
                      Text(
                        '${t('الفاتورة', 'Invoice')}: ${result['invoice_number']}',
                      ),
                      Text(
                        '${t('حالة الخدمة', 'Service status')}: ${invoiceState(result['work_status'] as String?, ar)}',
                      ),
                      Text(
                        '${t('حالة الدفع', 'Payment status')}: ${invoiceState(result['payment_status'] as String?, ar)}',
                      ),
                      Text(
                        '${t('السعر الأصلي', 'Gross amount')}: ${money(result['gross_amount'] as num)}',
                      ),
                      Text(
                        '${t('خصم المكافأة', 'Reward discount')}: ${money(result['reward_discount'] as num)}',
                      ),
                      Text(
                        '${t('المستحق للتحصيل', 'Amount to collect')}: ${money(result['amount_due'] as num)}',
                      ),
                      OutlinedButton(
                        onPressed: invalid || busy
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (context) =>
                                      widget.invoiceBuilder?.call(
                                        context,
                                        result['invoice_token'] as String,
                                      ) ??
                                      InvoiceDocumentsScreen(
                                        client: widget.client,
                                        initialToken:
                                            result['invoice_token'] as String,
                                        role: 'owner',
                                      ),
                                ),
                              ),
                        child: Text(
                          t('عرض الفاتورة وPDF', 'View invoice and PDF'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
