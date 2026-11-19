import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

const offlineRegistrationConsentVersion = 'offline-registration-v1';
const offlineRegistrationConsentEnglish =
    'I agree to record my name, phone and car details for service reception. This does not authorize marketing, app account linking or reward redemption.';
const offlineRegistrationConsentArabic =
    'أوافق على تسجيل اسمي ورقم هاتفي وبيانات سيارتي لاستقبال الخدمة. لا يشمل ذلك التسويق أو ربط حساب تطبيق أو استبدال المكافآت.';

String _asciiDigits(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var result = value;
  for (var digit = 0; digit < 10; digit++) {
    result = result
        .replaceAll(arabic[digit], '$digit')
        .replaceAll(persian[digit], '$digit');
  }
  return result;
}

bool validOfflineRegistrationPhone(String value) {
  if (value.length > 64) return false;
  var normalized = _asciiDigits(value.trim())
      .replaceAll(RegExp(r'[\s()\-.]'), '');
  if (normalized.startsWith('00')) normalized = '+${normalized.substring(2)}';
  if (RegExp(r'^01[0-9]{9}$').hasMatch(normalized) ||
      RegExp(r'^0[2-9][0-9]{8}$').hasMatch(normalized)) {
    normalized = '+20${normalized.substring(1)}';
  }
  return RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(normalized);
}

abstract class OfflineRegistrationGateway {
  Future<Map<String, dynamic>> register(Map<String, dynamic> parameters);
  Future<Map<String, dynamic>> recover(String requestId);
  Future<Map<String, dynamic>> close(String requestId, String branchId);
}

class SupabaseOfflineRegistrationGateway implements OfflineRegistrationGateway {
  SupabaseOfflineRegistrationGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  void _checkActor() {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
  }

  @override
  Future<Map<String, dynamic>> register(Map<String, dynamic> parameters) async {
    _checkActor();
    return Map<String, dynamic>.from(
      await client.rpc('register_offline_customer', params: parameters) as Map,
    );
  }

  @override
  Future<Map<String, dynamic>> recover(String requestId) async {
    _checkActor();
    return Map<String, dynamic>.from(
      await client.rpc(
        'get_offline_customer_registration',
        params: {'p_request': requestId},
      ) as Map,
    );
  }

  @override
  Future<Map<String, dynamic>> close(String requestId, String branchId) async {
    _checkActor();
    return Map<String, dynamic>.from(
      await client.rpc(
        'close_offline_customer_registration',
        params: {'p_request': requestId, 'p_branch': branchId},
      ) as Map,
    );
  }
}

abstract class OfflineRegistrationStore {
  Future<String?> read();
  Future<void> write(String requestId);
  Future<void> clear();
}

/// Local storage contains only a UUID, scoped to the staff account and branch.
class SharedOfflineRegistrationStore implements OfflineRegistrationStore {
  SharedOfflineRegistrationStore(this.client, this.branch)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String branch;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return 'offline_registration_uuid_${actor}_$branch';
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
      throw StateError('Request reference could not be saved');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Request reference could not be cleared');
    }
  }
}

class OfflineRegistrationController extends ChangeNotifier {
  OfflineRegistrationController({
    required this.gateway,
    required this.store,
    required this.branchId,
  });
  final String branchId;
  final OfflineRegistrationGateway gateway;
  final OfflineRegistrationStore store;
  String? requestId, errorCode, enrollmentSecret;
  Map<String, dynamic>? receipt;
  Map<String, dynamic>? _pending;
  bool initialized = false, busy = false, _disposed = false;
  bool get resolved => [
    'created_unverified',
    'reused_unverified',
    'review_required',
    'closed',
  ].contains(receipt?['status']);
  bool get locked => !initialized || busy || requestId != null;
  bool get canClose =>
      initialized &&
      !busy &&
      requestId != null &&
      !resolved &&
      errorCode != 'access_denied' &&
      (receipt?['status'] == 'absent' ||
          _pending == null ||
          errorCode == 'unconfirmed');
  bool get canRetry => requestId != null && _pending != null && !resolved;
  bool get canCreateSeparate =>
      receipt?['status'] == 'review_required' && _pending != null;
  bool get secretWasLost =>
      receipt?['enrollment_secret_issued'] == true && enrollmentSecret == null;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() work) async {
    if (busy || _disposed) return;
    busy = true;
    errorCode = null;
    _changed();
    try {
      await work();
    } on PostgrestException catch (error) {
      errorCode = error.code == '42501' ? 'access_denied' : 'unconfirmed';
    } catch (_) {
      errorCode = 'unconfirmed';
    } finally {
      busy = false;
      _changed();
    }
  }

  void _apply(Map<String, dynamic> response, {bool firstResponse = false}) {
    if (_disposed) return;
    if (response['request_id'] != requestId) {
      errorCode = 'unconfirmed';
      return;
    }
    if (response['status'] == 'closed' &&
        (response['branch_id'] != branchId ||
            response['registration_created'] != false ||
            response['definitive_failure'] != true ||
            response['may_retry_same_request'] != false)) {
      errorCode = 'unconfirmed';
      return;
    }
    final safe = Map<String, dynamic>.from(response);
    final secret = safe.remove('enrollment_secret');
    if (firstResponse &&
        safe['status'] == 'created_unverified' &&
        safe['enrollment_secret_issued'] == true &&
        secret is String &&
        secret.isNotEmpty) {
      enrollmentSecret = secret;
    }
    receipt = safe;
    if (!resolved) errorCode = 'unconfirmed';
  }

  Future<void> initialize() => _run(() async {
    requestId = await store.read();
    initialized = true;
    if (requestId != null) _apply(await gateway.recover(requestId!));
  });

  Future<void> submit(Map<String, dynamic> parameters) => _run(() async {
    if (!initialized || requestId != null) return;
    final id = newOrderRequestId();
    // Persist before dispatch. A failed write sends no personal data to the API.
    await store.write(id);
    requestId = id;
    _pending = Map<String, dynamic>.from(
      jsonDecode(jsonEncode({...parameters, 'p_request': id})) as Map,
    );
    _apply(await gateway.register(_pending!), firstResponse: true);
  });

  Future<void> recover() => _run(() async {
    if (requestId != null) _apply(await gateway.recover(requestId!));
  });

  Future<void> retry() => _run(() async {
    if (!canRetry) return;
    _apply(await gateway.register(_pending!), firstResponse: true);
  });

  Future<void> close() async {
    // Check eligibility before _run clears the previous uncertainty message.
    if (!canClose) return;
    await _run(() async {
      final response = await gateway.close(requestId!, branchId);
      if (response['request_id'] != requestId ||
          response['branch_id'] != branchId) {
        throw StateError('Close response scope does not match');
      }
      if (response['state'] == 'closed') {
        _apply({...response, 'status': 'closed'});
      } else if (response['state'] == 'succeeded' &&
          response['result'] is Map) {
        final actual = Map<String, dynamic>.from(response['result'] as Map);
        if (![
              'created_unverified',
              'reused_unverified',
              'review_required',
            ].contains(actual['status']) ||
            actual['request_id'] != requestId) {
          throw StateError('Close returned an unsupported receipt');
        }
        // Closing cannot recover or mint the one-time enrollment secret.
        enrollmentSecret = null;
        _apply(actual);
      } else {
        throw StateError('Close result is not authoritative');
      }
    });
  }

  Future<void> acknowledge() => _run(() async {
    if (!resolved) return;
    await store.clear();
    requestId = null;
    receipt = null;
    _pending = null;
    enrollmentSecret = null;
  });

  Future<void> createSeparate(String reason) async {
    if (!canCreateSeparate || busy) return;
    final exact = Map<String, dynamic>.from(_pending!)
      ..remove('p_request')
      ..['p_duplicate_action'] = 'create_separate'
      ..['p_review_reason'] = reason.trim();
    await acknowledge();
    if (requestId == null) await submit(exact);
  }

  @override
  void dispose() {
    _disposed = true;
    enrollmentSecret = null;
    _pending = null;
    super.dispose();
  }
}

class OfflineCustomerRegistrationScreen extends StatefulWidget {
  const OfflineCustomerRegistrationScreen({
    super.key,
    required this.client,
    required this.branchId,
    required this.role,
    this.gateway,
    this.store,
    this.onStageReceiveWork,
    this.onDiscardReceiveWork,
    this.onReceiveWork,
    this.intakePriority = 'normal',
  });
  final SupabaseClient client;
  final String branchId, role;
  final OfflineRegistrationGateway? gateway;
  final OfflineRegistrationStore? store;
  final Future<void> Function(String registrationRequest)? onStageReceiveWork;
  final ValueChanged<String>? onReceiveWork;
  final Future<void> Function(String registrationRequest)? onDiscardReceiveWork;
  final String intakePriority;
  @override
  State<OfflineCustomerRegistrationScreen> createState() =>
      _OfflineCustomerRegistrationScreenState();
}

class _OfflineCustomerRegistrationScreenState
    extends State<OfflineCustomerRegistrationScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(), phone = TextEditingController();
  final plate = TextEditingController(), brand = TextEditingController();
  final model = TextEditingController(), year = TextEditingController();
  final color = TextEditingController(), reason = TextEditingController();
  final odometerKm = TextEditingController();
  String? vehicleClassCode;
  late final OfflineRegistrationController controller;
  bool accepted = false, receiptAcknowledged = false, handoffBusy = false;
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String en, String arabic) => ar ? arabic : en;
  @override
  void initState() {
    super.initState();
    controller = OfflineRegistrationController(
      branchId: widget.branchId,
      gateway:
          widget.gateway ?? SupabaseOfflineRegistrationGateway(widget.client),
      store:
          widget.store ??
          SharedOfflineRegistrationStore(widget.client, widget.branchId),
    )..addListener(changed);
    controller.initialize();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    controller.dispose();
    for (final field in [
      name,
      phone,
      plate,
      brand,
      model,
      year,
      color,
      reason,
      odometerKm,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  String? requiredValue(String? value) =>
      value == null || value.trim().isEmpty ? t('Required', 'مطلوب') : null;
  String? optional(String value) => value.trim().isEmpty ? null : value.trim();
  Future<void> submit() async {
    if (!form.currentState!.validate() || !accepted) {
      setState(() {});
      return;
    }
    receiptAcknowledged = false;
    await controller.submit({
      'p_branch': widget.branchId,
      'p_name': name.text.trim(),
      'p_phone': phone.text.trim(),
      'p_country': 'EG',
      'p_car': {
        'plate_number': plate.text.trim(),
        'brand': optional(brand.text),
        'model': optional(model.text),
        'year': int.tryParse(year.text.trim()),
        'color': optional(color.text),
        'vehicle_class_code': vehicleClassCode,
        'odometer_km': int.tryParse(odometerKm.text.trim()),
      },
      'p_consent': {
        'accepted': true,
        'version': offlineRegistrationConsentVersion,
        'text': ar
            ? offlineRegistrationConsentArabic
            : offlineRegistrationConsentEnglish,
        'language': ar ? 'ar' : 'en',
      },
      'p_duplicate_action': null,
      'p_review_reason': null,
    });
  }

  Widget field(
    String key,
    TextEditingController input,
    String label, {
    bool required = false,
    int limit = 120,
    int lines = 1,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) => TextFormField(
    key: ValueKey(key),
    controller: input,
    enabled: !controller.locked,
    maxLength: limit,
    maxLines: lines,
    keyboardType: keyboard,
    validator: validator ?? (required ? requiredValue : null),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  Widget accessibleReference(
    String label,
    String value,
    String key,
  ) => Semantics(
    key: ValueKey('${key}_semantics'),
    container: true,
    // These are displayed references, not editable text clients. Flutter Web
    // initializes native text-field values only for active TextInput clients.
    label: '$label: $value',
    child: ExcludeSemantics(
      child: SelectableText(
        value,
        key: ValueKey(key),
        textDirection: TextDirection.ltr,
      ),
    ),
  );

  Future<bool> finishRegistration({bool retainHandoff = false}) async {
    final result = controller.receipt;
    if (controller.busy ||
        !controller.resolved ||
        (result?['enrollment_secret_issued'] == true && !receiptAcknowledged)) {
      return false;
    }
    if (!retainHandoff && controller.requestId != null) {
      try {
        await widget.onDiscardReceiveWork?.call(controller.requestId!);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Resolve the saved reception before finishing.',
                  'عالج الاستقبال المحفوظ قبل الإنهاء.',
                ),
              ),
            ),
          );
        }
        return false;
      }
    }
    await controller.acknowledge();
    if (!mounted || controller.locked) return false;
    for (final field in [
      name,
      phone,
      plate,
      brand,
      model,
      year,
      color,
      reason,
    ]) {
      field.clear();
    }
    setState(() {
      accepted = false;
      receiptAcknowledged = false;
    });
    return true;
  }

  Future<void> receiveWork() async {
    final result = controller.receipt;
    final request = controller.requestId;
    if (handoffBusy ||
        controller.busy ||
        widget.onStageReceiveWork == null ||
        widget.onReceiveWork == null ||
        request == null ||
        ![
          'created_unverified',
          'reused_unverified',
        ].contains(result?['status']) ||
        (result?['enrollment_secret_issued'] == true && !receiptAcknowledged)) {
      return;
    }
    setState(() => handoffBusy = true);
    try {
      await widget.onStageReceiveWork!(request);
      if (!mounted ||
          controller.requestId != request ||
          !await finishRegistration(retainHandoff: true)) {
        return;
      }
      // The secret's visual/selectable and accessible nodes must disappear first.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && !controller.locked) widget.onReceiveWork!(request);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'The reception reference could not be saved. Keep this receipt and resolve any earlier reception first.',
                'تعذر حفظ مرجع الاستقبال. احتفظ بهذا الإيصال وعالج أي استقبال سابق أولاً.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => handoffBusy = false);
    }
  }

  Widget receipt() {
    final result = controller.receipt!;
    final review = result['status'] == 'review_required';
    final closed = result['status'] == 'closed';
    final secret = controller.enrollmentSecret;
    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffc5cbd5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              closed
                  ? t(
                      'Unused registration request safely closed',
                      'أُغلق طلب التسجيل غير المستخدم بأمان',
                    )
                  : review
                  ? t(
                      'A possible match needs owner review',
                      'توجد بيانات محتملة تحتاج مراجعة المالك',
                    )
                  : t(
                      'Customer record saved · unverified',
                      'تم حفظ سجل العميل · غير موثق',
                    ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              t(
                closed
                    ? 'The server confirmed no registration was created for this reference. A delayed request with the same reference cannot create one.'
                    : 'No app account was created. This registration does not verify identity or authorize rewards.',
                closed
                    ? 'أكد الخادم عدم إنشاء تسجيل بهذا المرجع. لا يستطيع طلب متأخر بالمرجع نفسه إنشاء تسجيل.'
                    : 'لم يتم إنشاء حساب للتطبيق. هذا التسجيل لا يوثق الهوية ولا يسمح باستخدام المكافآت.',
              ),
            ),
            if (result['phone_masked'] != null)
              Text(
                '${result['phone_masked']}',
                textDirection: TextDirection.ltr,
              ),
            const SizedBox(height: 12),
            if (result['enrollment_receipt_id'] != null) ...[
              Text(t('Customer receipt reference', 'مرجع إيصال العميل')),
              accessibleReference(
                t('Customer receipt reference', 'مرجع إيصال العميل'),
                '${result['enrollment_receipt_id']}',
                'enrollment_receipt_reference',
              ),
              const SizedBox(height: 12),
            ],
            Text(t('Staff recovery reference', 'مرجع استعادة الموظف')),
            accessibleReference(
              t('Staff recovery reference', 'مرجع استعادة الموظف'),
              controller.requestId ?? '',
              'staff_recovery_reference',
            ),
            if (secret != null) ...[
              const SizedBox(height: 18),
              Text(
                t(
                  'Save the customer’s receipt code now',
                  'احفظ رمز إيصال العميل الآن',
                ),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                t(
                  'Give this code to the customer. It is shown only now and cannot be recovered after leaving. Keep it private; it does not link an account or approve rewards.',
                  'سلّم هذا الرمز للعميل. يظهر الآن فقط ولا يمكن استرجاعه بعد المغادرة. احفظه بسرية؛ فهو لا يربط حساباً ولا يوافق على مكافآت.',
                ),
              ),
              accessibleReference(
                t(
                  'Private receipt code · shown once',
                  'رمز الإيصال السري · يظهر مرة واحدة',
                ),
                secret,
                'enrollment_secret',
              ),
            ] else if (controller.secretWasLost) ...[
              const SizedBox(height: 12),
              Text(
                t(
                  'The original receipt code cannot be displayed again. A future account claim requires owner review.',
                  'لا يمكن عرض رمز الإيصال الأصلي مرة أخرى. أي طلب ربط مستقبلي يحتاج مراجعة المالك.',
                ),
              ),
            ],
            if (review &&
                widget.role == 'owner' &&
                controller.canCreateSeparate) ...[
              const SizedBox(height: 18),
              TextField(
                key: const ValueKey('review_reason'),
                controller: reason,
                enabled: !controller.busy,
                maxLength: 500,
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: t(
                    'Reason for a separate customer record',
                    'سبب إنشاء سجل عميل منفصل',
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              OutlinedButton(
                key: const ValueKey('create_separate'),
                onPressed: controller.busy || reason.text.trim().length < 10
                    ? null
                    : () => controller.createSeparate(reason.text),
                child: Text(
                  t(
                    'Confirm a separate customer record',
                    'تأكيد إنشاء سجل عميل منفصل',
                  ),
                ),
              ),
            ],
            if (result['enrollment_secret_issued'] == true)
              CheckboxListTile(
                key: const ValueKey('receipt_acknowledged'),
                contentPadding: EdgeInsets.zero,
                value: receiptAcknowledged,
                onChanged: controller.busy || handoffBusy
                    ? null
                    : (value) =>
                          setState(() => receiptAcknowledged = value == true),
                title: Text(
                  secret != null
                      ? t(
                          'The customer saved the private receipt code',
                          'حفظ العميل رمز الإيصال السري',
                        )
                      : t(
                          'I understand that owner review is required for the missing code',
                          'أفهم أن الرمز المفقود يحتاج مراجعة المالك',
                        ),
                ),
              ),
            if (widget.onReceiveWork != null &&
                widget.onStageReceiveWork != null &&
                [
                  'created_unverified',
                  'reused_unverified',
                ].contains(result['status']))
              OutlinedButton(
                key: const ValueKey('registration_receive_work'),
                onPressed:
                    controller.busy ||
                        handoffBusy ||
                        (result['enrollment_secret_issued'] == true &&
                            !receiptAcknowledged)
                    ? null
                    : receiveWork,
                child: Text(
                  t(
                    'Acknowledge receipt and open walk-in reception',
                    'تأكيد استلام الإيصال وفتح استقبال الخدمة المباشرة',
                  ),
                ),
              ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff174b83),
                foregroundColor: Colors.white,
              ),
              key: const ValueKey('registration_done'),
              onPressed:
                  controller.busy ||
                      handoffBusy ||
                      (result['enrollment_secret_issued'] == true &&
                          !receiptAcknowledged)
                  ? null
                  : () => finishRegistration(),
              child: Text(
                t(
                  'Finish and start another registration',
                  'إنهاء وبدء تسجيل آخر',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xffffffff),
    appBar: AppBar(
      backgroundColor: const Color(0xff071a36),
      foregroundColor: Colors.white,
      title: Text(
        widget.intakePriority == 'vip'
            ? t('VIP vehicle intake', 'استلام سيارة VIP')
            : t('Customer registration', 'تسجيل عميل'),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              t(
                'Register a customer without an app account',
                'تسجيل عميل دون حساب للتطبيق',
              ),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              t(
                'Customer and car details stay in the staff registry. Phone matching does not prove identity.',
                'تُحفظ بيانات العميل والسيارة في سجل الموظفين. تطابق الهاتف لا يثبت الهوية.',
              ),
            ),
            if (controller.busy)
              const LinearProgressIndicator(color: Color(0xff174b83)),
            if (!controller.initialized && !controller.busy)
              OutlinedButton(
                onPressed: controller.initialize,
                child: Text(
                  t('Check staff session again', 'فحص جلسة الموظف مجدداً'),
                ),
              ),
            if (controller.errorCode != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  controller.errorCode == 'access_denied'
                      ? t(
                          'Your current staff account cannot access this registration in this branch.',
                          'حساب الموظف الحالي لا يملك صلاحية هذا التسجيل في هذا الفرع.',
                        )
                      : t(
                          'Registration is not confirmed. Keep this reference and check its result; do not create another request.',
                          'لم يتأكد التسجيل. احتفظ بالمرجع وافحص النتيجة؛ لا تنشئ طلباً آخر.',
                        ),
                  style: const TextStyle(color: Color(0xff9d2738)),
                ),
              ),
            if (controller.resolved)
              receipt()
            else ...[
              if (controller.requestId != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          t(
                            'Pending registration reference',
                            'مرجع التسجيل قيد التحقق',
                          ),
                        ),
                        accessibleReference(
                          t('Staff recovery reference', 'مرجع استعادة الموظف'),
                          controller.requestId!,
                          'staff_recovery_reference',
                        ),
                        Text(
                          t(
                            'Details stay locked until the server returns a receipt or safely closes this request. An absent result does not allow a new request.',
                            'تبقى البيانات مقفلة حتى يعيد الخادم إيصالاً أو يغلق هذا الطلب بأمان. النتيجة غير الموجودة لا تسمح بطلب جديد.',
                          ),
                        ),
                        OutlinedButton(
                          key: const ValueKey('recover_registration'),
                          onPressed: controller.busy
                              ? null
                              : controller.recover,
                          child: Text(
                            t(
                              'Check saved registration',
                              'فحص التسجيل المحفوظ',
                            ),
                          ),
                        ),
                        if (controller.canClose)
                          OutlinedButton(
                            key: const ValueKey('close_registration'),
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: Text(
                                    t(
                                      'Safely close this unused request?',
                                      'إغلاق هذا الطلب غير المستخدم بأمان؟',
                                    ),
                                  ),
                                  content: Text(
                                    t(
                                      'If registration already succeeded, its saved receipt will be shown instead. This does not cancel a saved customer record or recover a missing receipt code.',
                                      'إذا نجح التسجيل بالفعل فسيظهر إيصالُه المحفوظ بدلاً من الإغلاق. لا يلغي ذلك سجل عميل محفوظاً ولا يستعيد رمز إيصال مفقوداً.',
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: Text(
                                        t('Keep checking', 'متابعة الفحص'),
                                      ),
                                    ),
                                    FilledButton(
                                      key: const ValueKey(
                                        'confirm_registration_close',
                                      ),
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: Text(
                                        t(
                                          'Request safe close',
                                          'طلب إغلاق آمن',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) await controller.close();
                            },
                            child: Text(
                              t(
                                'Request safe close before another registration',
                                'طلب إغلاق آمن قبل تسجيل آخر',
                              ),
                            ),
                          ),
                        if (controller.canRetry)
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xff174b83),
                              foregroundColor: Colors.white,
                            ),
                            key: const ValueKey('retry_registration'),
                            onPressed: controller.busy
                                ? null
                                : controller.retry,
                            child: Text(
                              t(
                                'Retry the exact same request',
                                'إعادة الطلب نفسه بالضبط',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field(
                      'customer_name',
                      name,
                      t('Customer name', 'اسم العميل'),
                      limit: 120,
                      validator: (value) =>
                          value == null ||
                              value
                                      .trim()
                                      .replaceAll(RegExp(r'\s+'), ' ')
                                      .length <
                                  2
                          ? t(
                              'Enter the customer’s actual name',
                              'أدخل اسم العميل الفعلي',
                            )
                          : null,
                    ),
                    field(
                      'customer_phone',
                      phone,
                      t('Phone number', 'رقم الهاتف'),
                      limit: 64,
                      keyboard: TextInputType.phone,
                      validator: (value) =>
                          value != null && validOfflineRegistrationPhone(value)
                          ? null
                          : t(
                              'Enter an international number or a valid Egyptian number',
                              'أدخل رقماً دولياً أو رقماً مصرياً صحيحاً',
                            ),
                    ),
                    Text(
                      t(
                        'Local numbers use Egypt (+20). The phone remains unverified.',
                        'تستخدم الأرقام المحلية رمز مصر (+20). يظل الهاتف غير موثق.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    field(
                      'car_plate',
                      plate,
                      t('Plate number', 'رقم اللوحة'),
                      limit: 40,
                      validator: (value) {
                        final normalized = _asciiDigits(value ?? '')
                            .replaceAll(RegExp(r'[\s-]'), '');
                        return normalized.length < 2 ||
                                normalized.length > 32 ||
                                RegExp(r'[\x00-\x1f\x7f]').hasMatch(value ?? '')
                            ? t(
                                'Enter the actual plate number',
                                'أدخل رقم اللوحة الفعلي',
                              )
                            : null;
                      },
                    ),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('vehicle_class_code'),
                      initialValue: vehicleClassCode,
                      decoration: InputDecoration(
                        labelText: t('Vehicle class', 'فئة السيارة'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'sedan',
                          child: Text(t('Sedan', 'سيدان')),
                        ),
                        DropdownMenuItem(
                          value: 'suv',
                          child: Text(t('SUV / 4WD', 'SUV / دفع رباعي')),
                        ),
                      ],
                      validator: (value) => value == null
                          ? t(
                              'Select the actual vehicle class',
                              'اختر فئة السيارة الفعلية',
                            )
                          : null,
                      onChanged: controller.locked
                          ? null
                          : (value) => setState(() => vehicleClassCode = value),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          field(
                            'car_brand',
                            brand,
                            t('Brand (optional)', 'الماركة (اختياري)'),
                            limit: 80,
                          ),
                          field(
                            'car_model',
                            model,
                            t('Model (optional)', 'الطراز (اختياري)'),
                            limit: 80,
                          ),
                        ];
                        return constraints.maxWidth < 560
                            ? Column(children: fields)
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: fields[0]),
                                  const SizedBox(width: 12),
                                  Expanded(child: fields[1]),
                                ],
                              );
                      },
                    ),
                    field(
                      'car_year',
                      year,
                      t('Year (optional)', 'سنة الصنع (اختياري)'),
                      limit: 4,
                      keyboard: TextInputType.number,
                      validator: (value) =>
                          value == null ||
                              value.trim().isEmpty ||
                              (int.tryParse(value) != null &&
                                  int.parse(value) >= 1950 &&
                                  int.parse(value) <= 2100)
                          ? null
                          : t(
                              'Enter a year from 1950 to 2100',
                              'أدخل سنة من 1950 إلى 2100',
                            ),
                    ),
                    field(
                      'car_color',
                      color,
                      t('Color (optional)', 'اللون (اختياري)'),
                      limit: 40,
                    ),
                    field(
                      'odometer_km',
                      odometerKm,
                      t('Odometer (km)', 'قراءة العداد (كم)'),
                      limit: 8,
                      keyboard: TextInputType.number,
                      validator: (value) =>
                          value == null ||
                              value.trim().isEmpty ||
                              (int.tryParse(value) != null &&
                                  int.parse(value) >= 0 &&
                                  int.parse(value) <= 9999999)
                          ? null
                          : t(
                              'Enter a valid odometer reading',
                              'أدخل قراءة عداد صحيحة',
                            ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      t(
                        'Actual registration notice presented to the customer',
                        'إشعار التسجيل الفعلي المعروض للعميل',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ar
                          ? offlineRegistrationConsentArabic
                          : offlineRegistrationConsentEnglish,
                      key: const ValueKey('registration_notice'),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('registration_consent'),
                      contentPadding: EdgeInsets.zero,
                      value: accepted,
                      onChanged: controller.locked
                          ? null
                          : (value) => setState(() => accepted = value == true),
                      title: Text(
                        t(
                          'The customer agreed to this registration notice',
                          'وافق العميل على إشعار التسجيل هذا',
                        ),
                      ),
                    ),
                    if (!accepted)
                      Text(
                        t(
                          'Customer agreement is required. It does not authorize marketing, linking or rewards.',
                          'موافقة العميل مطلوبة. وهي لا تسمح بالتسويق أو الربط أو المكافآت.',
                        ),
                      ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xff174b83),
                        foregroundColor: Colors.white,
                      ),
                      key: const ValueKey('submit_registration'),
                      onPressed: controller.locked ? null : submit,
                      child: Text(
                        t('Save customer registration', 'حفظ تسجيل العميل'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
