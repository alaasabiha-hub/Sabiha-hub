import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'emergency_reception_vault.dart';

abstract class EmergencyReceptionGateway {
  String? get actor;
  Stream<void> get authChanges;
  Future<void> probe();
  Future<Map<String, dynamic>> submit(Map<String, dynamic> request);
}

class SupabaseEmergencyReceptionGateway implements EmergencyReceptionGateway {
  final SupabaseClient client;
  final Session? session;
  SupabaseEmergencyReceptionGateway(this.client)
    : session = client.auth.currentSession;
  @override
  String? get actor =>
      client.auth.currentSession?.accessToken == session?.accessToken
      ? session?.user.id
      : null;
  @override
  Stream<void> get authChanges => client.auth.onAuthStateChange
      .where(
        (e) =>
            e.session?.accessToken != session?.accessToken ||
            e.event == AuthChangeEvent.signedOut,
      )
      .map((_) {});
  void check() {
    if (actor == null) throw StateError('Staff session changed');
  }

  @override
  Future<void> probe() async {
    check();
    await client.rpc('get_wash_reception_queue', params: {'p_branch': null}).timeout(const Duration(seconds: 20));
    check();
  }

  @override
  Future<Map<String, dynamic>> submit(Map<String, dynamic> request) async {
    check();
    final value = await client.rpc('update_wash_reception', params: request).timeout(const Duration(seconds: 20));
    check();
    return Map<String, dynamic>.from(value as Map);
  }
}

typedef EmergencyJournalFactory = EmergencyReceptionJournal Function(
  String password,
  bool Function() current,
);

/// Only a local draft until the existing authorized reception RPC accepts it.
class EmergencyReceptionScreen extends StatefulWidget {
  final EmergencyReceptionGateway gateway;
  final EmergencyVaultStore? store;
  final EmergencyJournalFactory? journalFactory;
  final Map<String, dynamic>? candidate;
  const EmergencyReceptionScreen({
    super.key,
    required this.gateway,
    this.store,
    this.journalFactory,
    this.candidate,
  });
  @override
  State<EmergencyReceptionScreen> createState() =>
      _EmergencyReceptionScreenState();
}

class _EmergencyReceptionScreenState extends State<EmergencyReceptionScreen> {
  final password = TextEditingController(),
      confirmation = TextEditingController();
  late final EmergencyVaultStore store;
  late final String? actor;
  StreamSubscription<void>? subscription;
  EmergencyReceptionJournal? journal;
  List<Map<String, dynamic>> rows = [];
  bool busy = true, invalid = false, creating = false, captured = false;
  String? error;
  String connection = 'unchecked';
  int epoch = 0;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  bool get active =>
      mounted && !invalid && actor != null && widget.gateway.actor == actor;
  bool current(int generation) => active && generation == epoch;
  void invalidate() {
    if (!mounted) return;
    journal?.lock();
    journal = null;
    password.clear();
    confirmation.clear();
    if (mounted) {
      setState(() {
        invalid = true;
        epoch++;
        rows = [];
        busy = false;
        error = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    store = widget.store ?? PreferencesEmergencyVaultStore();
    actor = widget.gateway.actor;
    if (actor == null) {
      invalid = true;
      busy = false;
      return;
    }
    subscription = widget.gateway.authChanges.listen((_) => invalidate());
    checkExisting();
  }

  Future<void> checkExisting() async {
    try {
      if (actor == null) throw StateError('Staff required');
      final raw = await store.read(emergencyVaultStorageKey(actor!));
      if (active) setState(() => creating = raw == null);
    } catch (_) {
      if (active) {
        setState(
          () => error = t(
            'التخزين المحلي غير متاح. لم تُحفظ أي مسودة.',
            'Local storage unavailable. No draft was saved.',
          ),
        );
      }
    } finally {
      if (active) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    epoch++;
    subscription?.cancel();
    journal?.lock();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  String failureText(Object value) {
    if (value is EmergencyVaultException) {
      return switch (value.code) {
        'invalid_unlock' => t(
          'استخدم عبارة محلية من 12 حرفًا على الأقل.',
          'Use a local passphrase of at least 12 characters.',
        ),
        'corrupt_or_wrong_key' => t(
          'تعذر فتح السجل. راجع العبارة المحلية؛ لم تُستبدل البيانات المحفوظة.',
          'Unable to unlock. Check the passphrase; saved data was not replaced.',
        ),
        'capacity' => t(
          'السجل المحلي بلغ حده. احتفظ به وراجع الإدارة قبل تسجيل المزيد.',
          'Local journal is full. Preserve it and contact management before adding more.',
        ),
        'resolution_required' => t(
          'أُرسل هذا الطلب؛ يجب التحقق من نتيجته قبل إغلاقه.',
          'This request was sent; resolve its outcome before closing it.',
        ),
        'receipt_mismatch' => t(
          'لم يتطابق إقرار الخادم. المسودة محفوظة للمراجعة.',
          'Server receipt did not match. The draft remains for review.',
        ),
        _ => t(
          'لم يتأكد الحفظ المحلي. احتفظ بالسجل وأعد المحاولة.',
          'Local save was not confirmed. Preserve the journal and try again.',
        ),
      };
    }
    if (value is PostgrestException) {
      return switch (value.code) {
        '42501' => t(
          'انتهت الجلسة أو الصلاحية. أعد الدخول قبل المزامنة.',
          'Session or permission expired. Sign in before syncing.',
        ),
        '40001' => t(
          'تغير استقبال الحجز. المسودة محفوظة كمشكلة تحتاج مراجعة.',
          'Booking reception changed. The draft is retained for review.',
        ),
        '55000' || '22023' => t(
          'شروط الاستقبال غير متاحة. المسودة محفوظة دون فرض التغيير.',
          'Reception requirements are not met. The draft is retained without forcing a change.',
        ),
        _ => t(
          'نتيجة المزامنة غير مؤكدة. أعد نفس الطلب دون إنشاء بديل.',
          'Sync outcome is uncertain. Retry the same request without creating a replacement.',
        ),
      };
    }
    return t(
      'الاتصال أو التخزين غير متاح. البيانات المحفوظة لم تُحذف.',
      'Connection or storage unavailable. Saved data was not deleted.',
    );
  }

  Future<void> unlock() async {
    if (!active || busy) return;
    if (creating && password.text != confirmation.text) {
      setState(
        () =>
            error = t('العبارتان غير متطابقتين.', 'Passphrases do not match.'),
      );
      return;
    }
    final generation = epoch;
    setState(() {
      busy = true;
      error = null;
    });
    EmergencyReceptionJournal? opened;
    try {
      opened =
          widget.journalFactory?.call(password.text, () => active) ??
          EmergencyReceptionVault(
            store: store,
            actor: actor!,
            password: password.text,
            current: () => active,
          );
      final data = await opened.list();
      if (!current(generation)) {
        opened.lock();
        return;
      }
      journal = opened;
      rows = data;
      creating = false;
      password.clear();
      confirmation.clear();
      final candidate = widget.candidate;
      if (candidate != null && !captured) {
        await opened.enqueue(
          request: Map<String, dynamic>.from(candidate['request'] as Map),
          branch: candidate['branch_id'] as String,
          reference: candidate['reference'] as String?,
          deviceTime: DateTime.tryParse(
            candidate['device_time'] as String? ?? '',
          ),
        );
        if (!current(generation)) return;
        captured = true;
        rows = await opened.list();
        if (!current(generation)) return;
      }
    } catch (value) {
      opened?.lock();
      if (current(generation)) {
        setState(() {
          journal = null;
          rows = [];
          password.clear();
          confirmation.clear();
          error = failureText(value);
        });
      }
    } finally {
      if (current(generation)) setState(() => busy = false);
    }
  }

  Future<void> probe() async {
    if (!active || busy) return;
    final generation = epoch;
    setState(() => busy = true);
    try {
      await widget.gateway.probe();
      if (current(generation)) {
        setState(() {
          connection = 'connected';
          error = null;
        });
      }
    } catch (value) {
      if (current(generation)) {
        setState(() {
          connection = value is PostgrestException && value.code == '42501'
              ? 'denied'
              : 'unavailable';
          error = failureText(value);
        });
      }
    } finally {
      if (current(generation)) setState(() => busy = false);
    }
  }

  Future<void> sync(Map<String, dynamic> row) async {
    final vault = journal;
    if (!active || busy || vault == null) return;
    final generation = epoch;
    final id = (row['request'] as Map)['p_request'] as String;
    var dispatched = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.probe();
      if (!current(generation)) return;
      connection = 'connected';
      final prepared = await vault.beginDispatch(id);
      if (!current(generation)) return;
      dispatched = true;
      final receipt = await widget.gateway.submit(
        Map<String, dynamic>.from(prepared['request'] as Map),
      );
      if (!current(generation)) return;
      await vault.confirm(id, receipt);
      if (!current(generation)) return;
      final refreshed = await vault.list();
      if (!current(generation)) return;
      rows = refreshed;
    } catch (value) {
      if (!current(generation)) return;
      if (dispatched) {
        try {
          await vault.failure(
            id,
            definitive:
                value is PostgrestException &&
                const {'40001', '42501', '22023', '55000'}.contains(value.code),
          );
        } catch (_) {
          /* Preserve the durable pre-dispatch uncertainty fence. */
        }
      }
      if (!current(generation)) return;
      connection = value is PostgrestException ? 'connected' : 'unavailable';
      error = failureText(value);
      if (value is PostgrestException && value.code == '42501') {
        invalidate();
        return;
      }
      try {
        final refreshed = await vault.list();
        if (!current(generation)) return;
        rows = refreshed;
      } catch (_) {
        /* Never replace a failed local read with an empty journal. */
      }
    } finally {
      if (current(generation)) setState(() => busy = false);
    }
  }

  Future<void> cancel(Map<String, dynamic> row) async {
    final vault = journal;
    if (!active || busy || vault == null) return;
    final generation = epoch;
    setState(() => busy = true);
    try {
      await vault.cancelUnsent((row['request'] as Map)['p_request'] as String);
      if (!current(generation)) return;
      final refreshed = await vault.list();
      if (!current(generation)) return;
      rows = refreshed;
    } catch (value) {
      if (current(generation)) error = failureText(value);
    } finally {
      if (current(generation)) setState(() => busy = false);
    }
  }

  String stateLabel(String state) => switch (state) {
    'pending' => t('محفوظ محليًا · لم يزامن', 'Saved locally · not synced'),
    'uncertain' => t('نتيجة المزامنة غير مؤكدة', 'Sync outcome uncertain'),
    'conflict' => t('تعارض محفوظ للمراجعة', 'Conflict retained for review'),
    'confirmed' => t('إقرار خادم محفوظ', 'Server receipt saved'),
    'cancelled' => t('ألغيت قبل الإرسال', 'Cancelled before sending'),
    _ => '—',
  };
  String reference(Map<String, dynamic> row) =>
      row['reference'] as String? ??
      '#${((row['request'] as Map)['p_booking'] as String).substring(0, 8).toUpperCase()}';
  String deviceStamp(dynamic raw) {
    final date = raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
    if (date == null) return '—';
    final local = MaterialLocalizations.of(context);
    return '${local.formatFullDate(date)} · ${local.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        t('سجل الاستقبال وقت الطوارئ', 'Emergency reception journal'),
      ),
      actions: [
        if (journal != null)
          IconButton(
            tooltip: t('قفل السجل المحلي', 'Lock local journal'),
            onPressed: busy
                ? null
                : () {
                    journal?.lock();
                    setState(() {
                      journal = null;
                      rows = [];
                      epoch++;
                    });
                  },
            icon: const Icon(Icons.lock_outline),
          ),
      ],
    ),
    body: invalid
        ? Center(
            child: Text(
              t(
                'تغيّرت الجلسة. أعد فتح السجل بحسابك.',
                'Session changed. Reopen the journal with your account.',
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t(
                  'مسودات استقبال فقط؛ لا إصدار فاتورة أو تأكيد دفع أو نقاط أو حجز سعة دون اتصال. لا يتغير طابور الخادم حتى قبول المزامنة بصلاحياتك الحالية.',
                  'Reception drafts only; no invoice, payment, points or capacity reservation offline. The server queue changes only after sync is accepted with your current permissions.',
                ),
              ),
              Text(switch (connection) {
                'connected' => t(
                  'آخر تحقق: الخادم متاح',
                  'Last check: server available',
                ),
                'unavailable' => t(
                  'الخادم غير متاح أو الاتصال منقطع',
                  'Server unavailable or connection lost',
                ),
                'denied' => t(
                  'التحقق من الهوية أو الصلاحية مطلوب',
                  'Identity or permission check required',
                ),
                _ => t(
                  'اتصال الخادم غير متحقق',
                  'Server connection not checked',
                ),
              }),
              TextButton(
                onPressed: busy ? null : probe,
                child: Text(
                  t(
                    'تحقق من الاتصال والصلاحيات',
                    'Check connection and access',
                  ),
                ),
              ),
              if (error != null) Text(error!),
              if (busy) const LinearProgressIndicator(),
              if (journal == null) ...[
                Text(
                  t(
                    'استخدم عبارة محلية طويلة مختلفة عن كلمة دخول حسابك. لا تُحفظ ولا تُرسل. لا يمكن فتح المسودات إذا فقدتها؛ لا تعيد تهيئة السجل عند فشل الفتح.',
                    'Use a long local passphrase different from your sign-in password. It is neither saved nor sent. Lost passphrases cannot unlock drafts; do not reset the journal after an unlock failure.',
                  ),
                ),
                if (widget.candidate != null && !captured)
                  Text(
                    t(
                      'سيُحفظ الاستقبال الذي اخترته محليًا بعد فتح السجل فقط.',
                      'Your selected arrival will be saved locally only after unlocking.',
                    ),
                  ),
                TextField(
                  key: const ValueKey('emergency-passphrase'),
                  controller: password,
                  obscureText: true,
                  enabled: !busy,
                  maxLength: 256,
                  decoration: InputDecoration(
                    labelText: t(
                      'العبارة المحلية للطوارئ',
                      'Local emergency passphrase',
                    ),
                  ),
                ),
                if (creating)
                  TextField(
                    key: const ValueKey('emergency-confirm-passphrase'),
                    controller: confirmation,
                    obscureText: true,
                    enabled: !busy,
                    maxLength: 256,
                    decoration: InputDecoration(
                      labelText: t(
                        'تأكيد العبارة المحلية',
                        'Confirm local passphrase',
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: busy ? null : unlock,
                  child: Text(
                    t('فتح السجل المشفر', 'Unlock encrypted journal'),
                  ),
                ),
              ] else ...[
                if (rows.isEmpty)
                  Text(t('لا توجد مسودات محفوظة.', 'No saved drafts.')),
                ...rows.reversed.map(
                  (row) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            reference(row),
                            textDirection: TextDirection.ltr,
                          ),
                          Text(stateLabel(row['state'] as String)),
                          Text((row['request'] as Map)['p_reason'] as String),
                          Text(
                            t(
                              'وقت الجهاز غير موثق: ${deviceStamp(row['created_at'])}',
                              'Unverified device time: ${deviceStamp(row['created_at'])}',
                            ),
                          ),
                          if (row['state'] == 'confirmed')
                            Text(
                              t(
                                'هذا إقرار للعملية السابقة؛ حدّث طابور الاستقبال للحالة الحالية.',
                                'This acknowledges the earlier operation; refresh reception for its current state.',
                              ),
                            ),
                          if (![
                            'confirmed',
                            'cancelled',
                          ].contains(row['state']))
                            FilledButton(
                              onPressed: busy ? null : () => sync(row),
                              child: Text(
                                t(
                                  'مزامنة مع تحقق الخادم',
                                  'Sync with server verification',
                                ),
                              ),
                            ),
                          if (row['dispatch_started'] == false &&
                              row['state'] == 'pending')
                            TextButton(
                              onPressed: busy ? null : () => cancel(row),
                              child: Text(
                                t(
                                  'إلغاء المسودة غير المرسلة',
                                  'Cancel unsent draft',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
  );
}
