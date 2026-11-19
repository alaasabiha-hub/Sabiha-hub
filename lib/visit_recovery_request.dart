import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

abstract class VisitRecoveryGateway {
  Future<Map<String, dynamic>> current();
  Future<Map<String, dynamic>> submit(
    String request,
    Map<String, dynamic> consent,
  );
  Future<Map<String, dynamic>> recover(String request);
  Future<Map<String, dynamic>> close(String request);
}

class SupabaseVisitRecoveryGateway implements VisitRecoveryGateway {
  SupabaseVisitRecoveryGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    final result = await client.rpc(name, params: parameters);
    if (client.auth.currentUser?.id != actor) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    return Map<String, dynamic>.from(result as Map);
  }

  @override
  Future<Map<String, dynamic>> current() =>
      call('get_my_visit_recovery_request', {'p_case': null});
  @override
  Future<Map<String, dynamic>> submit(
    String request,
    Map<String, dynamic> consent,
  ) => call('submit_visit_recovery_request', {
    'p_request': request,
    'p_consent': consent,
  });
  @override
  Future<Map<String, dynamic>> recover(String request) =>
      call('get_my_visit_recovery_submission', {'p_request': request});
  @override
  Future<Map<String, dynamic>> close(String request) =>
      call('close_my_visit_recovery_submission', {'p_request': request});
}

abstract class VisitRecoveryStore {
  Future<String?> read();
  Future<void> write(String request);
  Future<void> clear(String expectedRequest);
}

class SharedVisitRecoveryStore implements VisitRecoveryStore {
  SharedVisitRecoveryStore(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return 'visit_recovery_submission_uuid_$actor';
  }

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String request) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(key);
    if (existing != null && existing != request) {
      throw StateError('Resolve the saved request first');
    }
    if (!VisitRecoveryController.uuid.hasMatch(request) ||
        !await preferences.setString(key, request)) {
      throw StateError('Reference not saved');
    }
  }

  @override
  Future<void> clear(String expectedRequest) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(key);
    if (existing != null && existing != expectedRequest) {
      throw StateError('Saved request differs');
    }
    if (existing == null) return;
    if (!await preferences.remove(key)) {
      throw StateError('Reference not cleared');
    }
  }
}

class VisitRecoveryController extends ChangeNotifier {
  VisitRecoveryController({
    required this.gateway,
    required this.store,
    required this.currentActor,
  }) : actor = currentActor();
  final VisitRecoveryGateway gateway;
  final VisitRecoveryStore store;
  final String? Function() currentActor;
  final String? actor;
  static final uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  Map<String, dynamic>? view, _consent;
  String? requestId, error;
  String phase = 'idle';
  bool initialized = false, busy = false, _disposed = false;
  int _epoch = 0;
  bool get canSubmit =>
      initialized &&
      !busy &&
      requestId == null &&
      phase == 'idle' &&
      hasFreshConsent &&
      (view?['state'] == 'unavailable' ||
          (view?['new_request_allowed'] == true &&
              view?['case'] is Map &&
              [
                'rejected',
                'revoked',
              ].contains((view!['case'] as Map)['status'])));
  bool get hasFreshConsent {
    final consent = view?['consent'];
    return consent is Map &&
        consent['version'] == 'visit-recovery-v1' &&
        consent['notice_ar'] is String &&
        (consent['notice_ar'] as String).isNotEmpty &&
        consent['notice_en'] is String &&
        (consent['notice_en'] as String).isNotEmpty;
  }

  bool get canRetry =>
      !busy && phase == 'uncertain' && requestId != null && _consent != null;
  bool get canClose => !busy && phase == 'uncertain' && requestId != null;
  bool get canAcknowledge =>
      !busy && requestId != null && (phase == 'accepted' || phase == 'closed');
  bool current(int epoch) =>
      !_disposed && epoch == _epoch && actor != null && currentActor() == actor;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _epoch++;
    view = null;
    _consent = null;
    requestId = null;
    initialized = false;
    busy = false;
    phase = 'identity';
    error = 'identity';
    changed();
  }

  void validateConsent(Map<String, dynamic> value) {
    if (value['accepted'] != true ||
        value['version'] != 'visit-recovery-v1' ||
        !['ar', 'en'].contains(value['language']) ||
        value['text'] is! String ||
        (value['text'] as String).isEmpty) {
      throw StateError('Unconfirmed consent');
    }
  }

  void applyView(Map<String, dynamic> value) {
    if (value['state'] == 'available') {
      final result = value['case'];
      if (result is! Map ||
          result['case_id'] is! String ||
          !uuid.hasMatch(result['case_id'] as String) ||
          ![
            'awaiting_matching',
            'more_info',
            'rejected',
            'linked',
            'revoked',
          ].contains(result['status'])) {
        throw StateError('Unconfirmed case');
      }
    } else if (value['state'] == 'unavailable') {
      final consent = value['consent'];
      if (value['case'] != null ||
          consent is! Map ||
          consent['version'] != 'visit-recovery-v1' ||
          consent['notice_ar'] is! String ||
          consent['notice_en'] is! String) {
        throw StateError('Unconfirmed notice');
      }
    } else {
      throw StateError('Unconfirmed result');
    }
    view = Map<String, dynamic>.from(value);
  }

  void applyRecovery(Map<String, dynamic> value) {
    if (value['request_id'] != requestId) throw StateError('Request mismatch');
    if (value['state'] == 'accepted') {
      final payload = value['payload'], result = value['result'];
      if (value['definitive_failure'] != false ||
          payload is! Map ||
          payload['consent'] is! Map ||
          result is! Map ||
          result['state'] != 'available') {
        throw StateError('Unconfirmed receipt');
      }
      validateConsent(Map<String, dynamic>.from(payload['consent'] as Map));
      applyView(Map<String, dynamic>.from(result));
      phase = 'accepted';
      _consent = null;
    } else if (value['state'] == 'closed' &&
        value['definitive_failure'] == true &&
        value['payload'] == null &&
        value['result'] == null) {
      phase = 'closed';
      view = null;
      _consent = null;
    } else if (value['state'] == 'absent' &&
        value['definitive_failure'] == false &&
        value['payload'] == null &&
        value['result'] == null) {
      phase = 'uncertain';
      view = null;
    } else {
      throw StateError('Unconfirmed recovery');
    }
  }

  Future<void> run(Future<void> Function(int epoch) action) async {
    if (busy || _disposed) return;
    final epoch = _epoch;
    if (!current(epoch)) {
      error = 'identity';
      changed();
      return;
    }
    busy = true;
    error = null;
    changed();
    try {
      await action(epoch);
    } on PostgrestException catch (failure) {
      if (current(epoch)) {
        error = failure.code == '42501' ? 'identity' : 'unconfirmed';
        if (requestId != null && phase != 'accepted' && phase != 'closed') {
          phase = 'uncertain';
        }
      }
    } catch (_) {
      if (current(epoch)) {
        error = 'unconfirmed';
        if (requestId != null && phase != 'accepted' && phase != 'closed') {
          phase = 'uncertain';
        }
      }
    } finally {
      if (current(epoch)) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> initialize() => run((epoch) async {
    final saved = await store.read();
    if (!current(epoch)) return;
    if (saved != null && !uuid.hasMatch(saved)) {
      throw StateError('Invalid reference');
    }
    requestId = saved;
    initialized = true;
    if (saved != null) {
      phase = 'uncertain';
      final result = await gateway.recover(saved);
      if (current(epoch)) applyRecovery(result);
    } else {
      phase = 'idle';
      final result = await gateway.current();
      if (current(epoch)) applyView(result);
    }
  });
  Future<void> refresh() => requestId == null
      ? initialize()
      : run((epoch) async {
          final result = await gateway.recover(requestId!);
          if (current(epoch)) applyRecovery(result);
        });
  Future<void> submit(String language, {required bool accepted}) async {
    if (!canSubmit || !accepted || !['ar', 'en'].contains(language)) return;
    final notice = view!['consent'] as Map;
    await run((epoch) async {
      requestId = newOrderRequestId();
      _consent = Map<String, dynamic>.unmodifiable({
        'accepted': true,
        'version': notice['version'],
        'language': language,
        'text': notice['notice_$language'],
      });
      validateConsent(_consent!);
      phase = 'uncertain';
      await store.write(requestId!);
      if (!current(epoch)) return;
      final result = await gateway.submit(requestId!, _consent!);
      if (!current(epoch)) return;
      if (result['state'] == 'closed') {
        applyRecovery(result);
      } else {
        applyView(result);
        if (result['state'] != 'available') {
          throw StateError('Submission unconfirmed');
        }
        phase = 'accepted';
        _consent = null;
      }
    });
  }

  Future<void> retry() async {
    if (!canRetry) return;
    await run((epoch) async {
      await store.write(requestId!);
      if (!current(epoch)) return;
      final result = await gateway.submit(requestId!, _consent!);
      if (!current(epoch)) return;
      if (result['state'] == 'closed') {
        applyRecovery(result);
      } else {
        applyView(result);
        if (result['state'] != 'available') {
          throw StateError('Submission unconfirmed');
        }
        phase = 'accepted';
        _consent = null;
      }
    });
  }

  Future<void> close() async {
    if (!canClose) return;
    await run((epoch) async {
      final result = await gateway.close(requestId!);
      if (current(epoch)) applyRecovery(result);
    });
  }

  Future<void> acknowledge() async {
    if (!canAcknowledge) return;
    await run((epoch) async {
      final closed = phase == 'closed';
      await store.clear(requestId!);
      if (!current(epoch)) return;
      requestId = null;
      _consent = null;
      phase = 'idle';
      if (closed) {
        final result = await gateway.current();
        if (current(epoch)) applyView(result);
      }
    });
  }

  @override
  void dispose() {
    _epoch++;
    _disposed = true;
    super.dispose();
  }
}

class VisitRecoveryRequestPanel extends StatefulWidget {
  const VisitRecoveryRequestPanel({
    super.key,
    required this.client,
    this.gateway,
    this.store,
    this.onRequestChanged,
  });
  final SupabaseClient client;
  final VisitRecoveryGateway? gateway;
  final VisitRecoveryStore? store;
  final VoidCallback? onRequestChanged;
  @override
  State<VisitRecoveryRequestPanel> createState() =>
      _VisitRecoveryRequestPanelState();
}

class _VisitRecoveryRequestPanelState extends State<VisitRecoveryRequestPanel>
    with WidgetsBindingObserver {
  late final VisitRecoveryController controller;
  StreamSubscription<AuthState>? subscription;
  bool accepted = false;
  String text(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    controller = VisitRecoveryController(
      gateway: widget.gateway ?? SupabaseVisitRecoveryGateway(widget.client),
      store: widget.store ?? SharedVisitRecoveryStore(widget.client),
      currentActor: () => widget.client.auth.currentUser?.id,
    );
    WidgetsBinding.instance.addObserver(this);
    final initial = widget.client.auth.currentSession;
    var replay = true;
    subscription = widget.client.auth.onAuthStateChange.listen((event) {
      final same = replay && matchesInitialAuthReplay(event, initial);
      replay = false;
      if (same) return;
      if (event.event != AuthChangeEvent.initialSession && mounted) {
        setState(() => accepted = false);
        controller.invalidate();
      }
    });
    unawaited(controller.initialize());
  }

  Future<void> requestAction(Future<void> Function() action) async {
    final epoch = controller._epoch;
    await action();
    if (!mounted ||
        !controller.current(epoch) ||
        controller.error != null ||
        controller.phase == 'uncertain') {
      return;
    }
    widget.onRequestChanged?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(requestAction(controller.refresh));
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller,
          ar = Localizations.localeOf(context).languageCode == 'ar';
      final view = c.view, result = view?['case'];
      final suffix = ar ? 'ar' : 'en';
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                text('استرجاع زياراتي السابقة', 'Recover previous visits'),
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: const Color(0xff071a36)),
              ),
              const SizedBox(height: 12),
              if (c.busy) const LinearProgressIndicator(),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    c.error == 'identity'
                        ? text(
                            'تحقق من تسجيل الدخول وتأكيد البريد ورقم الهاتف المسجل. أعد فتح هذه الصفحة بعد تغيير الحساب.',
                            'Check sign-in, confirmed email and your registered phone. Reopen this page after changing accounts.',
                          )
                        : text(
                            'تعذر تأكيد النتيجة. احتفظ بالطلب نفسه وتحقق من حالته.',
                            'The outcome is unconfirmed. Keep this request and check its status.',
                          ),
                  ),
                ),
              if (view?['state'] == 'available' && result is Map) ...[
                Text(
                  '${view?['status_label_$suffix'] ?? ''}',
                  key: const ValueKey('recovery_status'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '${view?['receipt_message_$suffix'] ?? view?['pending_text_$suffix'] ?? ''}',
                  key: const ValueKey('recovery_receipt_message'),
                ),
                const SizedBox(height: 8),
                Text(
                  '${view?['notification_notice_$suffix'] ?? ''}',
                  key: const ValueKey('recovery_notification_notice'),
                ),
                if (result['identity_current'] == false)
                  Text(
                    text(
                      'تغيرت بيانات الحساب المسجلة وتحتاج إلى مراجعة مستقلة.',
                      'Registered account details changed and require independent review.',
                    ),
                  ),
              ],
              if (c.canSubmit) ...[
                Text(
                  '${(view!['consent'] as Map)['notice_$suffix']}',
                  key: const ValueKey('recovery_server_consent'),
                ),
                CheckboxListTile(
                  key: const ValueKey('recovery_consent'),
                  contentPadding: EdgeInsets.zero,
                  value: accepted,
                  onChanged: c.busy
                      ? null
                      : (value) => setState(() => accepted = value == true),
                  title: Text(
                    text(
                      'أوافق على طلب المراجعة بهذا النطاق',
                      'I agree to this review request scope',
                    ),
                  ),
                ),
                FilledButton(
                  key: const ValueKey('recovery_submit'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff174b83),
                  ),
                  onPressed: accepted
                      ? () => requestAction(
                          () => c.submit(ar ? 'ar' : 'en', accepted: accepted),
                        )
                      : null,
                  child: Text(
                    view['new_request_allowed'] == true
                        ? text(
                            'إرسال طلب جديد للمراجعة',
                            'Send a new request for review',
                          )
                        : text('إرسال طلب الاسترجاع', 'Send recovery request'),
                  ),
                ),
              ],
              if (c.phase == 'uncertain') ...[
                Text(
                  text(
                    'الطلب محفوظ ولم تُحسم نتيجته. لا تبدأ طلباً جديداً. الإغلاق الآمن يمنع الإرسال المتأخر ولا يلغي طلباً تم استلامه.',
                    'This request is saved and unresolved. Keep the same request. Safe close blocks a late submission and does not undo a received request.',
                  ),
                ),
                if (c.canRetry)
                  OutlinedButton(
                    key: const ValueKey('recovery_retry'),
                    onPressed: () => requestAction(c.retry),
                    child: Text(
                      text('إعادة إرسال الطلب نفسه', 'Retry the same request'),
                    ),
                  ),
                OutlinedButton(
                  key: const ValueKey('recovery_close'),
                  onPressed: c.canClose ? () => requestAction(c.close) : null,
                  child: Text(
                    text(
                      'إغلاق الإرسال غير المحسوم بأمان',
                      'Safely close unresolved submission',
                    ),
                  ),
                ),
              ],
              if (c.phase == 'closed')
                Text(
                  text(
                    'تم إغلاق هذا الإرسال بأمان. لم يُنشأ طلب جديد من هذا المرجع.',
                    'This submission was safely closed. No new request was created from this reference.',
                  ),
                  key: const ValueKey('recovery_closed'),
                ),
              if (c.canAcknowledge)
                FilledButton(
                  key: const ValueKey('recovery_acknowledge'),
                  onPressed: () async {
                    await requestAction(c.acknowledge);
                    if (mounted && c.phase == 'idle') {
                      setState(() => accepted = false);
                    }
                  },
                  child: Text(text('راجعت النتيجة', 'I reviewed the result')),
                ),
              TextButton(
                key: const ValueKey('recovery_refresh'),
                onPressed:
                    c.busy || widget.client.auth.currentUser?.id != c.actor
                    ? null
                    : () => requestAction(c.refresh),
                child: Text(text('تحديث حالة الطلب', 'Refresh request status')),
              ),
              const SizedBox(height: 8),
              Text(
                text(
                  'المطابقة ومراجعة الهوية لا تتمان تلقائياً. الهاتف وحده لا يثبت ملكية السجلات.',
                  'Matching and identity review are not automatic. Phone matching alone does not prove record ownership.',
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
