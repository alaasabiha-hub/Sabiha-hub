// Durable operational work transitions; financial settlement remains separate.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'service_quality.dart';
import 'workflow.dart' show newOrderRequestId;

enum ServiceWorkRoute { legacy, canonical, review }

// Only explicit, server-authorized legacy facts permit the original route.
// Unknown contexts and denied requests never fall back to a direct update.
ServiceWorkRoute serviceWorkRoute(
  Map<String, dynamic> work, {
  required bool booking,
  required String requestedStatus,
}) {
  if (booking && work['legacy_unpaired_booking'] == true) {
    return ServiceWorkRoute.legacy;
  }
  if (booking &&
      requestedStatus == 'in_progress' &&
      work['legacy_booking_alignment'] == true) {
    return ServiceWorkRoute.legacy;
  }
  if (!booking && work['legacy_active_progress'] == true) {
    return ServiceWorkRoute.legacy;
  }
  return work['canonical_work_supported'] == true
      ? ServiceWorkRoute.canonical
      : ServiceWorkRoute.review;
}

abstract class ServiceWorkGateway {
  Future<Map<String, dynamic>> context({String? order, String? booking});
  Future<Map<String, dynamic>> queue(String branch);
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> parameters);
  Future<Map<String, dynamic>> recover(String? request);
  Future<Map<String, dynamic>> place(String request);
  Future<Map<String, dynamic>> close(String request);
  Future<Map<String, dynamic>> acknowledge(String request);
}

class SupabaseServiceWorkGateway implements ServiceWorkGateway {
  SupabaseServiceWorkGateway(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> parameters,
  ) async {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    final value = await client.rpc(name, params: parameters) as Map;
    if (client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return Map<String, dynamic>.from(value);
  }

  @override
  Future<Map<String, dynamic>> context({String? order, String? booking}) =>
      call('get_service_work_context', {
        'p_order': order,
        'p_booking': booking,
      });
  @override
  Future<Map<String, dynamic>> queue(String branch) =>
      call('list_service_work_queue', {'p_branch': branch});
  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> parameters) =>
      call('prepare_service_work', parameters);
  @override
  Future<Map<String, dynamic>> recover(String? request) =>
      call('get_service_work_command', {'p_request': request});
  @override
  Future<Map<String, dynamic>> place(String request) =>
      call('place_service_work', {'p_request': request});
  @override
  Future<Map<String, dynamic>> close(String request) =>
      call('close_service_work_command', {'p_request': request});
  @override
  Future<Map<String, dynamic>> acknowledge(String request) =>
      call('ack_service_work_command', {'p_request': request});
}

abstract class ServiceWorkStore {
  Future<String?> read();
  Future<void> write(String request);
  Future<void> clear();
}

class SharedServiceWorkStore implements ServiceWorkStore {
  SharedServiceWorkStore(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  String get key {
    if (actor == null || client.auth.currentUser?.id != actor) {
      throw StateError('Staff session changed');
    }
    return 'service_work_request_$actor';
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
      throw StateError('Reference not saved');
    }
  }

  @override
  Future<void> clear() async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Reference not cleared');
    }
  }
}

class ServiceWorkController extends ChangeNotifier {
  ServiceWorkController({
    required this.gateway,
    required this.store,
    this.order,
    this.booking,
  });
  final ServiceWorkGateway gateway;
  final ServiceWorkStore store;
  final String? order, booking;
  String? requestId, errorCode;
  Map<String, dynamic> command = {};
  Map<String, dynamic>? contextData, _pendingPreparation;
  bool initialized = false, busy = false, uncertain = false, _disposed = false;
  String? get status => command['status'] as String?;
  bool get terminal => status == 'succeeded' || status == 'closed';
  bool get locked => !initialized || busy || requestId != null || uncertain;
  bool get canPrepare => !locked && contextData?['can_prepare'] == true;
  bool get canRetryPreparation =>
      requestId != null && _pendingPreparation != null && !terminal;
  Map<String, dynamic>? get result => command['result'] is Map
      ? Map<String, dynamic>.from(command['result'] as Map)
      : null;
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  void changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> run(
    Future<void> Function() action, {
    bool mutation = true,
  }) async {
    if (busy || _disposed) {
      return;
    }
    busy = true;
    errorCode = null;
    changed();
    try {
      await action();
    } on PostgrestException catch (error) {
      errorCode = switch (error.code) {
        '42501' => 'access_denied',
        '40001' => 'stale',
        '55000' => 'blocked',
        _ => 'unconfirmed',
      };
      if (mutation || requestId != null) {
        uncertain = true;
      }
    } catch (_) {
      errorCode = 'unconfirmed';
      if (mutation || requestId != null) {
        uncertain = true;
      }
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> apply(Map<String, dynamic> response) async {
    final state = response['status'];
    if (state == 'absent') {
      command = response;
      uncertain = requestId != null;
      if (uncertain) {
        errorCode = 'unconfirmed';
      }
      return;
    }
    final id = response['request_id'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        (requestId != null && requestId != id) ||
        !['prepared', 'succeeded', 'closed'].contains(state)) {
      throw StateError('Unconfirmed receipt');
    }
    if (requestId == null) {
      await store.write(id);
      requestId = id;
    }
    if (state == 'prepared') {
      final payload = response['payload'];
      if (payload is! Map ||
          payload['order_id'] is! String ||
          payload['expected_status'] is! String ||
          payload['next_status'] is! String ||
          payload['reason'] is! String) {
        throw StateError('Missing server preparation');
      }
    }
    if (state == 'succeeded' &&
        (response['result'] is! Map ||
            (response['result'] as Map)['order_id'] == null)) {
      throw StateError('Missing actual work receipt');
    }
    if (state == 'closed' &&
        (response['result'] is! Map ||
            (response['result'] as Map)['status'] != 'closed')) {
      throw StateError('Missing close fence');
    }
    command = response;
    uncertain = false;
  }

  Future<void> fetchContext() async {
    contextData = null;
    final savedOrder = (command['payload'] as Map?)?['order_id'] as String?;
    if (requestId != null && result?['current_state_available'] == false) {
      return;
    }
    if (savedOrder != null) {
      contextData = await gateway.context(order: savedOrder);
    } else if (order != null || booking != null) {
      contextData = await gateway.context(
        order: order,
        booking: order == null ? booking : null,
      );
    }
  }

  Future<void> refreshContextAdvisory() async {
    try {
      await fetchContext();
    } on PostgrestException catch (error) {
      errorCode = error.code == '42501'
          ? 'access_denied'
          : 'context_unavailable';
    } catch (_) {
      errorCode = 'context_unavailable';
    }
  }

  Future<void> recoverInternal() async {
    if (requestId == null) {
      final saved = await store.read();
      if (saved != null) {
        if (!_uuid.hasMatch(saved)) {
          throw StateError('Invalid saved reference');
        }
        requestId = saved;
      }
    }
    await apply(await gateway.recover(requestId));
    if (!uncertain) {
      await refreshContextAdvisory();
    }
  }

  Future<void> initialize() async {
    await run(recoverInternal);
    initialized = true;
    changed();
  }

  Future<void> recover() => run(recoverInternal);
  Future<void> refreshContext() => run(fetchContext, mutation: false);
  Future<void> prepare(String reason) async {
    if (!canPrepare) {
      return;
    }
    if (reason.trim().length < 5 || reason.trim().length > 500) {
      errorCode = 'invalid_reason';
      changed();
      return;
    }
    final view = contextData!;
    final target = view['order_id'];
    final expected = view['work_status'];
    final next = view['next_status'];
    if (target is! String || expected is! String || next is! String) {
      return;
    }
    await run(() async {
      final id = newOrderRequestId();
      // Persist only identity BEFORE any server preparation. Never save reason/context locally.
      await store.write(id);
      requestId = id;
      _pendingPreparation = Map<String, dynamic>.unmodifiable({
        'p_request': id,
        'p_order': target,
        'p_expected_status': expected,
        'p_next_status': next,
        'p_reason': reason.trim(),
      });
      await apply(await gateway.prepare(_pendingPreparation!));
    });
  }

  Future<void> retryPreparation() => run(() async {
    if (!canRetryPreparation) {
      return;
    }
    await apply(await gateway.prepare(_pendingPreparation!));
  });
  Future<void> place() => run(() async {
    if (requestId == null ||
        status != 'prepared' ||
        result?['current_state_available'] == false) {
      return;
    }
    await apply(await gateway.place(requestId!));
    if (result?['current_state_available'] != false) {
      await refreshContextAdvisory();
    }
  });
  Future<void> close() => run(() async {
    if (requestId == null) {
      return;
    }
    await apply(await gateway.close(requestId!));
  });
  Future<void> acknowledge() => run(() async {
    if (requestId == null || !terminal) {
      return;
    }
    final response = await gateway.acknowledge(requestId!);
    if (response['request_id'] != requestId ||
        response['acknowledged'] != true ||
        !['succeeded', 'closed'].contains(response['status'])) {
      throw StateError('Acknowledgment unconfirmed');
    }
    await store.clear();
    requestId = null;
    command = {};
    _pendingPreparation = null;
    uncertain = false;
    // Discover another device's own pending action before allowing a fresh change.
    await apply(await gateway.recover(null));
    if (!uncertain) {
      await refreshContextAdvisory();
    }
  });
  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    super.dispose();
  }
}

String _say(BuildContext context, String ar, String en) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
String _statusText(BuildContext context, String? status) => switch (status) {
  'received' => _say(context, 'بانتظار العمل', 'Awaiting work'),
  'in_progress' => _say(context, 'قيد التنفيذ', 'In progress'),
  'quality_check' => _say(context, 'مراجعة الجودة', 'Quality check'),
  'completed' => _say(context, 'مكتمل', 'Completed'),
  'delivered' => _say(context, 'تم التسليم', 'Delivered'),
  _ => '—',
};
String _actionText(BuildContext context, String? status) => switch (status) {
  'in_progress' => _say(context, 'بدء الخدمة', 'Start service'),
  'quality_check' => _say(
    context,
    'الانتقال لمراجعة الجودة',
    'Move to quality check',
  ),
  'completed' => _say(context, 'تأكيد اكتمال الخدمة', 'Confirm completion'),
  'delivered' => _say(context, 'تأكيد التسليم', 'Confirm delivery'),
  _ => _say(context, 'لا توجد خطوة تالية', 'No next action'),
};
String _blockerText(BuildContext context, String code) => switch (code) {
  'capacity_recheck_required' => _say(
    context,
    'السعة مشغولة حالياً. حدّث الحالة قبل البدء.',
    'Capacity is occupied. Refresh before starting.',
  ),
  'typed_inspection_adapter_required' ||
  'approved_before_after_inspections_required' => _say(
    context,
    'تقارير الفحص المطلوبة لم تكتمل بعد.',
    'Required inspection reports are not ready.',
  ),
  'branch_closed_for_start' ||
  'service_hours_not_open' ||
  'booking_service_day_required' => _say(
    context,
    'موعد البدء خارج ساعات أو يوم الخدمة المسموح.',
    'Starting is outside the allowed service hours or day.',
  ),
  'current_work_permission_required' => _say(
    context,
    'هذه الخطوة تحتاج تكليفاً أو صلاحية إدارة.',
    'This step needs an assignment or management permission.',
  ),
  'no_next_work_action' => _say(
    context,
    'لا توجد خطوة عمل تالية.',
    'No further work action is available.',
  ),
  _ => _say(
    context,
    'تحتاج حالة الخدمة إلى مراجعة الإدارة قبل المتابعة.',
    'Management needs to review this service before continuing.',
  ),
};

class ServiceWorkScreen extends StatefulWidget {
  const ServiceWorkScreen({super.key, required this.controller});
  factory ServiceWorkScreen.forOrder({
    Key? key,
    required SupabaseClient client,
    required String order,
  }) => ServiceWorkScreen(
    key: key,
    controller: ServiceWorkController(
      gateway: SupabaseServiceWorkGateway(client),
      store: SharedServiceWorkStore(client),
      order: order,
    ),
  );
  factory ServiceWorkScreen.forBooking({
    Key? key,
    required SupabaseClient client,
    required String booking,
  }) => ServiceWorkScreen(
    key: key,
    controller: ServiceWorkController(
      gateway: SupabaseServiceWorkGateway(client),
      store: SharedServiceWorkStore(client),
      booking: booking,
    ),
  );
  final ServiceWorkController controller;
  @override
  State<ServiceWorkScreen> createState() => _ServiceWorkScreenState();
}

class _ServiceWorkScreenState extends State<ServiceWorkScreen> {
  final reason = TextEditingController();
  ServiceWorkController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    if (!c.initialized) {
      unawaited(c.initialize());
    }
  }

  void changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    c.removeListener(changed);
    c.dispose();
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = c.contextData ?? <String, dynamic>{};
    final service = view['service'] as Map? ?? {};
    final payload = c.command['payload'] as Map? ?? {};
    final result = c.result ?? <String, dynamic>{};
    final blockers = (view['blockers'] as List? ?? [])
        .map((v) => v.toString())
        .toList();
    final crew = (view['assigned_staff'] as List? ?? [])
        .whereType<Map>()
        .map((v) => v['name'])
        .whereType<String>()
        .join(' · ');
    final reference = result['work_reference'] ?? view['work_reference'] ?? '—';
    return PopScope(
      canPop: !c.locked,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_say(context, 'تنفيذ الخدمة', 'Service work')),
          actions: [
            if (c.gateway is SupabaseServiceWorkGateway &&
                view['order_id'] is String &&
                !c.locked)
              IconButton(
                tooltip: _say(
                  context,
                  'فحص جودة الخدمة',
                  'Service quality check',
                ),
                icon: const Icon(Icons.fact_check_outlined),
                onPressed: c.busy
                    ? null
                    : () async {
                        final gateway = c.gateway as SupabaseServiceWorkGateway;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ServiceQualityScreen(
                              order: view['order_id'] as String,
                              gateway: SupabaseServiceQualityGateway(
                                gateway.client,
                              ),
                            ),
                          ),
                        );
                        if (mounted && !c.locked) await c.refreshContext();
                      },
              ),
            IconButton(
              tooltip: _say(context, 'تحديث', 'Refresh'),
              onPressed: c.busy
                  ? null
                  : c.requestId != null || c.uncertain
                  ? c.recover
                  : c.refreshContext,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (c.busy || !c.initialized) const LinearProgressIndicator(),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            reference.toString(),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (service['name'] != null)
                            Text(service['name'].toString()),
                          if (view['plate_number'] != null)
                            Text(view['plate_number'].toString()),
                          Text(
                            _statusText(
                              context,
                              result['current_state_available'] == false
                                  ? null
                                  : result['current_work_status'] as String? ??
                                        view['work_status'] as String?,
                            ),
                          ),
                          if (crew.isNotEmpty) Text(crew),
                        ],
                      ),
                    ),
                  ),
                  if (c.errorCode != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          c.errorCode == 'context_unavailable'
                              ? _say(
                                  context,
                                  'تعذر تحديث بيانات الخدمة. حدّث الحالة عند عودة الاتصال.',
                                  'Service details could not refresh. Try refreshing when connected.',
                                )
                              : c.errorCode == 'invalid_reason'
                              ? _say(
                                  context,
                                  'اكتب سبباً من ٥ إلى ٥٠٠ حرف قبل الحفظ.',
                                  'Enter a reason of 5 to 500 characters before saving.',
                                )
                              : c.errorCode == 'access_denied'
                              ? _say(
                                  context,
                                  c.requestId == null
                                      ? 'لا تملك صلاحية عرض هذه الخدمة. ارجع إلى قائمة أعمالك.'
                                      : 'تغيرت صلاحية الوصول. راجع طلبك المحفوظ دون تنفيذ خطوة جديدة.',
                                  c.requestId == null
                                      ? 'You do not have access to this service. Return to your work list.'
                                      : 'Access has changed. Review the saved request before making another change.',
                                )
                              : c.errorCode == 'stale'
                              ? _say(
                                  context,
                                  'تغيرت حالة أو تكليف الخدمة. أغلق التغيير المعلّق وحدّث البيانات.',
                                  'Service state or assignment changed. Close the pending change and refresh.',
                                )
                              : _say(
                                  context,
                                  'لم تتأكد نتيجة التغيير بعد. راجع الطلب المحفوظ أو أعد المحاولة بنفس الطلب.',
                                  'The result is not confirmed. Check the saved change or retry the same request.',
                                ),
                        ),
                      ),
                    ),
                  if (c.requestId != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _say(context, 'تغيير محفوظ', 'Saved change'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (payload['next_status'] is String)
                              Text(
                                _actionText(
                                  context,
                                  payload['next_status'] as String,
                                ),
                              ),
                            if (payload['reason'] is String)
                              Text(payload['reason'] as String),
                            if (c.status == 'succeeded')
                              Text(
                                _say(
                                  context,
                                  'تم تسجيل الخطوة. راجع الحالة الحالية ثم أكد الاستلام.',
                                  'The step was recorded. Review its current state and confirm receipt.',
                                ),
                              ),
                            if (c.status == 'closed')
                              Text(
                                _say(
                                  context,
                                  'أُغلق هذا التغيير المعلّق.',
                                  'This pending change is closed.',
                                ),
                              ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (c.status == 'prepared')
                                  FilledButton(
                                    onPressed: c.busy ? null : c.place,
                                    child: Text(
                                      _say(
                                        context,
                                        'تطبيق التغيير المحفوظ',
                                        'Apply saved change',
                                      ),
                                    ),
                                  ),
                                if (!c.terminal)
                                  OutlinedButton(
                                    onPressed: c.busy ? null : c.close,
                                    child: Text(
                                      _say(
                                        context,
                                        'إغلاق التغيير المعلّق',
                                        'Close pending change',
                                      ),
                                    ),
                                  ),
                                if (c.canRetryPreparation &&
                                    c.status != 'prepared')
                                  OutlinedButton(
                                    onPressed: c.busy
                                        ? null
                                        : c.retryPreparation,
                                    child: Text(
                                      _say(
                                        context,
                                        'إعادة نفس الطلب',
                                        'Retry same request',
                                      ),
                                    ),
                                  ),
                                if (c.terminal)
                                  FilledButton(
                                    onPressed: c.busy ? null : c.acknowledge,
                                    child: Text(
                                      _say(
                                        context,
                                        'تأكيد وتحديث',
                                        'Confirm and refresh',
                                      ),
                                    ),
                                  ),
                                TextButton(
                                  onPressed: c.busy ? null : c.recover,
                                  child: Text(
                                    _say(
                                      context,
                                      'مراجعة الطلب المحفوظ',
                                      'Check saved change',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (c.requestId == null && c.uncertain)
                    OutlinedButton(
                      onPressed: c.busy ? null : c.recover,
                      child: Text(
                        _say(
                          context,
                          'استعادة التغيير المحفوظ',
                          'Recover saved change',
                        ),
                      ),
                    ),
                  if (!c.locked && view.isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final code in blockers)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(_blockerText(context, code)),
                              ),
                            TextField(
                              controller: reason,
                              enabled: c.canPrepare,
                              minLines: 2,
                              maxLines: 4,
                              maxLength: 500,
                              decoration: InputDecoration(
                                labelText: _say(
                                  context,
                                  'سبب الخطوة أو ملاحظتها',
                                  'Step reason or note',
                                ),
                              ),
                            ),
                            FilledButton(
                              onPressed: c.canPrepare
                                  ? () => c.prepare(reason.text)
                                  : null,
                              child: Text(
                                view['next_status'] == 'in_progress' &&
                                        view['admission_is_continuation'] ==
                                            true
                                    ? _say(
                                        context,
                                        'تسجيل تقدم العمل الحالي',
                                        'Record existing work progress',
                                      )
                                    : _actionText(
                                        context,
                                        view['next_status'] as String?,
                                      ),
                              ),
                            ),
                            TextButton(
                              onPressed: c.refreshContext,
                              child: Text(
                                _say(context, 'تحديث الحالة', 'Refresh status'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    _say(
                      context,
                      'إغلاق التغيير يخص الطلب المعلّق فقط ولا يوقف العمل. إلغاء خدمات الفاتورة المؤهلة متاح للإدارة من نقطة البيع، ورد المبلغ يحتاج تأكيدًا منفصلًا.',
                      'Closing a pending change affects that request only and does not stop work. Management can cancel eligible invoiced services from point of sale; a money refund requires separate confirmation.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ServiceWorkQueueScreen extends StatefulWidget {
  const ServiceWorkQueueScreen({
    super.key,
    required this.client,
    required this.branch,
  });
  final SupabaseClient client;
  final String branch;
  @override
  State<ServiceWorkQueueScreen> createState() => _ServiceWorkQueueScreenState();
}

class _ServiceWorkQueueScreenState extends State<ServiceWorkQueueScreen> {
  List<Map<String, dynamic>> items = [];
  bool busy = true, failed = false, more = false;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        busy = true;
        failed = false;
      });
    }
    try {
      final response = await SupabaseServiceWorkGateway(widget.client)
          .queue(widget.branch);
      if (mounted) {
        setState(() {
          items = (response['items'] as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList();
          more = response['more_available'] == true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => failed = true);
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_say(context, 'طابور الخدمات', 'Service queue')),
      actions: [
        IconButton(
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: busy
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (failed)
                Text(
                  _say(
                    context,
                    'تعذر تحميل أعمال الفرع. حدّث القائمة.',
                    'Could not load branch work. Refresh the list.',
                  ),
                ),
              for (final item in items)
                Card(
                  child: ListTile(
                    leading: Icon(
                      item['vip'] == true
                          ? Icons.star
                          : Icons.build_circle_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(
                      '${item['work_reference']} · ${(item['service'] as Map?)?['name'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${item['plate_number'] ?? ''} · ${_statusText(context, item['work_status'] as String?)}',
                    ),
                    onTap: item['canonical_work_supported'] == true
                        ? () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ServiceWorkScreen.forOrder(
                                  client: widget.client,
                                  order: item['order_id'] as String,
                                ),
                              ),
                            );
                            await load();
                          }
                        : null,
                  ),
                ),
              if (more)
                Text(
                  _say(
                    context,
                    'تظهر أول ١٠٠ خدمة حسب أولوية الخادم.',
                    'Showing the first 100 services in server priority order.',
                  ),
                ),
            ],
          ),
  );
}
