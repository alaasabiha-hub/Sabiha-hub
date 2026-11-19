import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;
import 'invoices.dart' show matchesInitialAuthReplay;

const offlineClaimNoticeVersion = 'offline-claim-v1';
const offlineClaimNoticeEnglish =
    'I request owner review to link this reception receipt to my confirmed app account. I consent to this identity review. Phone matching alone is not proof. History and rewards remain unavailable until secure access is implemented.';
const offlineClaimNoticeArabic =
    'أطلب مراجعة المالك لربط إيصال الاستقبال بحسابي المؤكد في التطبيق وأوافق على مراجعة الهوية. تطابق الهاتف وحده ليس إثباتاً. تبقى السجلات والمكافآت غير متاحة حتى تنفيذ الوصول الآمن.';

abstract class OfflineClaimGateway {
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters);
}

class SupabaseOfflineClaimGateway implements OfflineClaimGateway {
  SupabaseOfflineClaimGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    return client.rpc(name, params: parameters);
  }
}

abstract class OfflineClaimStore {
  Future<String?> read();
  Future<void> write(String requestId);
  Future<void> clear();
}

/// Only the request UUID is retained locally, never receipt proof or review notes.
class SharedOfflineClaimStore implements OfflineClaimStore {
  SharedOfflineClaimStore(this.client, {required this.owner})
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final bool owner;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Session changed');
    }
    return 'offline_claim_${owner ? 'owner_command' : 'customer_request'}_uuid_$actor';
  }

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String requestId) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      requestId,
    )) {
      throw StateError('Reference was not saved');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Reference was not cleared');
    }
  }
}

Map<String, dynamic> _map(dynamic value) =>
    Map<String, dynamic>.from(value as Map);
Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    _map(jsonDecode(jsonEncode(value)));

abstract class _ClaimFlow extends ChangeNotifier {
  _ClaimFlow({required this.gateway, required this.store});
  final OfflineClaimGateway gateway;
  final OfflineClaimStore store;
  String? requestId, error;
  bool busy = false, initialized = false, disposed = false;
  bool invalidated = false;
  int sessionEpoch = 0;
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) async {
    if (disposed || invalidated) throw StateError('Session changed');
    final generation = sessionEpoch;
    final value = await gateway.rpc(name, parameters);
    if (disposed || invalidated || generation != sessionEpoch) {
      throw StateError('Session changed');
    }
    return value;
  }

  void invalidate() {
    sessionEpoch++;
    invalidated = true;
    requestId = null;
    busy = false;
    initialized = false;
    error = 'session_changed';
    changed();
  }

  bool get locked => invalidated || !initialized || busy || requestId != null;
  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy || disposed || invalidated) return;
    busy = true;
    error = null;
    changed();
    try {
      await work();
    } on PostgrestException catch (exception) {
      if (!invalidated) {
        error = exception.code == '42501' ? 'access_denied' : 'not_confirmed';
      }
    } catch (_) {
      if (!invalidated) error = 'not_confirmed';
    } finally {
      busy = false;
      changed();
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class CustomerOfflineClaimController extends _ClaimFlow {
  CustomerOfflineClaimController({
    required super.gateway,
    required super.store,
  });
  Map<String, dynamic>? result, _payload;
  String? receiptReference;
  @override
  void invalidate() {
    _payload?.remove('p_secret');
    _payload = null;
    result = null;
    receiptReference = null;
    super.invalidate();
  }

  String get status => result?['status']?.toString() ?? 'unconfirmed';
  bool get hasReceipt => const [
    'verification_failed',
    'pending_owner_review',
    'stale_identity_review_required',
    'approved_pending_reader_bridge',
    'rejected',
    'expired',
    'revoked',
  ].contains(status);
  bool get canStartAgain => const [
    'verification_failed',
    'rejected',
    'expired',
    'revoked',
  ].contains(status);
  bool get canRetry => requestId != null && _payload != null && !hasReceipt;
  void apply(Map<String, dynamic> response) {
    if (disposed || invalidated) return;
    if (response['request_id'] != requestId) {
      error = 'not_confirmed';
      return;
    }
    result = response;
    if (hasReceipt) {
      _payload?.remove('p_secret');
      _payload = null;
    } else {
      error = 'not_confirmed';
    }
  }

  Future<void> initialize() => run(() async {
    final saved = await store.read();
    if (disposed || invalidated) return;
    requestId = saved;
    initialized = true;
    if (requestId != null) {
      apply(
        _map(
          await rpc('get_my_offline_customer_claim', {'p_request': requestId}),
        ),
      );
    }
  });
  Future<void> submit(Map<String, dynamic> values) => run(() async {
    if (!initialized || requestId != null) return;
    final id = newOrderRequestId();
    await store.write(id);
    if (disposed || invalidated) return;
    requestId = id;
    receiptReference = values['p_receipt'] as String?;
    _payload = _copy({...values, 'p_request': id});
    apply(_map(await rpc('request_offline_customer_claim', _payload!)));
  });
  Future<void> refresh() => run(() async {
    if (requestId != null) {
      apply(
        _map(
          await rpc('get_my_offline_customer_claim', {'p_request': requestId}),
        ),
      );
    }
  });
  Future<void> retry() => run(() async {
    if (canRetry) {
      apply(_map(await rpc('request_offline_customer_claim', _payload!)));
    }
  });
  Future<void> startAgain() => run(() async {
    if (!canStartAgain) return;
    await store.clear();
    requestId = null;
    result = null;
    _payload = null;
    receiptReference = null;
  });
  @override
  void dispose() {
    _payload?.remove('p_secret');
    _payload = null;
    super.dispose();
  }
}

class OwnerOfflineClaimController extends _ClaimFlow {
  OwnerOfflineClaimController({
    required super.gateway,
    required super.store,
    this.branchId,
  });
  final String? branchId;
  List<Map<String, dynamic>> reviews = [];
  Map<String, dynamic> view = {'state': 'idle'};
  String? _kind;
  Map<String, dynamic>? _payload;
  @override
  void invalidate() {
    reviews = [];
    view = {'state': 'session_changed'};
    _payload = null;
    _kind = null;
    super.invalidate();
  }

  String get state => view['state']?.toString() ?? 'unknown';
  bool get succeeded => state == 'succeeded';
  bool get canRetry =>
      requestId != null &&
      !succeeded &&
      state != 'manual_review_required' &&
      (view['payload'] is Map || _payload != null);
  Future<void> apply(Map<String, dynamic> response) async {
    if (disposed || invalidated) return;
    if (response['request_id'] != requestId) {
      error = 'not_confirmed';
      return;
    }
    view = response;
    if (state == 'closed') {
      await store.clear();
      requestId = null;
      _kind = null;
      _payload = null;
    }
  }

  Future<void> loadReviews() async {
    try {
      final value = await rpc('list_offline_customer_claim_reviews', {
        'p_branch': branchId,
      });
      reviews = (value as List).map(_map).toList();
    } catch (_) {
      reviews = [];
      rethrow;
    }
  }

  Future<void> initialize() => run(() async {
    final saved = await store.read();
    if (disposed || invalidated) return;
    requestId = saved;
    initialized = true;
    if (requestId != null) {
      await apply(
        _map(
          await rpc('get_offline_customer_claim_command', {
            'p_request': requestId,
          }),
        ),
      );
    }
    await loadReviews();
  });
  Future<void> refresh() => run(() async {
    if (requestId != null) {
      await apply(
        _map(
          await rpc('get_offline_customer_claim_command', {
            'p_request': requestId,
          }),
        ),
      );
    }
    await loadReviews();
  });
  Future<void> execute() async {
    if (disposed || invalidated || state != 'open') return;
    final kind = view['kind'];
    final payload = _map(view['payload']);
    final endpoint = kind == 'decide'
        ? 'decide_offline_customer_claim'
        : kind == 'revoke'
        ? 'revoke_offline_customer_link'
        : null;
    if (endpoint == null) throw StateError('Unknown command');
    final result = _map(
      await rpc(endpoint, {'p_request': requestId, ...payload}),
    );
    final valid = kind == 'decide'
        ? result['claim_id'] == payload['p_claim'] &&
              result['decision'] == payload['p_decision']
        : result['link_id'] == payload['p_link'] &&
              result['status'] == 'revoked';
    if (!valid) throw StateError('Command receipt mismatch');
    await apply({...view, 'state': 'succeeded', 'result': result});
    _payload = null;
    _kind = null;
    await loadReviews();
  }

  Future<void> submit(String kind, Map<String, dynamic> payload) =>
      run(() async {
        if (!initialized || requestId != null) return;
        final id = newOrderRequestId();
        await store.write(id);
        if (disposed || invalidated) return;
        requestId = id;
        _kind = kind;
        _payload = _copy(payload);
        await apply(
          _map(
            await rpc('prepare_offline_claim_command', {
              'p_request': id,
              'p_kind': kind,
              'p_payload': _payload,
            }),
          ),
        );
        await execute();
      });
  Future<void> retry() => run(() async {
    if (!canRetry) return;
    await apply(
      _map(
        await rpc('get_offline_customer_claim_command', {
          'p_request': requestId,
        }),
      ),
    );
    if (state == 'absent' && _payload != null && _kind != null) {
      await apply(
        _map(
          await rpc('prepare_offline_claim_command', {
            'p_request': requestId,
            'p_kind': _kind,
            'p_payload': _payload,
          }),
        ),
      );
    }
    await execute();
  });
  Future<void> close() => run(() async {
    if (requestId == null || succeeded || state == 'manual_review_required') {
      return;
    }
    await apply(
      _map(await rpc('close_offline_claim_command', {'p_request': requestId})),
    );
    await loadReviews();
  });
  Future<void> acknowledge() => run(() async {
    if (!succeeded) return;
    await store.clear();
    requestId = null;
    _payload = null;
    _kind = null;
    view = {'state': 'idle'};
    await loadReviews();
  });
}

String _text(BuildContext context, String en, String ar) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
String? _requiredUuid(String? value) =>
    value != null &&
        RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(value.trim())
    ? null
    : 'uuid';
const _navy = Color(0xff071a36),
    _royal = Color(0xff174b83),
    _silver = Color(0xffc5cbd5);
Widget _reference(BuildContext context, String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      SelectableText(value, textDirection: TextDirection.ltr),
    ],
  ),
);
Widget _boundary(BuildContext context) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Text(
    _text(
      context,
      'Identity review does not give access to previous visits, cars, invoices, wallet or rewards yet.',
      'مراجعة الهوية لا تتيح حالياً الوصول إلى الزيارات أو السيارات أو الفواتير السابقة أو الرصيد أو المكافآت.',
    ),
    style: const TextStyle(color: _navy),
  ),
);
Widget _button(String key, String label, VoidCallback? action) => FilledButton(
  key: ValueKey(key),
  style: FilledButton.styleFrom(
    backgroundColor: _royal,
    foregroundColor: Colors.white,
  ),
  onPressed: action,
  child: Text(label),
);
Widget _page(BuildContext context, String title, List<Widget> children) =>
    Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: children,
          ),
        ),
      ),
    );

StreamSubscription<AuthState> _watchClaimSession(
  SupabaseClient client,
  VoidCallback invalidate,
) {
  final initial = client.auth.currentSession;
  var first = true;
  return client.auth.onAuthStateChange.listen((event) {
    final same = first && matchesInitialAuthReplay(event, initial);
    first = false;
    if (same) return;
    if (event.event != AuthChangeEvent.initialSession) invalidate();
  });
}

class CustomerOfflineClaimScreen extends StatefulWidget {
  const CustomerOfflineClaimScreen({
    super.key,
    required this.client,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final OfflineClaimGateway? gateway;
  final OfflineClaimStore? store;
  @override
  State<CustomerOfflineClaimScreen> createState() =>
      _CustomerOfflineClaimScreenState();
}

class _CustomerOfflineClaimScreenState
    extends State<CustomerOfflineClaimScreen> {
  final form = GlobalKey<FormState>();
  final receipt = TextEditingController(), secret = TextEditingController();
  late final CustomerOfflineClaimController flow;
  bool lost = false, consent = false, showSecret = false;
  StreamSubscription<AuthState>? authSubscription;
  String t(String en, String ar) => _text(context, en, ar);
  bool get arabic => Localizations.localeOf(context).languageCode == 'ar';
  @override
  void initState() {
    super.initState();
    flow = CustomerOfflineClaimController(
      gateway: widget.gateway ?? SupabaseOfflineClaimGateway(widget.client),
      store:
          widget.store ?? SharedOfflineClaimStore(widget.client, owner: false),
    )..addListener(changed);
    authSubscription = _watchClaimSession(widget.client, () {
      receipt.clear();
      secret.clear();
      lost = false;
      consent = false;
      showSecret = false;
      flow.invalidate();
    });
    flow.initialize();
  }

  void changed() {
    if (mounted) {
      if (flow.hasReceipt && secret.text.isNotEmpty) secret.clear();
      setState(() {});
    }
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    flow.removeListener(changed);
    flow.dispose();
    receipt.dispose();
    secret.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate() || !consent) return;
    await flow.submit({
      'p_receipt': receipt.text.trim(),
      'p_secret': lost ? null : secret.text.trim(),
      'p_mode': lost ? 'lost_secret_review' : 'original_receipt',
      'p_consent': {
        'accepted': true,
        'version': offlineClaimNoticeVersion,
        'text': arabic ? offlineClaimNoticeArabic : offlineClaimNoticeEnglish,
        'language': arabic ? 'ar' : 'en',
      },
    });
  }

  String statusLabel() => switch (flow.status) {
    'pending_owner_review' => t(
      'Request received · owner review required',
      'تم استلام الطلب · مراجعة المالك مطلوبة',
    ),
    'approved_pending_reader_bridge' => t(
      'Identity evidence approved · access is not available yet',
      'تمت الموافقة على إثبات الهوية · الوصول غير متاح حالياً',
    ),
    'verification_failed' => t(
      'The evidence could not be confirmed',
      'تعذر تأكيد الإثبات',
    ),
    'stale_identity_review_required' => t(
      'Account or contact details changed · ask the owner to review',
      'تغيّرت بيانات الحساب أو الاتصال · اطلب مراجعة المالك',
    ),
    'rejected' => t('Review request declined', 'تم رفض طلب المراجعة'),
    'expired' => t('Review request expired', 'انتهت مهلة طلب المراجعة'),
    'revoked' => t('Identity approval revoked', 'تم إلغاء الموافقة على الهوية'),
    _ => t('The request is not confirmed', 'لم يتم تأكيد الطلب'),
  };
  @override
  Widget build(
    BuildContext context,
  ) => _page(context, t('Reception receipt review', 'مراجعة إيصال الاستقبال'), [
    Text(
      t('Use your original reception receipt', 'استخدم إيصال الاستقبال الأصلي'),
      style: Theme.of(context).textTheme.headlineSmall,
    ),
    Text(
      t(
        'Your app account email must be confirmed. The owner must approve the evidence; a phone match is insufficient.',
        'يجب تأكيد بريد حسابك في التطبيق. يجب أن يوافق المالك على الإثبات؛ تطابق الهاتف غير كافٍ.',
      ),
    ),
    _boundary(context),
    if (flow.busy) const LinearProgressIndicator(color: _royal),
    if (flow.invalidated)
      Text(
        t(
          'Session changed. Reopen this screen with the correct account.',
          'تغيرت الجلسة. أعد فتح هذه الشاشة بالحساب الصحيح.',
        ),
      ),
    if (flow.error != null && !flow.invalidated)
      Text(
        flow.error == 'access_denied'
            ? t(
                'Sign in to your own app account before requesting review.',
                'سجّل الدخول إلى حسابك في التطبيق قبل طلب المراجعة.',
              )
            : t(
                'Keep the saved reference and check its status. Do not create another request while its result is unknown.',
                'احتفظ بالمرجع المحفوظ وافحص الحالة. لا تنشئ طلباً آخر ما دامت النتيجة غير معروفة.',
              ),
      ),
    if (!flow.initialized && !flow.busy)
      OutlinedButton(
        onPressed: flow.initialize,
        child: Text(t('Check session again', 'فحص الجلسة مجدداً')),
      ),
    if (flow.requestId != null) ...[
      _reference(
        context,
        t('Review request reference', 'مرجع طلب المراجعة'),
        flow.requestId!,
      ),
      if (flow.receiptReference != null)
        _reference(
          context,
          t('Original receipt reference', 'مرجع الإيصال الأصلي'),
          flow.receiptReference!,
        ),
      Text(
        statusLabel(),
        key: const ValueKey('claim_status'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (flow.status == 'verification_failed')
        Text(
          t(
            'Check the receipt and your account email confirmation, or ask the owner for help. No identity or access has been granted.',
            'تحقق من الإيصال وتأكيد بريد حسابك، أو اطلب مساعدة المالك. لم يتم منح إثبات هوية أو صلاحية وصول.',
          ),
        ),
      if (flow.status == 'revoked')
        Text(
          t(
            'The original receipt cannot be reused after an approved link is revoked. Ask the owner about new continuity evidence.',
            'لا يمكن إعادة استخدام الإيصال الأصلي بعد إلغاء الربط المعتمد. اسأل المالك عن إثبات استمرارية جديد.',
          ),
        ),
      OutlinedButton(
        key: const ValueKey('refresh_claim'),
        onPressed: flow.busy ? null : flow.refresh,
        child: Text(t('Check my review status', 'فحص حالة طلبي')),
      ),
      if (flow.canRetry)
        _button(
          'retry_claim',
          t('Retry the exact same request', 'إعادة الطلب نفسه بالضبط'),
          flow.busy ? null : flow.retry,
        ),
      if (!flow.hasReceipt && !flow.canRetry)
        Text(
          t(
            'This device no longer holds the proof. Keep this reference and ask the owner for help; an unavailable result does not prove failure.',
            'لم يعد الإثبات محفوظاً على هذا الجهاز. احتفظ بالمرجع واطلب مساعدة المالك؛ النتيجة غير المتاحة لا تثبت فشل الطلب.',
          ),
        ),
      if (flow.canStartAgain)
        _button(
          'new_claim',
          t(
            'Acknowledge result and start a new review',
            'تأكيد النتيجة وبدء مراجعة جديدة',
          ),
          flow.busy
              ? null
              : () async {
                  await flow.startAgain();
                  if (mounted && !flow.locked) {
                    setState(() {
                      receipt.clear();
                      secret.clear();
                      consent = false;
                      lost = false;
                    });
                  }
                },
        ),
    ],
    if (!flow.hasReceipt)
      Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const ValueKey('receipt_reference'),
              controller: receipt,
              enabled: !flow.locked,
              decoration: InputDecoration(
                labelText: t(
                  'Original receipt reference',
                  'مرجع الإيصال الأصلي',
                ),
                helperMaxLines: 3,
                helperText: t(
                  'Use the receipt reference, not the registration request reference.',
                  'استخدم مرجع الإيصال وليس مرجع طلب التسجيل.',
                ),
                border: const OutlineInputBorder(),
              ),
              validator: (value) => _requiredUuid(value) == null
                  ? null
                  : t(
                      'Enter the receipt reference printed on your receipt',
                      'أدخل مرجع الإيصال المطبوع على إيصالك',
                    ),
            ),
            CheckboxListTile(
              key: const ValueKey('lost_receipt_code'),
              contentPadding: EdgeInsets.zero,
              value: lost,
              onChanged: flow.locked
                  ? null
                  : (value) => setState(() {
                      lost = value == true;
                      secret.clear();
                    }),
              title: Text(
                t(
                  'I lost the original private code and need an owner continuity review',
                  'فقدت الرمز السري الأصلي وأحتاج مراجعة المالك لاستمرارية الهوية',
                ),
              ),
            ),
            if (!lost)
              TextFormField(
                key: const ValueKey('receipt_secret'),
                controller: secret,
                enabled: !flow.locked,
                obscureText: !showSecret,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                decoration: InputDecoration(
                  labelText: t(
                    'Original private receipt code',
                    'رمز الإيصال السري الأصلي',
                  ),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => showSecret = !showSecret),
                    tooltip: t(
                      'Show or hide the code',
                      'إظهار الرمز أو إخفاؤه',
                    ),
                    icon: Icon(
                      showSecret ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
                validator: (value) =>
                    value != null &&
                        RegExp(r'^[0-9a-f]{64}$').hasMatch(value.trim())
                    ? null
                    : t(
                        'Enter the original 64-character receipt code',
                        'أدخل رمز الإيصال الأصلي المكوّن من 64 خانة',
                      ),
              ),
            const SizedBox(height: 16),
            Text(arabic ? offlineClaimNoticeArabic : offlineClaimNoticeEnglish),
            CheckboxListTile(
              key: const ValueKey('claim_consent'),
              contentPadding: EdgeInsets.zero,
              value: consent,
              onChanged: flow.locked
                  ? null
                  : (value) => setState(() => consent = value == true),
              title: Text(
                t(
                  'I agree to this identity review',
                  'أوافق على مراجعة الهوية هذه',
                ),
              ),
            ),
            _button(
              'submit_claim',
              t('Request owner identity review', 'طلب مراجعة الهوية من المالك'),
              flow.locked ? null : submit,
            ),
          ],
        ),
      ),
  ]);
}

class OwnerOfflineClaimReviewsScreen extends StatefulWidget {
  const OwnerOfflineClaimReviewsScreen({
    super.key,
    required this.client,
    this.branchId,
    this.gateway,
    this.store,
  });
  final SupabaseClient client;
  final String? branchId;
  final OfflineClaimGateway? gateway;
  final OfflineClaimStore? store;
  @override
  State<OwnerOfflineClaimReviewsScreen> createState() =>
      _OwnerOfflineClaimReviewsScreenState();
}

class _OwnerOfflineClaimReviewsScreenState
    extends State<OwnerOfflineClaimReviewsScreen> {
  late final OwnerOfflineClaimController flow;
  final reason = TextEditingController();
  String? selected, evidence;
  bool attested = false;
  StreamSubscription<AuthState>? authSubscription;
  String t(String en, String ar) => _text(context, en, ar);
  @override
  void initState() {
    super.initState();
    flow = OwnerOfflineClaimController(
      gateway: widget.gateway ?? SupabaseOfflineClaimGateway(widget.client),
      store:
          widget.store ?? SharedOfflineClaimStore(widget.client, owner: true),
      branchId: widget.branchId,
    )..addListener(changed);
    authSubscription = _watchClaimSession(widget.client, () {
      reason.clear();
      selected = null;
      evidence = null;
      attested = false;
      flow.invalidate();
    });
    flow.initialize();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    flow.removeListener(changed);
    flow.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> decide(Map<String, dynamic> row, String decision) =>
      flow.submit('decide', {
        'p_claim': row['claim_id'],
        'p_decision': decision,
        'p_reason': reason.text.trim(),
        'p_evidence_type': decision == 'approve_exception' ? evidence : null,
      });
  Widget review(Map<String, dynamic> row) {
    final id = row['claim_id'].toString();
    final active = selected == id;
    final status = row['status'];
    final pending = status == 'pending_owner_review';
    final current =
        row['confirmed_account_current'] == true &&
        row['contact_current'] == true;
    final ready = !flow.locked && reason.text.trim().length >= 10;
    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _silver),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              row['name']?.toString() ??
                  t('Reception customer', 'عميل الاستقبال'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(switch (status) {
              'approved_pending_reader_bridge' => t(
                'Evidence approved · access unavailable',
                'تمت الموافقة على الإثبات · الوصول غير متاح',
              ),
              'rejected' => t('Declined', 'مرفوض'),
              'expired' => t('Expired', 'منتهي المهلة'),
              'revoked' => t('Revoked', 'ملغى'),
              _ => t('Awaiting owner review', 'بانتظار مراجعة المالك'),
            }),
            Text(
              row['secret_proved'] == true
                  ? t(
                      'Original receipt proof confirmed',
                      'تم تأكيد إثبات الإيصال الأصلي',
                    )
                  : t(
                      'Original receipt proof unavailable',
                      'إثبات الإيصال الأصلي غير متاح',
                    ),
            ),
            Text(
              current
                  ? t(
                      'Account confirmation and contact details are current',
                      'تأكيد الحساب وبيانات الاتصال ساريان',
                    )
                  : t(
                      'Account or contact details need a fresh review; approval is blocked',
                      'تحتاج بيانات الحساب أو الاتصال مراجعة جديدة؛ الموافقة محظورة',
                    ),
            ),
            _reference(context, t('Review reference', 'مرجع المراجعة'), id),
            OutlinedButton(
              key: ValueKey('select_$id'),
              onPressed: flow.locked
                  ? null
                  : () => setState(() {
                      selected = active ? null : id;
                      evidence = null;
                      attested = false;
                      reason.clear();
                    }),
              child: Text(
                active
                    ? t('Close details', 'إغلاق التفاصيل')
                    : t('Review evidence', 'مراجعة الإثبات'),
              ),
            ),
            if (active) ...[
              TextField(
                key: const ValueKey('owner_review_reason'),
                controller: reason,
                enabled: !flow.locked,
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: t(
                    'Actual review evidence and reason',
                    'الإثبات الفعلي وسبب القرار',
                  ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (pending) ...[
                if (row['mode'] == 'lost_secret_review') ...[
                  DropdownButtonFormField<String>(
                    key: const ValueKey('continuity_evidence'),
                    initialValue: evidence,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        'Continuity evidence checked in person',
                        'إثبات الاستمرارية الذي تم فحصه حضورياً',
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'in_person_original_service_documents',
                        child: Text(
                          t(
                            'Original service documents',
                            'مستندات الخدمة الأصلية',
                          ),
                          maxLines: 2,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'in_person_independent_continuity_witness',
                        child: Text(
                          t(
                            'Independent continuity witness',
                            'شاهد مستقل لاستمرارية الهوية',
                          ),
                          maxLines: 2,
                        ),
                      ),
                    ],
                    onChanged: flow.locked
                        ? null
                        : (value) => setState(() => evidence = value),
                  ),
                  CheckboxListTile(
                    key: const ValueKey('continuity_attestation'),
                    contentPadding: EdgeInsets.zero,
                    value: attested,
                    onChanged: flow.locked
                        ? null
                        : (value) => setState(() => attested = value == true),
                    title: Text(
                      t(
                        'I checked this evidence in person. A phone match alone is insufficient.',
                        'فحصت هذا الإثبات حضورياً. تطابق الهاتف وحده غير كافٍ.',
                      ),
                    ),
                  ),
                  _button(
                    'approve_exception',
                    t(
                      'Approve the documented continuity exception',
                      'الموافقة على استثناء الاستمرارية الموثق',
                    ),
                    ready && current && evidence != null && attested
                        ? () => decide(row, 'approve_exception')
                        : null,
                  ),
                ] else
                  _button(
                    'approve_with_secret',
                    t(
                      'Approve the reviewed original receipt evidence',
                      'الموافقة على إثبات الإيصال الأصلي بعد مراجعته',
                    ),
                    ready && current && row['secret_proved'] == true
                        ? () => decide(row, 'approve_with_secret')
                        : null,
                  ),
                OutlinedButton(
                  key: const ValueKey('hold_claim'),
                  onPressed: ready ? () => decide(row, 'hold') : null,
                  child: Text(t('Record hold', 'تسجيل تعليق المراجعة')),
                ),
                OutlinedButton(
                  key: const ValueKey('reject_claim'),
                  onPressed: ready ? () => decide(row, 'reject') : null,
                  child: Text(t('Decline this request', 'رفض هذا الطلب')),
                ),
              ],
              if (status == 'approved_pending_reader_bridge' &&
                  row['link_id'] != null)
                _button(
                  'revoke_link',
                  t('Revoke identity approval', 'إلغاء الموافقة على الهوية'),
                  ready
                      ? () => flow.submit('revoke', {
                          'p_link': row['link_id'],
                          'p_reason': reason.text.trim(),
                        })
                      : null,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget pendingCommand() {
    final result = flow.view['result'] as Map?;
    final command = flow.view['payload'] as Map?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _reference(
              context,
              t('Owner action reference', 'مرجع إجراء المالك'),
              flow.requestId!,
            ),
            Text(
              flow.succeeded
                  ? t('Owner action recorded', 'تم تسجيل إجراء المالك')
                  : t(
                      'Owner action is not confirmed; all review controls are locked',
                      'لم يتأكد إجراء المالك؛ تم قفل جميع أدوات المراجعة',
                    ),
            ),
            if (result?['status'] == 'approved_pending_reader_bridge')
              Text(
                t(
                  'Identity evidence approved. Previous history and rewards remain unavailable.',
                  'تمت الموافقة على إثبات الهوية. السجلات السابقة والمكافآت ما زالت غير متاحة.',
                ),
              ),
            if (result?['status'] == 'revoked')
              Text(
                t(
                  'Identity approval revoked. The original receipt cannot be reused.',
                  'تم إلغاء الموافقة على الهوية. لا يمكن إعادة استخدام الإيصال الأصلي.',
                ),
              ),
            if (command?['p_reason'] is String)
              Text(command!['p_reason'] as String),
            OutlinedButton(
              key: const ValueKey('recover_owner_command'),
              onPressed: flow.busy ? null : flow.refresh,
              child: Text(
                t('Check saved owner action', 'فحص إجراء المالك المحفوظ'),
              ),
            ),
            if (flow.canRetry)
              _button(
                'retry_owner_command',
                t(
                  'Retry the exact prepared action',
                  'إعادة الإجراء المُعد نفسه بالضبط',
                ),
                flow.busy ? null : flow.retry,
              ),
            if (!flow.succeeded && flow.state != 'manual_review_required')
              OutlinedButton(
                key: const ValueKey('close_owner_command'),
                onPressed: flow.busy ? null : flow.close,
                child: Text(
                  t(
                    'Close the unconfirmed action safely',
                    'إغلاق الإجراء غير المؤكد بأمان',
                  ),
                ),
              ),
            if (flow.succeeded)
              _button(
                'ack_owner_command',
                t('Acknowledge this result', 'تأكيد هذه النتيجة'),
                flow.busy ? null : flow.acknowledge,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      _page(context, t('Owner identity reviews', 'مراجعات الهوية للمالك'), [
        _boundary(context),
        if (flow.busy) const LinearProgressIndicator(color: _royal),
        if (flow.invalidated)
          Text(
            t(
              'Session changed. Reopen this screen with the correct account.',
              'تغيرت الجلسة. أعد فتح هذه الشاشة بالحساب الصحيح.',
            ),
          ),
        if (flow.error != null && !flow.invalidated)
          Text(
            flow.error == 'access_denied'
                ? t(
                    'An active owner account is required for these reviews.',
                    'تحتاج هذه المراجعات حساب مالك نشطاً.',
                  )
                : t(
                    'The result is not confirmed. Keep the reference and recover or safely close the prepared action.',
                    'لم تتأكد النتيجة. احتفظ بالمرجع واسترجع الإجراء المُعد أو أغلقه بأمان.',
                  ),
          ),
        OutlinedButton(
          key: const ValueKey('refresh_reviews'),
          onPressed: flow.busy
              ? null
              : (flow.initialized ? flow.refresh : flow.initialize),
          child: Text(t('Refresh identity reviews', 'تحديث مراجعات الهوية')),
        ),
        if (flow.requestId != null) pendingCommand(),
        if (flow.initialized &&
            !flow.busy &&
            flow.reviews.isEmpty &&
            flow.error == null)
          Text(
            t(
              'No identity review requests in this scope',
              'لا توجد طلبات مراجعة هوية ضمن هذا النطاق',
            ),
          ),
        ...flow.reviews.map(review),
      ]);
}
