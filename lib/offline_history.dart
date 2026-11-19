import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoice_presentation.dart';
import 'mixed_points_earnings.dart';
import 'invoices.dart';
import 'workflow.dart';

abstract class OfflineHistoryGateway {
  Future<Map<String, dynamic>> context();
  Future<Map<String, dynamic>> consent(
    String request,
    Map<String, dynamic> notice,
  );
  Future<Map<String, dynamic>> history(Map<String, dynamic>? cursor);
}

class SupabaseOfflineHistoryGateway implements OfflineHistoryGateway {
  SupabaseOfflineHistoryGateway(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> context() async => Map<String, dynamic>.from(
    await client.rpc('get_my_offline_history_context'),
  );
  @override
  Future<Map<String, dynamic>> consent(
    String request,
    Map<String, dynamic> notice,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'accept_my_offline_history_scope',
      params: {'p_request': request, 'p_consent': notice},
    ),
  );
  @override
  Future<Map<String, dynamic>> history(Map<String, dynamic>? cursor) async =>
      Map<String, dynamic>.from(
        await client.rpc(
          'get_my_offline_visit_history',
          params: {
            'p_before_created_at': cursor?['created_at'],
            'p_before_order': cursor?['order_id'],
            'p_limit': 25,
          },
        ),
      );
}

class OfflineHistoryScreen extends StatefulWidget {
  const OfflineHistoryScreen({
    super.key,
    required this.client,
    this.gateway,
    this.onOpenInvoice,
  });
  final SupabaseClient client;
  final OfflineHistoryGateway? gateway;
  final Future<void> Function(String token)? onOpenInvoice;
  @override
  State<OfflineHistoryScreen> createState() => _OfflineHistoryScreenState();
}

class _OfflineHistoryScreenState extends State<OfflineHistoryScreen>
    with WidgetsBindingObserver {
  late final OfflineHistoryGateway gateway;
  StreamSubscription<AuthState>? subscription;
  Map<String, dynamic>? contextData, cursor;
  final items = <Map<String, dynamic>>[];
  final consentRequest = newOrderRequestId();
  bool loading = true, accepted = false;
  String? error;
  int epoch = 0;
  static const navy = Color(0xff071a36),
      royal = Color(0xff174b83),
      silver = Color(0xffc5cbd5);
  String text(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    gateway = widget.gateway ?? SupabaseOfflineHistoryGateway(widget.client);
    WidgetsBinding.instance.addObserver(this);
    final initialSession = widget.client.auth.currentSession;
    var replayPending = true;
    subscription = widget.client.auth.onAuthStateChange.listen((state) {
      final sameInitialSession =
          replayPending && matchesInitialAuthReplay(state, initialSession);
      replayPending = false;
      if (sameInitialSession) return;
      if (state.event != AuthChangeEvent.initialSession) {
        epoch++;
        if (mounted) {
          setState(() {
            contextData = null;
            items.clear();
            cursor = null;
            accepted = false;
            loading = false;
            error = 'identity';
          });
        }
      }
    });
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool current(int requestEpoch, String? actor) =>
      mounted &&
      epoch == requestEpoch &&
      widget.client.auth.currentUser?.id == actor;
  Future<void> load() async {
    final requestEpoch = ++epoch, actor = widget.client.auth.currentUser?.id;
    setState(() {
      loading = true;
      error = null;
      contextData = null;
      items.clear();
      cursor = null;
      accepted = false;
    });
    try {
      final data = await gateway.context();
      if (!current(requestEpoch, actor)) return;
      if (data['state'] == 'available') {
        final page = await gateway.history(null);
        if (!current(requestEpoch, actor)) return;
        if (page['state'] != 'available') {
          throw StateError('History unavailable');
        }
        items.addAll(List<Map<String, dynamic>>.from(page['items']));
        cursor = page['next_cursor'] == null
            ? null
            : Map<String, dynamic>.from(page['next_cursor']);
      }
      setState(() {
        contextData = data;
        loading = false;
      });
    } catch (_) {
      if (current(requestEpoch, actor)) clearFailure();
    }
  }

  void clearFailure() => setState(() {
    items.clear();
    contextData = null;
    cursor = null;
    loading = false;
    error = 'unavailable';
  });
  Future<void> accept() async {
    if (loading || !accepted) return;
    final requestEpoch = epoch, actor = widget.client.auth.currentUser?.id;
    final consent = Map<String, dynamic>.from(contextData!['consent']);
    final language = Localizations.localeOf(context).languageCode == 'ar'
        ? 'ar'
        : 'en';
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await gateway.consent(consentRequest, {
        'accepted': true,
        'version': consent['version'],
        'language': language,
        'text': consent['notice_$language'],
      });
      if (current(requestEpoch, actor)) await load();
    } catch (_) {
      if (current(requestEpoch, actor)) clearFailure();
    }
  }

  Future<void> more() async {
    if (loading || cursor == null) return;
    final requestEpoch = epoch, actor = widget.client.auth.currentUser?.id;
    setState(() => loading = true);
    try {
      final page = await gateway.history(cursor);
      if (!current(requestEpoch, actor)) return;
      if (page['state'] != 'available') throw StateError('History unavailable');
      setState(() {
        final seen = items.map((row) => row['order_id']).toSet();
        items.addAll(
          List<Map<String, dynamic>>.from(page['items'])
              .where((row) => seen.add(row['order_id'])),
        );
        cursor = page['next_cursor'] == null
            ? null
            : Map<String, dynamic>.from(page['next_cursor']);
        loading = false;
      });
    } catch (_) {
      if (current(requestEpoch, actor)) clearFailure();
    }
  }

  Future<void> openInvoice(String token) async {
    if (widget.onOpenInvoice != null) {
      await widget.onOpenInvoice!(token);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => InvoiceDocumentsScreen(
            client: widget.client,
            role: 'customer',
            initialToken: token,
          ),
        ),
      );
    }
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) {
    final data = contextData,
        ar = Localizations.localeOf(context).languageCode == 'ar';
    final state = data?['state'];
    return Scaffold(
      backgroundColor: navy,
      appBar: AppBar(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        title: Text(text('سجل الاستقبال المرتبط', 'Linked reception history')),
        actions: [
          IconButton(
            onPressed: loading ? null : load,
            tooltip: text('تحديث', 'Refresh'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context).textTheme
              .apply(bodyColor: Colors.white, displayColor: Colors.white),
          checkboxTheme: CheckboxThemeData(
            fillColor: WidgetStatePropertyAll(royal),
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              text(
                'سجلات استقبال للقراءة فقط. لا تنقل ملكية السيارة ولا تمنح نقاطًا أو مكافآت.',
                'Read-only reception records. These do not transfer car ownership or grant points or rewards.',
              ),
              style: const TextStyle(color: silver),
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null)
              Text(
                text(
                  'تعذر التحقق من الوصول. حدّث الصفحة أو راجع المالك.',
                  'Access could not be verified. Refresh or contact the owner.',
                ),
              ),
            if (state == 'review_required')
              Text(
                text(
                  'يلزم ربط إيصال ومراجعة هوية سارية من المالك.',
                  'A receipt link and current owner-reviewed identity are required.',
                ),
              ),
            if (state == 'acceptance_pending')
              Text(
                text(
                  'تم تسجيل الموافقة؛ عرض السجلات لم يُفعّل بعد.',
                  'Consent recorded; history access has not been enabled yet.',
                ),
              ),
            if (state == 'consent_required') ...[
              Text('${data!['consent'][ar ? 'notice_ar' : 'notice_en']}'),
              CheckboxListTile(
                value: accepted,
                onChanged: loading
                    ? null
                    : (value) => setState(() => accepted = value == true),
                title: Text(
                  text(
                    'أوافق على نطاق عرض السجلات هذا',
                    'I agree to this history access scope',
                  ),
                ),
              ),
              FilledButton(
                onPressed: accepted && !loading ? accept : null,
                child: Text(text('تسجيل الموافقة', 'Record consent')),
              ),
            ],
            if (state == 'available') ...[
              MixedPointsEarningsPanel(
                key: ValueKey(widget.client.auth.currentUser?.id),
                client: widget.client,
              ),
              Text(
                text('سجلات السيارات لدى الاستقبال', 'Reception car records'),
                style: const TextStyle(fontSize: 20),
              ),
              for (final car in List<Map<String, dynamic>>.from(data!['cars']))
                ListTile(
                  textColor: Colors.white,
                  leading: const Icon(
                    Icons.directions_car_outlined,
                    color: silver,
                  ),
                  title: Text('${car['plate_number'] ?? '—'}'),
                  subtitle: Text(
                    [
                      car['brand'],
                      car['model'],
                      car['year'],
                    ].where((v) => v != null).join(' · '),
                    style: const TextStyle(color: silver),
                  ),
                ),
              if (items.isEmpty)
                Text(
                  text(
                    'لا توجد زيارات استقبال مسجلة.',
                    'No reception visits recorded.',
                  ),
                ),
              for (final row in items)
                Card(
                  color: royal,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${row['invoice_number'] ?? row['work_reference'] ?? '—'}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${ar ? row['service_name'] : row['service_name_en'] ?? row['service_name']}',
                        ),
                        Text(
                          '${row['car']?['plate_number'] ?? '—'} · ${row['branch']?[ar ? 'name_ar' : 'name_en'] ?? '—'}',
                        ),
                        Text(
                          '${invoiceState(row['service_status'], ar)} · ${invoiceState(row['payment_status'], ar)}',
                        ),
                        Text(
                          '${text('قيمة الفاتورة', 'Invoice face amount')}: ${row['invoice_total']} EGP',
                        ),
                        if (row['invoice_token'] is String)
                          OutlinedButton(
                            onPressed: loading
                                ? null
                                : () => openInvoice(row['invoice_token']),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            child: Text(text('فتح الفاتورة', 'Open invoice')),
                          ),
                      ],
                    ),
                  ),
                ),
              if (cursor != null)
                OutlinedButton(
                  onPressed: loading ? null : more,
                  child: Text(text('عرض المزيد', 'Load more')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
