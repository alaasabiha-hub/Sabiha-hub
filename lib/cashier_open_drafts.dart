import 'dart:async';

import 'package:flutter/material.dart';

import 'cashier_invoice_draft.dart' show CashierCartGateway;

class CashierOpenDraftsScreen extends StatefulWidget {
  const CashierOpenDraftsScreen({
    super.key,
    required this.gateway,
    required this.branch,
  });
  final CashierCartGateway gateway;
  final String branch;
  @override
  State<CashierOpenDraftsScreen> createState() =>
      _CashierOpenDraftsScreenState();
}

class _CashierOpenDraftsScreenState extends State<CashierOpenDraftsScreen> {
  final rows = <Map<String, dynamic>>[];
  bool busy = false, more = true, sessionInvalidated = false;
  StreamSubscription<void>? sessionSubscription;
  int generation = 0;
  String? error;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String a, String e) => ar ? a : e;
  @override
  void initState() {
    super.initState();
    sessionSubscription = widget.gateway.changes.listen((_) {
      if (!mounted) return;
      generation++;
      setState(() {
        sessionInvalidated = true;
        rows.clear();
        error = null;
        busy = false;
      });
    });
    load();
  }

  @override
  void dispose() {
    generation++;
    sessionSubscription?.cancel();
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy || sessionInvalidated || !widget.gateway.current) return;
    final requestGeneration = generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final last = !reset && rows.isNotEmpty ? rows.last : null;
      final data = await widget.gateway.call('list_cashier_open_drafts', {
        'p_branch': widget.branch,
        'p_before_time': last?['updated_at'],
        'p_before_id': last?['draft_id'],
      });
      if (!mounted ||
          sessionInvalidated ||
          requestGeneration != generation ||
          !widget.gateway.current) {
        return;
      }
      if (data['scope'] != 'own_cashier_branch' ||
          data['loyalty_authorized'] != false) {
        throw StateError('Invalid scope');
      }
      setState(() {
        if (reset) rows.clear();
        rows.addAll(List<Map<String, dynamic>>.from(data['drafts']));
        more = data['has_more'] == true;
      });
    } catch (_) {
      if (mounted && requestGeneration == generation) {
        setState(
          () => error = t(
            'تعذر تحميل الفواتير المفتوحة.',
            'Unable to load open invoices.',
          ),
        );
      }
    } finally {
      if (mounted && requestGeneration == generation) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff5f7fa),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(t('الفواتير المفتوحة', 'Open invoices')),
    ),
    body: sessionInvalidated || !widget.gateway.current
        ? Center(child: Text(t('أعد تسجيل الدخول.', 'Sign in again.')))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  'مسودات حسابك في هذا الفرع. يُراجع السعر وحالة التحصيل عند الفتح.',
                  'Your drafts in this branch. Price and collection status are reviewed on opening.',
                ),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => load(reset: true),
                child: Text(t('تحديث', 'Refresh')),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
              if (rows.isEmpty && !busy)
                Text(t('لا توجد مسودات محفوظة.', 'No saved drafts.')),
              for (final row in rows)
                Card(
                  child: ListTile(
                    title: Text(
                      row['customer_name']?.toString() ??
                          t('عميل لم يحدد بعد', 'Customer not selected'),
                    ),
                    subtitle: Text(
                      '${(row['car'] as Map?)?['plate_number'] ?? ''}\n${row['line_count']} ${t('بند', 'lines')} · ${row['total']} EGP\n${row['state'] == 'issued' ? t('صدرت الفاتورة؛ راجع التحصيل', 'Invoice issued; review collection') : t('مسودة مفتوحة', 'Open draft')}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: busy
                        ? null
                        : () =>
                              Navigator.pop(context, row['draft_id'] as String),
                  ),
                ),
              if (more)
                OutlinedButton(
                  onPressed: busy ? null : () => load(),
                  child: Text(t('المزيد', 'More')),
                ),
            ],
          ),
  );
}
