import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show InvoiceDocumentsScreen;
import 'offline_customer_registration.dart' show SharedOfflineRegistrationStore;
import 'workflow.dart' show newOrderRequestId;

abstract class OfflineWalkInGateway {
  Future<Map<String, dynamic>> context(String registration);
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> parameters);
  Future<Map<String, dynamic>> recover(String? request);
  Future<Map<String, dynamic>> place(String request);
  Future<Map<String, dynamic>> placeWithPriority(
    String request, {
    required String priority,
  }) => place(request);
  Future<Map<String, dynamic>> close(String request);
  Future<Map<String, dynamic>> acknowledge(String request);
}

class SupabaseOfflineWalkInGateway implements OfflineWalkInGateway {
  SupabaseOfflineWalkInGateway(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  Future<Map<String, dynamic>> call(
    String function,
    Map<String, dynamic> parameters,
  ) async {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    final response = await client.rpc(function, params: parameters) as Map;
    if (client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return Map<String, dynamic>.from(response);
  }

  @override
  Future<Map<String, dynamic>> context(String registration) =>
      call('get_offline_walk_in_context', {'p_registration': registration});
  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> parameters) =>
      call('prepare_offline_walk_in', parameters);
  @override
  Future<Map<String, dynamic>> recover(String? request) =>
      call('get_offline_walk_in_command', {'p_request': request});
  @override
  Future<Map<String, dynamic>> place(String request) =>
      call('place_offline_walk_in', {'p_request': request});
  @override
  Future<Map<String, dynamic>> placeWithPriority(
    String request, {
    required String priority,
  }) => priority == 'vip'
      ? call('place_offline_walk_in_with_priority', {
          'p_request': request,
          'p_priority': priority,
        })
      : place(request);
  @override
  Future<Map<String, dynamic>> close(String request) =>
      call('close_offline_walk_in_command', {'p_request': request});
  @override
  Future<Map<String, dynamic>> acknowledge(String request) =>
      call('ack_offline_walk_in_command', {'p_request': request});
}

abstract class OfflineWalkInStore {
  Future<String?> read();
  Future<void> write(String request);
  Future<void> clear();
}

/// The staff-scoped store contains a UUID only. All operational fields stay server-side.
class SharedOfflineWalkInStore implements OfflineWalkInStore {
  SharedOfflineWalkInStore(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return 'offline_walk_in_request_$actor';
  }

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String request) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      request,
    )) {
      throw StateError('Request reference not saved');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Request reference not cleared');
    }
  }
}

class OfflineWalkInHandoffState {
  const OfflineWalkInHandoffState({
    this.registration,
    this.command,
    this.pendingRegistration,
  });
  final String? registration, command, pendingRegistration;
}

abstract class OfflineWalkInHandoffStore {
  String get branchId;
  Future<OfflineWalkInHandoffState> read();
  Future<void> stage(String registration);
  Future<void> discardSource(String registration);
  Future<void> associate(String registration, String command);
  Future<void> consumeSource(String registration, String command);
  Future<void> finishCommand(String command, String? registration);
}

/// H and C are separate UUID values, scoped to the captured staff and branch.
/// Neither key contains customer details, notes, or the one-time receipt secret.
class SharedOfflineWalkInHandoffStore implements OfflineWalkInHandoffStore {
  SharedOfflineWalkInHandoffStore(this.client, this.branchId)
    : actor = client.auth.currentUser?.id,
      originalRegistration = SharedOfflineRegistrationStore(client, branchId);
  final SupabaseClient client;
  @override
  final String branchId;
  final String? actor;
  final SharedOfflineRegistrationStore originalRegistration;
  static final uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  String key(String suffix) {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return 'offline_walk_in_handoff_${actor}_${branchId}_$suffix';
  }

  void validate(String? value) {
    if (value != null && !uuid.hasMatch(value)) {
      throw StateError('Expected a UUID reference only');
    }
  }

  @override
  Future<OfflineWalkInHandoffState> read() async {
    final preferences = await SharedPreferences.getInstance();
    final h = preferences.getString(key('registration'));
    final c = preferences.getString(key('command'));
    final pending = await originalRegistration.read();
    validate(h);
    validate(c);
    validate(pending);
    return OfflineWalkInHandoffState(
      registration: h,
      command: c,
      pendingRegistration: pending,
    );
  }

  Future<void> write(String suffix, String value) async {
    validate(value);
    if (!await (await SharedPreferences.getInstance()).setString(
      key(suffix),
      value,
    )) {
      throw StateError('Reception reference was not saved');
    }
  }

  Future<void> remove(String suffix) async {
    if (!await (await SharedPreferences.getInstance()).remove(key(suffix))) {
      throw StateError('Reception reference was not cleared');
    }
  }

  @override
  Future<void> stage(String registration) async {
    validate(registration);
    final state = await read();
    if (state.pendingRegistration != registration ||
        state.command != null ||
        (state.registration != null && state.registration != registration)) {
      throw StateError('Resolve the original pending reception first');
    }
    await write('registration', registration);
  }

  @override
  Future<void> associate(String registration, String command) async {
    validate(registration);
    validate(command);
    final state = await read();
    if (state.pendingRegistration != null ||
        state.registration != registration ||
        (state.command != null && state.command != command)) {
      throw StateError('Reception references do not match');
    }
    await write('command', command);
  }

  @override
  Future<void> consumeSource(String registration, String command) async {
    final state = await read();
    if (state.pendingRegistration != null ||
        state.command != command ||
        (state.registration != null && state.registration != registration)) {
      throw StateError('Reception references do not match');
    }
    if (state.registration != null) await remove('registration');
  }

  @override
  Future<void> discardSource(String registration) async {
    final state = await read();
    if (state.registration == null) return;
    if (state.registration != registration ||
        (state.pendingRegistration != null &&
            state.pendingRegistration != registration)) {
      throw StateError('Reception references do not match');
    }
    // A saved command always retains its durable recovery references.
    if (state.command != null) return;
    await remove('registration');
  }

  @override
  Future<void> finishCommand(String command, String? registration) async {
    final state = await read();
    if (state.pendingRegistration != null ||
        (state.command != null && state.command != command)) {
      throw StateError('Resolve the original pending reception first');
    }
    if (state.command == command) {
      if (state.registration != null &&
          registration != null &&
          state.registration != registration) {
        throw StateError('Reception references do not match');
      }
      if (state.registration != null) await remove('registration');
      await remove('command');
    } else if (registration != null && state.registration == registration) {
      await remove('registration');
    }
  }
}

class OfflineWalkInController extends ChangeNotifier {
  OfflineWalkInController({
    required this.gateway,
    required this.store,
    this.handoff,
    this.priority = 'normal',
  });
  final OfflineWalkInGateway gateway;
  final OfflineWalkInStore store;
  final OfflineWalkInHandoffStore? handoff;
  final String priority;
  OfflineWalkInHandoffState handoffState = const OfflineWalkInHandoffState();
  String? get pendingRegistration => handoffState.pendingRegistration;
  String? get restorableRegistration =>
      requestId == null &&
          handoffState.command == null &&
          pendingRegistration == null
      ? handoffState.registration
      : null;
  String? requestId, errorCode;
  Map<String, dynamic> view = {};
  Map<String, dynamic>? contextData, _pendingPreparation;
  bool initialized = false,
      busy = false,
      recoveryUncertain = false,
      _disposed = false;
  String? get status => view['status'] as String?;
  bool get terminal => status == 'succeeded' || status == 'closed';
  bool get locked =>
      !initialized || busy || requestId != null || recoveryUncertain;
  bool get canRetryPreparation =>
      requestId != null && _pendingPreparation != null && !terminal;
  bool get canPrepare =>
      !locked &&
      pendingRegistration == null &&
      contextData?['can_prepare'] == true;
  Map<String, dynamic>? get result => view['result'] is Map
      ? Map<String, dynamic>.from(view['result'] as Map)
      : null;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> run(Future<void> Function() work, {bool command = true}) async {
    if (busy || _disposed) return;
    busy = true;
    errorCode = null;
    changed();
    try {
      await work();
    } on PostgrestException catch (error) {
      errorCode = error.code == '42501'
          ? 'access_denied'
          : error.code == '40001'
          ? 'stale'
          : 'unconfirmed';
      if (command) recoveryUncertain = true;
    } catch (_) {
      errorCode = 'unconfirmed';
      if (command) recoveryUncertain = true;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> refreshHandoff() async {
    if (handoff == null) return;
    handoffState = await handoff!.read();
    if (requestId != null &&
        handoffState.command != null &&
        handoffState.command != requestId) {
      throw StateError('A different saved command needs review');
    }
  }

  Future<void> consumeConfirmedHandoff() async {
    if (handoff == null || !['prepared', 'succeeded'].contains(status)) return;
    await refreshHandoff();
    if (pendingRegistration != null) return;
    final registration =
        (view['payload'] as Map?)?['registration_request_id'] as String?;
    if (handoffState.registration != null &&
        handoffState.registration == registration) {
      if (handoffState.command == null) {
        await handoff!.associate(registration!, requestId!);
      }
      await handoff!.consumeSource(registration!, requestId!);
      await refreshHandoff();
    }
  }

  Future<void> apply(Map<String, dynamic> response) async {
    if (_disposed) return;
    if (response['status'] == 'absent') {
      view = response;
      recoveryUncertain = requestId != null;
      if (recoveryUncertain) errorCode = 'unconfirmed';
      return;
    }
    final id = response['request_id'];
    if (id is! String ||
        id.isEmpty ||
        (requestId != null && id != requestId) ||
        !['prepared', 'succeeded', 'closed'].contains(response['status'])) {
      throw StateError('Unconfirmed command protocol');
    }
    if (response['status'] == 'prepared' && response['payload'] is! Map) {
      throw StateError('Missing saved preparation');
    }
    if (response['status'] == 'closed' &&
        (response['result'] is! Map ||
            (response['result'] as Map)['status'] != 'closed' ||
            (response['result'] as Map)['order_id'] != null)) {
      throw StateError('Missing authoritative closed result');
    }
    if (response['status'] == 'succeeded' &&
        (response['result'] is! Map ||
            (response['result'] as Map)['order_id'] == null ||
            (response['result'] as Map)['invoice_id'] == null)) {
      throw StateError('Missing actual receipt');
    }
    if (requestId == null) {
      await store.write(id);
      requestId = id;
    }
    view = Map<String, dynamic>.from(response);
    recoveryUncertain = false;
    await consumeConfirmedHandoff();
  }

  Future<void> initialize() => run(() async {
    requestId = await store.read();
    await refreshHandoff();
    if (requestId == null && handoffState.command != null) {
      requestId = handoffState.command;
      await store.write(requestId!);
    }
    initialized = true;
    await apply(await gateway.recover(requestId));
  });
  Future<void> discardRestoredContext() => run(() async {
    await refreshHandoff();
    final source = restorableRegistration;
    if (requestId != null ||
        pendingRegistration != null ||
        handoffState.command != null ||
        source == null) {
      throw StateError('Resolve the saved reception first');
    }
    await handoff!.discardSource(source);
    await refreshHandoff();
    contextData = null;
  }, command: false);
  Future<void> loadContext(String registration) => run(() async {
    if (locked && requestId != null) return;
    contextData = null;
    await refreshHandoff();
    if (pendingRegistration != null) {
      errorCode = 'registration_pending';
      return;
    }
    if (handoffState.command != null ||
        (handoffState.registration != null &&
            handoffState.registration != registration)) {
      throw StateError('Resolve the staged reception first');
    }
    final actual = await gateway.context(registration);
    if (actual['registration_request_id'] != registration ||
        actual['bound_cashier'] is! Map ||
        actual['branch'] is! Map) {
      throw StateError('Unconfirmed reception context');
    }
    if (handoff != null &&
        (actual['branch'] as Map)['id'] != handoff!.branchId) {
      throw StateError('Reception branch does not match');
    }
    contextData = actual;
  }, command: false);
  Future<void> prepareSelection(
    String service,
    List<String> staff,
    String notes,
  ) => run(() async {
    // run sets busy; validate the underlying confirmed state rather than canPrepare.
    if (!initialized ||
        requestId != null ||
        recoveryUncertain ||
        contextData?['can_prepare'] != true) {
      return;
    }
    await refreshHandoff();
    if (pendingRegistration != null) {
      errorCode = 'registration_pending';
      return;
    }
    if (handoffState.command != null ||
        (handoffState.registration != null &&
            handoffState.registration !=
                contextData!['registration_request_id'])) {
      throw StateError('Resolve the saved reception first');
    }
    final services = (contextData!['services'] as List).cast<Map>();
    final workers = (contextData!['workers'] as List).cast<Map>();
    final selected = services.where((s) => s['id'] == service).single;
    if (staff.isEmpty ||
        staff.toSet().length != staff.length ||
        staff.any((id) => !workers.any((w) => w['id'] == id))) {
      throw StateError('Select actual eligible workers');
    }
    final id = newOrderRequestId();
    final exact = {
      'p_request': id,
      'p_registration': contextData!['registration_request_id'],
      'p_service': service,
      'p_expected_price': selected['price'],
      'p_cashier': (contextData!['bound_cashier'] as Map)['id'],
      'p_staff_ids': [...staff]..sort(),
      'p_notes': notes.trim().isEmpty ? null : notes.trim(),
    };
    recoveryUncertain = true;
    // Associate H with C before dispatch. If command-key storage then fails, C
    // still recovers the exact nonce instead of silently allocating another one.
    if (handoffState.registration != null) {
      await handoff!.associate(handoffState.registration!, id);
    }
    await store.write(id);
    requestId = id;
    _pendingPreparation = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(exact)) as Map,
    );
    await apply(await gateway.prepare(_pendingPreparation!));
  }, command: false);
  Future<void> recoverCurrent() async {
    await refreshHandoff();
    if (requestId == null && handoffState.command != null) {
      requestId = handoffState.command;
      await store.write(requestId!);
    }
    await apply(await gateway.recover(requestId));
  }

  Future<void> recover() => run(recoverCurrent);
  Future<void> retryPreparation() => run(() async {
    if (requestId == null) return;
    await recoverCurrent();
    await refreshHandoff();
    if (pendingRegistration != null) {
      errorCode = 'registration_pending';
      return;
    }
    if (status == 'absent' && _pendingPreparation != null) {
      await apply(await gateway.prepare(_pendingPreparation!));
    }
  });
  Future<void> place() => run(() async {
    if (requestId == null) return;
    await recoverCurrent();
    await refreshHandoff();
    if (pendingRegistration != null) {
      errorCode = 'registration_pending';
      return;
    }
    if (status == 'prepared') {
      await apply(
        await gateway.placeWithPriority(requestId!, priority: priority),
      );
    }
  });
  Future<void> close() => run(() async {
    if (requestId != null && !terminal) {
      await apply(await gateway.close(requestId!));
    }
  });
  Future<void> acknowledge() => run(() async {
    if (requestId == null || !terminal) return;
    await refreshHandoff();
    if (pendingRegistration != null) {
      errorCode = 'registration_pending';
      return;
    }
    final id = requestId!;
    final response = await gateway.acknowledge(id);
    if (response['request_id'] != id ||
        response['acknowledged'] != true ||
        response['status'] != status ||
        !['succeeded', 'closed'].contains(response['status'])) {
      throw StateError('Acknowledgement not confirmed');
    }
    await apply(response);
    final registration =
        (view['payload'] as Map?)?['registration_request_id'] as String?;
    await handoff?.finishCommand(id, registration);
    await refreshHandoff();
    await store.clear();
    requestId = null;
    view = {};
    _pendingPreparation = null;
    contextData = null;
    recoveryUncertain = false;
  });
  @override
  void dispose() {
    _disposed = true;
    _pendingPreparation = null;
    super.dispose();
  }
}

class OfflineWalkInScreen extends StatefulWidget {
  const OfflineWalkInScreen({
    super.key,
    required this.client,
    required this.role,
    this.initialRegistrationRequestId,
    this.priority = 'normal',
    this.gateway,
    this.store,
    this.onOpenCashierLedger,
    this.handoff,
    this.onResumeRegistration,
  });
  final SupabaseClient client;
  final String role;
  final String? initialRegistrationRequestId;
  final String priority;
  final OfflineWalkInGateway? gateway;
  final OfflineWalkInStore? store;
  final VoidCallback? onOpenCashierLedger, onResumeRegistration;
  final OfflineWalkInHandoffStore? handoff;
  @override
  State<OfflineWalkInScreen> createState() => _WalkInState();
}

class _WalkInState extends State<OfflineWalkInScreen> {
  late final OfflineWalkInController controller;
  final registration = TextEditingController(), notes = TextEditingController();
  String? service;
  final selectedStaff = <String>{};
  bool get ar => Localizations.localeOf(context).languageCode == 'ar';
  String t(String english, String arabic) => ar ? arabic : english;
  bool get staffRole => ['owner', 'manager', 'employee'].contains(widget.role);
  @override
  void initState() {
    super.initState();
    registration.text = widget.initialRegistrationRequestId ?? '';
    controller = OfflineWalkInController(
      gateway: widget.gateway ?? SupabaseOfflineWalkInGateway(widget.client),
      store: widget.store ?? SharedOfflineWalkInStore(widget.client),
      handoff: widget.handoff,
      priority: widget.priority,
    )..addListener(changed);
    start();
  }

  Future<void> start() async {
    await controller.initialize();
    final source =
        controller.restorableRegistration ??
        widget.initialRegistrationRequestId;
    if (!controller.locked &&
        controller.pendingRegistration == null &&
        source != null) {
      registration.text = source;
      await controller.loadContext(source);
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(changed);
    controller.dispose();
    registration.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> safeClose() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          t('Safely close this preparation?', 'إغلاق هذا التحضير بأمان؟'),
        ),
        content: Text(
          t(
            'If work was already created, its actual receipt will be shown. This does not cancel issued work or refund a payment.',
            'إذا تم إنشاء العمل بالفعل فسيظهر إيصالُه الفعلي. لا يلغي ذلك عملاً صادراً ولا يسترد دفعة.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('Keep checking', 'متابعة الفحص')),
          ),
          FilledButton(
            key: const ValueKey('confirm_walk_in_close'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('Request safe close', 'طلب إغلاق آمن')),
          ),
        ],
      ),
    );
    if (confirm == true) await controller.close();
  }

  Widget reference(String label, dynamic value) => Semantics(
    container: true,
    label: '$label: $value',
    child: ExcludeSemantics(
      child: SelectableText('$label: $value', textDirection: TextDirection.ltr),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final data = controller.contextData,
        result = controller.result,
        payload = controller.view['payload'] as Map?;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xff071a36),
        foregroundColor: Colors.white,
        title: Text(
          widget.priority == 'vip'
              ? t('VIP vehicle reception', 'استلام سيارة VIP')
              : t('Walk-in reception', 'استقبال خدمة مباشرة'),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                t('Received work only', 'استقبال العمل فقط'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (widget.priority == 'vip')
                Card(
                  key: const ValueKey('vip_intake_notice'),
                  child: ListTile(
                    leading: const Icon(Icons.star, color: Color(0xffb68a22)),
                    title: Text(
                      t('VIP priority requested', 'تم طلب أولوية VIP'),
                    ),
                    subtitle: Text(
                      t(
                        'VIP changes reception order only. It does not start service or confirm payment.',
                        'تغيّر VIP ترتيب الاستقبال فقط، ولا تبدأ الخدمة أو تؤكد الدفع.',
                      ),
                    ),
                  ),
                ),
              Text(
                t(
                  'No app account, loyalty visits, rewards or work-start action is created here. Collection uses the existing cashier ledger.',
                  'لا يُنشأ هنا حساب تطبيق أو زيارات ولاء أو مكافآت أو بدء تنفيذ العمل. يتم التحصيل من دفتر الكاشير الحالي.',
                ),
              ),
              if (controller.busy) const LinearProgressIndicator(),
              if (controller.pendingRegistration != null) ...[
                Text(
                  t(
                    'A registration receipt still needs acknowledgement before reception. No new service is created automatically.',
                    'يحتاج إيصال التسجيل إلى التأكيد قبل الاستقبال. لا يتم إنشاء خدمة جديدة تلقائياً.',
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('walk_in_resume_registration'),
                  onPressed:
                      widget.onResumeRegistration ??
                      () => Navigator.maybePop(context),
                  child: Text(
                    t(
                      'Review pending registration receipt',
                      'مراجعة إيصال التسجيل المعلق',
                    ),
                  ),
                ),
              ],
              if (controller.errorCode != null)
                Text(
                  controller.errorCode == 'access_denied'
                      ? t(
                          'Current staff access to this receipt or branch is unavailable.',
                          'صلاحية الموظف الحالية لهذا الإيصال أو الفرع غير متاحة.',
                        )
                      : controller.errorCode == 'stale'
                      ? t(
                          'Actual price or worker configuration changed. Safely close this preparation before refreshing.',
                          'تغير السعر الفعلي أو إعداد الموظفين. أغلق هذا التحضير بأمان قبل التحديث.',
                        )
                      : t(
                          'The outcome is unconfirmed. Keep the same reference; details stay locked until server resolution.',
                          'النتيجة غير مؤكدة. احتفظ بالمرجع نفسه؛ تبقى البيانات مقفلة حتى يحسمها الخادم.',
                        ),
                ),
              if (!controller.initialized ||
                  (controller.recoveryUncertain &&
                      controller.requestId == null))
                OutlinedButton(
                  key: const ValueKey('recover_walk_in'),
                  onPressed: controller.busy ? null : controller.initialize,
                  child: Text(t('Check saved command', 'فحص الطلب المحفوظ')),
                ),
              if (controller.requestId != null) ...[
                reference(
                  t('Staff recovery reference', 'مرجع استعادة الموظف'),
                  controller.requestId,
                ),
                if (controller.status == 'succeeded' && result != null) ...[
                  reference(
                    t('Work reference', 'مرجع العمل'),
                    result['work_reference'],
                  ),
                  reference(
                    t('Invoice reference', 'مرجع الفاتورة'),
                    result['invoice_number'],
                  ),
                  Text(
                    '${t('Frozen gross', 'الإجمالي المحفوظ')}: ${result['gross_amount']} ${result['currency']}',
                  ),
                  Text(
                    '${t('Current work status', 'حالة العمل الحالية')}: ${_workLabel(result['work_status'])}\n${t('Current invoice status', 'حالة الفاتورة الحالية')}: ${_invoiceLabel(result['invoice_status'])}\n${t('Current payment status', 'حالة الدفع الحالية')}: ${_paymentLabel(result['payment_status'])}',
                  ),
                  if (result['collectible_amount'] != null)
                    Text(
                      '${t('Currently collectible', 'القابل للتحصيل حالياً')}: ${result['collectible_amount']} ${result['currency']}',
                    ),
                  if (result['invoice_token'] != null)
                    OutlinedButton(
                      key: const ValueKey('walk_in_invoice'),
                      onPressed: controller.busy
                          ? null
                          : () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => InvoiceDocumentsScreen(
                                    client: widget.client,
                                    role: widget.role,
                                    initialToken: result['invoice_token'],
                                  ),
                                ),
                              );
                              if (mounted) await controller.recover();
                            },
                      child: Text(
                        t('View actual invoice', 'عرض الفاتورة الفعلية'),
                      ),
                    ),
                  if (widget.onOpenCashierLedger != null)
                    OutlinedButton(
                      onPressed: widget.onOpenCashierLedger,
                      child: Text(
                        t(
                          'Open existing cashier ledger',
                          'فتح دفتر الكاشير الحالي',
                        ),
                      ),
                    ),
                ] else if (controller.status == 'closed')
                  Text(
                    t(
                      'The server safely closed this unused command. A delayed request cannot create work under this reference.',
                      'أغلق الخادم هذا الطلب غير المستخدم بأمان. لا يستطيع طلب متأخر إنشاء عمل بهذا المرجع.',
                    ),
                  )
                else ...[
                  if (payload != null)
                    Text(
                      '${t('Server-saved preparation', 'التحضير المحفوظ على الخادم')}: ${payload['expected_price']} EGP · ${t('Assigned staff count', 'عدد الموظفين المحددين')}: ${(payload['staff_ids'] as List?)?.length ?? 0}',
                    ),
                  OutlinedButton(
                    key: const ValueKey('recover_walk_in'),
                    onPressed: controller.busy ? null : controller.recover,
                    child: Text(t('Check saved command', 'فحص الطلب المحفوظ')),
                  ),
                  if (controller.status == 'prepared')
                    FilledButton(
                      key: const ValueKey('place_walk_in'),
                      onPressed:
                          controller.busy ||
                              controller.pendingRegistration != null
                          ? null
                          : controller.place,
                      child: Text(
                        t(
                          'Create or retry this exact received work',
                          'إنشاء أو إعادة هذا العمل المستلم نفسه',
                        ),
                      ),
                    ),
                  if (controller.status == 'absent' &&
                      controller.canRetryPreparation)
                    OutlinedButton(
                      key: const ValueKey('retry_walk_in_preparation'),
                      onPressed:
                          controller.busy ||
                              controller.pendingRegistration != null
                          ? null
                          : controller.retryPreparation,
                      child: Text(
                        t(
                          'Retry the saved preparation if available',
                          'إعادة التحضير المحفوظ إن كان متاحاً',
                        ),
                      ),
                    ),
                  OutlinedButton(
                    key: const ValueKey('close_walk_in'),
                    onPressed: controller.busy ? null : safeClose,
                    child: Text(
                      t(
                        'Request safe close before editing',
                        'طلب إغلاق آمن قبل التعديل',
                      ),
                    ),
                  ),
                ],
                if (controller.terminal)
                  OutlinedButton(
                    key: const ValueKey('refresh_walk_in_receipt'),
                    onPressed: controller.busy ? null : controller.recover,
                    child: Text(
                      t(
                        'Refresh actual receipt status',
                        'تحديث حالة الإيصال الفعلية',
                      ),
                    ),
                  ),
                if (controller.terminal)
                  FilledButton(
                    key: const ValueKey('ack_walk_in'),
                    onPressed:
                        controller.busy ||
                            controller.pendingRegistration != null
                        ? null
                        : () async {
                            await controller.acknowledge();
                            if (mounted && !controller.locked) {
                              setState(() {
                                service = null;
                                selectedStaff.clear();
                                notes.clear();
                              });
                            }
                          },
                    child: Text(
                      t(
                        'I reviewed this result · Finish',
                        'راجعت هذه النتيجة · إنهاء',
                      ),
                    ),
                  ),
              ] else if (!controller.locked &&
                  controller.pendingRegistration == null) ...[
                OutlinedButton(
                  key: const ValueKey('recover_walk_in'),
                  onPressed: controller.recover,
                  child: Text(t('Check saved command', 'فحص الطلب المحفوظ')),
                ),
                if (controller.restorableRegistration != null)
                  OutlinedButton(
                    key: const ValueKey('discard_walk_in_context'),
                    onPressed: controller.busy
                        ? null
                        : () async {
                            await controller.discardRestoredContext();
                            if (controller.contextData == null && mounted) {
                              setState(() {
                                registration.clear();
                                service = null;
                                selectedStaff.clear();
                              });
                            }
                          },
                    child: Text(
                      t(
                        'Discard this reception selection',
                        'تجاهل اختيار هذا الاستقبال',
                      ),
                    ),
                  ),
                if (staffRole) ...[
                  TextField(
                    key: const ValueKey('walk_in_registration'),
                    controller: registration,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: t(
                        'Actual staff registration reference',
                        'مرجع تسجيل الموظف الفعلي',
                      ),
                    ),
                  ),
                  OutlinedButton(
                    key: const ValueKey('load_walk_in_context'),
                    onPressed: registration.text.trim().isEmpty
                        ? null
                        : () async {
                            setState(() {
                              service = null;
                              selectedStaff.clear();
                            });
                            await controller.loadContext(
                              registration.text.trim(),
                            );
                          },
                    child: Text(
                      t(
                        'Load authorized reception details',
                        'تحميل بيانات الاستقبال المصرح بها',
                      ),
                    ),
                  ),
                ] else
                  Text(
                    t(
                      'Only an authorized cashier, manager or owner can prepare a service and assign eligible workers.',
                      'لا يمكن تحضير الخدمة واختيار العمال إلا للكاشير أو المدير أو المالك المخوّل.',
                    ),
                  ),
                if (data != null) ...[
                  if ((data['branch'] as Map)[ar ? 'name_ar' : 'name_en'] !=
                      null)
                    Text(
                      '${t('Actual reception branch', 'فرع الاستقبال الفعلي')}: ${(data['branch'] as Map)[ar ? 'name_ar' : 'name_en']}',
                    ),
                  Text(
                    '${(data['subject'] as Map)['name']} · ${(data['subject'] as Map)['plate_number']}',
                  ),
                  Text(
                    '${t('Bound cashier from the actual receipt', 'الكاشير المرتبط بالإيصال الفعلي')}: ${(data['bound_cashier'] as Map)['name']}',
                  ),
                  if (data['can_prepare'] == true) ...[
                    DropdownButtonFormField<String>(
                      key: const ValueKey('walk_in_service'),
                      initialValue: service,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: t(
                          'Explicit actual service',
                          'الخدمة الفعلية المختارة',
                        ),
                      ),
                      items: [
                        for (final s in data['services'] as List)
                          DropdownMenuItem(
                            value: '${s['id']}',
                            child: Text(
                              '${s['name']} · ${s['price']} ${(data['branch'] as Map)['currency']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) => setState(() => service = id),
                    ),
                    if ((data['services'] as List).isEmpty)
                      Text(
                        t(
                          data['unpriced_services_count'] is int &&
                                  data['unpriced_services_count'] > 0
                              ? 'No approved price exists for this vehicle class. Ask the owner to set the branch rate; a legacy price will not be used.'
                              : 'No actual eligible service is configured for this branch and vehicle class.',
                          data['unpriced_services_count'] is int &&
                                  data['unpriced_services_count'] > 0
                              ? 'لا يوجد سعر معتمد لهذه الفئة. اطلب من المالك ضبط سعر الفرع؛ لن يُستخدم سعر قديم تلقائيًا.'
                              : 'لا توجد خدمة فعلية مؤهلة معدّة لهذا الفرع وفئة السيارة.',
                        ),
                      ),
                    Text(
                      t(
                        'Explicitly select eligible assigned workers',
                        'اختر الموظفين المؤهلين المحددين صراحةً',
                      ),
                    ),
                    for (final w in data['workers'] as List)
                      CheckboxListTile(
                        key: ValueKey('walk_in_worker_${w['id']}'),
                        title: Text('${w['name']}'),
                        value: selectedStaff.contains(w['id']),
                        onChanged: (yes) => setState(() {
                          if (yes == true) {
                            selectedStaff.add('${w['id']}');
                          } else {
                            selectedStaff.remove(w['id']);
                          }
                        }),
                      ),
                    if ((data['workers'] as List).isEmpty)
                      Text(
                        t(
                          'No eligible configured workers are available.',
                          'لا يوجد موظفون مؤهلون بإعداد فعلي.',
                        ),
                      ),
                    TextField(
                      key: const ValueKey('walk_in_notes'),
                      controller: notes,
                      maxLength: 1000,
                      decoration: InputDecoration(
                        labelText: t(
                          'Operational notes · optional',
                          'ملاحظات تشغيلية · اختياري',
                        ),
                      ),
                    ),
                    FilledButton(
                      key: const ValueKey('prepare_walk_in'),
                      onPressed: service == null || selectedStaff.isEmpty
                          ? null
                          : () => controller.prepareSelection(
                              service!,
                              selectedStaff.toList(),
                              notes.text,
                            ),
                      child: Text(
                        t(
                          'Save this exact preparation',
                          'حفظ هذا التحضير نفسه',
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _workLabel(dynamic value) => value == 'received'
      ? t('Received', 'تم الاستلام')
      : value == 'cancelled'
      ? t('Cancelled', 'ملغى')
      : t('Check current server state', 'راجع حالة الخادم الحالية');
  String _invoiceLabel(dynamic value) => value == 'active'
      ? t('Active', 'سارية')
      : value == 'void'
      ? t('Void', 'ملغاة')
      : value == 'refunded'
      ? t('Refunded', 'مستردة')
      : t('Check actual invoice', 'راجع الفاتورة الفعلية');
  String _paymentLabel(dynamic value) => value == 'paid'
      ? t('Paid', 'مدفوعة')
      : value == 'unpaid'
      ? t('Unpaid', 'غير مدفوعة')
      : value == 'cancelled'
      ? t('Cancelled', 'ملغاة')
      : value == 'refunded'
      ? t('Refunded', 'مستردة')
      : t('Check actual payment ledger', 'راجع دفتر الدفع الفعلي');
}
