import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'mixed_points_live.dart';
import 'invoices.dart' show matchesInitialAuthReplay;

/// Read-only point entitlements. This panel never combines legacy balances or
/// treats an earned balance as authorization to redeem it.
class MixedPointsEarningsPanel extends StatefulWidget {
  const MixedPointsEarningsPanel({
    super.key,
    required this.client,
    this.hintTransport,
    this.fallbackInterval = const Duration(seconds: 60),
  });
  final SupabaseClient client;
  final MixedPointsHintTransport? hintTransport;
  final Duration fallbackInterval;
  @override
  State<MixedPointsEarningsPanel> createState() =>
      _MixedPointsEarningsPanelState();
}

class _MixedPointsEarningsPanelState extends State<MixedPointsEarningsPanel>
    with WidgetsBindingObserver {
  Map<String, dynamic>? data;
  bool loading = true, failed = false;
  int epoch = 0;
  late final String? scopeActor;
  MixedPointsHintTransport? hints;
  Timer? fallback;
  bool frozen = false, reading = false, readAgain = false, foreground = true;
  bool get current =>
      mounted && !frozen && widget.client.auth.currentUser?.id == scopeActor;
  void wake() {
    if (current && foreground) unawaited(load());
  }

  Future<void> connectHints() async {
    try {
      await hints?.connect(onHint: wake, onReconnect: wake);
    } catch (_) {
      /* Authorized reads/resume/fallback remain available. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && current) {
      unawaited(connectHints());
      wake();
    }
  }

  StreamSubscription<AuthState>? subscription;
  String t(String a, String e) =>
      Localizations.localeOf(context).languageCode == 'ar' ? a : e;
  @override
  void initState() {
    super.initState();
    scopeActor = widget.client.auth.currentUser?.id;
    WidgetsBinding.instance.addObserver(this);
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (widget.hintTransport != null ||
        widget.client.auth.currentSession != null) {
      hints = widget.hintTransport ?? SupabaseMixedPointsHints(widget.client);
      unawaited(connectHints());
      if (widget.fallbackInterval > Duration.zero) {
        fallback = Timer.periodic(widget.fallbackInterval, (_) {
          if (current && foreground) {
            unawaited(connectHints());
            wake();
          }
        });
      }
    }
    final initial = widget.client.auth.currentSession;
    var replay = true;
    subscription = widget.client.auth.onAuthStateChange.listen((event) {
      final initialReplay = replay && matchesInitialAuthReplay(event, initial);
      replay = false;
      if (initialReplay) return;
      if (event.event == AuthChangeEvent.tokenRefreshed &&
          widget.client.auth.currentUser?.id == scopeActor &&
          current) {
        unawaited(hints?.reauthenticate().catchError((Object _) {}));
        wake();
        return;
      }
      if (event.event != AuthChangeEvent.initialSession && mounted) {
        frozen = true;
        fallback?.cancel();
        unawaited(hints?.close());
        epoch++;
        setState(() {
          data = null;
          loading = false;
          failed = true;
        });
      }
    });
    load();
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    fallback?.cancel();
    unawaited(hints?.close());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!current) return;
    if (reading) {
      readAgain = true;
      return;
    }
    reading = true;
    try {
      do {
        readAgain = false;
        await readBalance();
      } while (readAgain && current && foreground);
    } finally {
      reading = false;
    }
  }

  Future<void> readBalance() async {
    final generation = ++epoch, actor = widget.client.auth.currentUser?.id;
    try {
      final result = Map<String, dynamic>.from(
        await widget.client.rpc('get_my_mixed_points_earnings'),
      );
      if (!mounted ||
          generation != epoch ||
          widget.client.auth.currentUser?.id != actor) {
        return;
      }
      if (result['unit'] != 'reward_points_v1' ||
          result['legacy_converted'] != false ||
          result['redemption_available'] != false ||
          result['buckets'] is! List) {
        throw const FormatException('Invalid point scope');
      }
      for (final bucket in result['buckets'] as List) {
        for (final key in [
          'earned_points',
          'refund_offsets',
          'net_earned_points',
          if (bucket.containsKey('available_points')) ...[
            'available_points',
            'reserved_points',
            'redeemed_points',
          ],
        ]) {
          if (bucket[key] is! String ||
              BigInt.tryParse(bucket[key] as String) == null) {
            throw const FormatException('Exact point amounts required');
          }
        }
      }
      setState(() {
        data = result;
        failed = false;
        loading = false;
      });
    } catch (error) {
      if (!mounted ||
          generation != epoch ||
          widget.client.auth.currentUser?.id != actor) {
        return;
      }
      // An older local schema has no new program; do not fabricate a zero balance.
      if (error is PostgrestException && error.code == 'PGRST202') {
        setState(() {
          data = null;
          failed = false;
          loading = false;
        });
        return;
      }
      setState(() {
        data = null;
        failed = true;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const LinearProgressIndicator();
    if (failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t(
              'تعذر التحقق من نقاط الولاء. حدّث الصفحة.',
              'Loyalty points could not be verified. Refresh the page.',
            ),
          ),
          if (current)
            OutlinedButton(
              onPressed: load,
              child: Text(t('تحديث النقاط', 'Refresh points')),
            ),
        ],
      );
    }
    if (data?['has_earnings'] != true) return const SizedBox.shrink();
    return Card(
      color: const Color(0xff071a36),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('نقاط الولاء المسجلة', 'Recorded loyalty points'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              t(
                'تُحفظ النقاط وفق الشروط المسجلة عند الفاتورة. الاستبدال غير متاح حاليًا.',
                'Points retain the terms recorded with each invoice. Redemption is not enabled.',
              ),
              style: const TextStyle(color: Color(0xffc5cbd5)),
            ),
            for (final bucket in data!['buckets'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${bucket['net_earned_points']} ${t('نقطة مسجلة', 'recorded points')}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${t('مكتسب', 'Earned')}: ${bucket['earned_points']} · ${t('تسويات الاسترداد', 'Refund offsets')}: ${bucket['refund_offsets']}',
                      style: const TextStyle(color: Color(0xffc5cbd5)),
                    ),
                    if (bucket['available_points'] is String)
                      Text(
                        '${t('غير مستخدم', 'Unused')}: ${bucket['available_points']} · ${t('محجوز', 'Reserved')}: ${bucket['reserved_points']} · ${t('مستبدل بعد الاستردادات', 'Redeemed after returns')}: ${bucket['redeemed_points']}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    if (bucket['review_required'] == true)
                      Text(
                        t(
                          'بانتظار مراجعة المالك بعد الاسترداد.',
                          'Awaiting owner review after a refund.',
                        ),
                        style: const TextStyle(color: Colors.white),
                      ),
                  ],
                ),
              ),
            OutlinedButton(
              onPressed: current ? load : null,
              child: Text(
                t('تحديث النقاط', 'Refresh points'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
