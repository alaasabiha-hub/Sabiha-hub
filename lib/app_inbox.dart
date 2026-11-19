import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_customer_claim.dart'
    show OfflineClaimGateway, SupabaseOfflineClaimGateway;
import 'app_inbox_live.dart';
import 'invoices.dart' show matchesInitialAuthReplay;
import 'workflow.dart' show newOrderRequestId;

abstract interface class CustomerOperationalInboxGateway {
  String? get actorId;
  Future<Map<String, dynamic>> list();
  Future<Map<String, dynamic>> markRead(String notificationId);
}

class SupabaseCustomerOperationalInboxGateway
    implements CustomerOperationalInboxGateway {
  SupabaseCustomerOperationalInboxGateway(this.client)
    : actorId = client.auth.currentUser?.id;
  final SupabaseClient client;
  @override
  final String? actorId;

  void _check() {
    if (actorId == null || client.auth.currentUser?.id != actorId) {
      throw StateError('Customer session changed');
    }
  }

  @override
  Future<Map<String, dynamic>> list() async {
    _check();
    final value = await client.rpc(
      'list_my_customer_operational_notifications',
      params: {'p_limit': 100},
    );
    _check();
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> markRead(String notificationId) async {
    _check();
    final value = await client.rpc(
      'mark_my_customer_operational_notification_read',
      params: {'p_notification': notificationId},
    );
    _check();
    return Map<String, dynamic>.from(value as Map);
  }
}

/// Customer-scoped operational messages. Data is loaded from a session-bound
/// RPC, cleared as soon as the auth actor changes, and never cached locally.
class CustomerOperationalInboxSection extends StatefulWidget {
  const CustomerOperationalInboxSection({
    super.key,
    required this.gateway,
    this.onOpen,
  });
  final CustomerOperationalInboxGateway gateway;
  final Future<void> Function(String deepLink)? onOpen;

  @override
  State<CustomerOperationalInboxSection> createState() =>
      _CustomerOperationalInboxSectionState();
}

class _CustomerOperationalInboxSectionState
    extends State<CustomerOperationalInboxSection> {
  late final String? _actor = widget.gateway.actorId;
  StreamSubscription<AuthState>? _auth;
  List<Map<String, dynamic>> _items = [];
  int _unread = 0;
  bool _busy = false, _failed = false, _invalid = false;

  bool get _current =>
      mounted &&
      !_invalid &&
      _actor != null &&
      widget.gateway.actorId == _actor;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  @override
  void initState() {
    super.initState();
    if (_actor == null) {
      _invalid = true;
      return;
    }
    final source = widget.gateway;
    if (source is SupabaseCustomerOperationalInboxGateway) {
      final client = source.client;
      _auth = client.auth.onAuthStateChange.listen((event) {
        if (event.event == AuthChangeEvent.initialSession) return;
        if (client.auth.currentUser?.id != _actor ||
            event.session?.user.id != _actor) {
          if (!mounted) return;
          setState(() {
            _invalid = true;
            _items = [];
            _unread = 0;
          });
        }
      });
    }
    load();
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await widget.gateway.list();
      if (!_current) return;
      _items = (result['items'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(growable: true);
      _unread = (result['unread_count'] as num?)?.toInt() ?? 0;
    } catch (_) {
      if (_current) {
        _items = [];
        _unread = 0;
        _failed = true;
      }
    } finally {
      if (mounted && !_invalid) setState(() => _busy = false);
    }
  }

  Future<void> _markRead(Map<String, dynamic> row) async {
    if (!_current || row['read'] == true || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final id = '${row['notification_id']}';
      final response = await widget.gateway.markRead(id);
      if (!_current) return;
      if (response['notification_id'] != id || response['read'] != true) {
        throw StateError('Read not confirmed');
      }
      setState(() {
        row['read'] = true;
        row['read_at'] = response['read_at'];
        if (_unread > 0) _unread--;
      });
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (mounted && !_invalid) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (!_current) return;
    final link = row['deep_link']?.toString() ?? '';
    if (!RegExp(r'^/(booking|orders)(/|$)').hasMatch(link)) return;
    await _markRead(row);
    if (_current && widget.onOpen != null) await widget.onOpen!(link);
  }

  String _title(String event) => switch (event) {
    'booking_received' => t('تم استلام الحجز', 'Booking received'),
    'booking_confirmed' => t('تم تأكيد الحجز', 'Booking confirmed'),
    'booking_cancelled' => t('تم إلغاء الحجز', 'Booking cancelled'),
    'booking_rescheduled' => t('تم تغيير موعد الحجز', 'Booking rescheduled'),
    'booking_reminder' => t('تذكير بموعدك', 'Appointment reminder'),
    'service_started' => t('بدأت الخدمة', 'Service started'),
    'service_quality_check' => t('الخدمة قيد فحص الجودة', 'Quality check'),
    'vehicle_ready' => t('سيارتك جاهزة', 'Your vehicle is ready'),
    'vehicle_delivered' => t('تم تسليم السيارة', 'Vehicle delivered'),
    'service_cancelled' => t('تم إلغاء الخدمة', 'Service cancelled'),
    'loyalty_points_added' => t('أضيفت نقاط الولاء', 'Loyalty points added'),
    'loyalty_visit_earned' => t('تم تسجيل زيارة ولاء', 'Loyalty visit earned'),
    _ => t('تحديث من Sabiha Hub', 'Sabiha Hub update'),
  };

  String _body(Map<String, dynamic> row) {
    final event = '${row['event_type'] ?? ''}';
    final payload = row['payload'] is Map
        ? Map<String, dynamic>.from(row['payload'] as Map)
        : const <String, dynamic>{};
    if (event == 'loyalty_points_added') {
      final points = payload['points_earned'];
      return t('النقاط المكتسبة: $points', 'Points earned: $points');
    }
    if (event == 'loyalty_visit_earned') {
      final visits = payload['visits_earned'];
      return t('الزيارات المكتسبة: $visits', 'Visits earned: $visits');
    }
    final date = payload['booking_date']?.toString();
    final time = payload['booking_time']?.toString();
    if (date != null || time != null) {
      return t(
        'الموعد: ${date ?? ''} ${time ?? ''}',
        'Appointment: ${date ?? ''} ${time ?? ''}',
      );
    }
    return t(
      'افتح حجوزاتي لمتابعة التفاصيل.',
      'Open your bookings to view details.',
    );
  }

  String _when(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(local)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 32),
      Row(
        children: [
          Expanded(
            child: Text(
              t(
                'تحديثات الحجوزات والخدمة والولاء',
                'Booking, service & loyalty updates',
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: t('تحديث', 'Refresh'),
            onPressed: _busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      Text(t('غير المقروءة: $_unread', 'Unread: $_unread')),
      if (_busy) const LinearProgressIndicator(),
      if (_failed)
        Text(
          t(
            'تعذر تحميل التحديثات التشغيلية.',
            'Could not load operational updates.',
          ),
        ),
      if (!_busy && !_failed && _items.isEmpty)
        Text(t('لا توجد تحديثات تشغيلية.', 'No operational updates.')),
      for (final row in _items)
        Card(
          child: ListTile(
            leading: Icon(
              row['read'] == true
                  ? Icons.notifications_none
                  : Icons.notifications_active_outlined,
            ),
            title: Text(_title('${row['event_type'] ?? ''}')),
            subtitle: Text('${_body(row)}\n${_when(row['created_at'])}'),
            isThreeLine: true,
            trailing: row['read'] == true
                ? null
                : IconButton(
                    tooltip: t('تحديد كمقروء', 'Mark as read'),
                    onPressed: _busy ? null : () => _markRead(row),
                    icon: const Icon(Icons.done),
                  ),
            onTap: _busy ? null : () => _open(row),
          ),
        ),
    ],
  );
}

abstract interface class CustomerMarketingInboxGateway {
  String? get actorId;
  Future<Map<String, dynamic>> list();
  Future<Map<String, dynamic>> markRead(String recipientId);
}

class SupabaseCustomerMarketingInboxGateway
    implements CustomerMarketingInboxGateway {
  SupabaseCustomerMarketingInboxGateway(this.client)
    : actorId = client.auth.currentUser?.id;
  final SupabaseClient client;
  @override
  final String? actorId;

  void _check() {
    if (actorId == null || client.auth.currentUser?.id != actorId) {
      throw StateError('Customer session changed');
    }
  }

  @override
  Future<Map<String, dynamic>> list() async {
    _check();
    final value = await client.rpc('list_my_marketing_notifications');
    _check();
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> markRead(String recipientId) async {
    _check();
    final value = await client.rpc(
      'mark_my_marketing_notification_read',
      params: {'p_recipient': recipientId},
    );
    _check();
    return Map<String, dynamic>.from(value as Map);
  }
}

/// Campaign history is read from an actor-scoped server RPC. This widget does
/// not cache content across accounts and cannot create or dispatch campaigns.
class CustomerMarketingInboxSection extends StatefulWidget {
  const CustomerMarketingInboxSection({
    super.key,
    required this.gateway,
    this.onOpen,
  });
  final CustomerMarketingInboxGateway gateway;
  final Future<void> Function(String deepLink)? onOpen;

  @override
  State<CustomerMarketingInboxSection> createState() =>
      _CustomerMarketingInboxSectionState();
}

class _CustomerMarketingInboxSectionState
    extends State<CustomerMarketingInboxSection> {
  late final String? _actor;
  StreamSubscription<AuthState>? _auth;
  List<Map<String, dynamic>> _items = [];
  int _unread = 0;
  bool _busy = false, _failed = false, _invalid = false;

  bool get _current =>
      mounted &&
      !_invalid &&
      _actor != null &&
      widget.gateway.actorId == _actor;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  @override
  void initState() {
    super.initState();
    _actor = widget.gateway.actorId;
    if (_actor == null) {
      _invalid = true;
      return;
    }
    final source = widget.gateway;
    if (source is SupabaseCustomerMarketingInboxGateway) {
      final client = source.client;
      _auth = client.auth.onAuthStateChange.listen((event) {
        if (event.event == AuthChangeEvent.initialSession) return;
        if (client.auth.currentUser?.id != _actor ||
            event.session?.user.id != _actor) {
          if (!mounted) return;
          setState(() {
            _invalid = true;
            _items = [];
            _unread = 0;
          });
        }
      });
    }
    load();
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await widget.gateway.list();
      if (!_current) return;
      _items = (result['items'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(growable: true);
      _unread = (result['unread_count'] as num?)?.toInt() ?? 0;
    } catch (_) {
      if (_current) {
        _items = [];
        _unread = 0;
        _failed = true;
      }
    } finally {
      if (mounted && !_invalid) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (!_current) return;
    final link = row['deep_link']?.toString() ?? '/offers';
    if (!RegExp(r'^/(offers|booking)(/|$)').hasMatch(link)) return;
    await _markRead(row);
    if (_current && widget.onOpen != null) await widget.onOpen!(link);
  }

  Future<void> _markRead(Map<String, dynamic> row) async {
    if (!_current || row['read'] == true || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final response = await widget.gateway.markRead('${row['recipient_id']}');
      if (!_current) return;
      if (response['recipient_id'] != row['recipient_id'] ||
          response['read'] != true) {
        throw StateError('Read not confirmed');
      }
      setState(() {
        row['read'] = true;
        row['opened_at'] = response['opened_at'];
        if (_unread > 0) _unread--;
      });
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (mounted && !_invalid) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 32),
      Row(
        children: [
          Expanded(
            child: Text(
              t('العروض والتنبيهات التسويقية', 'Offers & marketing updates'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: t('تحديث', 'Refresh'),
            onPressed: _busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      Text(t('غير المقروءة: $_unread', 'Unread: $_unread')),
      if (_busy) const LinearProgressIndicator(),
      if (_failed)
        Text(
          t(
            'تعذر تحميل إشعارات العروض.',
            'Could not load offer notifications.',
          ),
        ),
      if (!_busy && !_failed && _items.isEmpty)
        Text(
          t(
            'لا توجد إشعارات تسويقية متاحة.',
            'No marketing notifications available.',
          ),
        ),
      for (final row in _items)
        Card(
          child: InkWell(
            onTap: _busy ? null : () => _open(row),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (row['image_url'] is String &&
                      '${row['image_url']}'.startsWith('https://'))
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        '${row['image_url']}',
                        height: 150,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  Text(
                    '${row[t('title_ar', 'title_en')] ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text('${row[t('body_ar', 'body_en')] ?? ''}'),
                  const SizedBox(height: 6),
                  Text(
                    '${row['created_at'] ?? ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (row['read'] != true)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(
                        onPressed: _busy ? null : () => _markRead(row),
                        child: Text(t('تحديد كمقروء', 'Mark as read')),
                      ),
                    ),
                  if (row['deep_link'] != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: _busy ? null : () => _open(row),
                        icon: const Icon(Icons.open_in_new),
                        label: Text(t('فتح', 'Open')),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// Server-scoped in-app messages only. No push, SMS, private-table subscription,
/// persisted message cache, or client-created notification content.
class AppInboxController extends ChangeNotifier {
  AppInboxController({required this.gateway, required this.actorId})
    : _actor = actorId();
  final OfflineClaimGateway gateway;
  final String? Function() actorId;
  final String? _actor;
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic>? cursor;
  int unread = 0;
  bool busy = false, failed = false, _disposed = false, _invalidated = false;
  int _epoch = 0;
  final Map<String, String> _readRequests = {};
  final Map<String, String> _dismissRequests = {};

  bool get current =>
      !_disposed && !_invalidated && _actor != null && actorId() == _actor;
  void resetForSession({bool invalidate = false}) {
    if (_disposed) return;
    _epoch++;
    _invalidated = invalidate;
    items = [];
    cursor = null;
    unread = 0;
    busy = false;
    failed = false;
    // Retain same-actor event nonces: an old read may have committed before
    // the session changed, so any future retry must use its exact nonce.
    notifyListeners();
  }

  void clearOnAccountChange() {
    if (current || _disposed) return;
    _epoch++;
    items = [];
    cursor = null;
    unread = 0;
    busy = false;
    failed = false;
    _readRequests.clear();
    _dismissRequests.clear();
    notifyListeners();
  }

  Future<void> refresh({bool more = false}) async {
    if (!current) {
      clearOnAccountChange();
      return;
    }
    if (busy || (more && cursor == null)) return;
    final epoch = ++_epoch;
    busy = true;
    failed = false;
    notifyListeners();
    try {
      final result = Map<String, dynamic>.from(
        await gateway.rpc('list_my_app_inbox', {
          'p_before_created_at': more ? cursor!['created_at'] : null,
          'p_before_event': more ? cursor!['event_id'] : null,
          'p_limit': 25,
        }) as Map,
      );
      if (!current || epoch != _epoch) return;
      final page = (result['items'] as List)
          .map((x) => Map<String, dynamic>.from(x as Map))
          .toList();
      final merged = <String, Map<String, dynamic>>{
        if (more)
          for (final row in items) row['event_id'] as String: row,
        for (final row in page) row['event_id'] as String: row,
      };
      items = merged.values.toList();
      unread = (result['unread_count'] as num).toInt();
      cursor = result['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(result['next_cursor'] as Map);
    } catch (_) {
      if (current && epoch == _epoch) {
        // Do not leave potentially stale private messages visible on permission
        // loss or network failure. Refresh retrieves current authorized facts.
        items = [];
        cursor = null;
        unread = 0;
        failed = true;
      }
    } finally {
      if (current && epoch == _epoch) {
        busy = false;
        notifyListeners();
      }
      if (!current) clearOnAccountChange();
    }
  }

  Future<void> dismiss(String event) async {
    if (!current ||
        busy ||
        !items.any((x) => x['event_id'] == event && x['can_dismiss'] == true)) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    failed = false;
    notifyListeners();
    try {
      final response = Map<String, dynamic>.from(
        await gateway.rpc('dismiss_my_app_inbox_event', {
          'p_request': _dismissRequests.putIfAbsent(event, newOrderRequestId),
          'p_event': event,
        }) as Map,
      );
      if (!current || epoch != _epoch) return;
      if (response['event_id'] != event ||
          response['dismissed'] != true ||
          response['administrative_record_preserved'] != true) {
        throw StateError('Unconfirmed personal dismissal');
      }
      final row = items.firstWhere((x) => x['event_id'] == event);
      if (row['read'] != true && unread > 0) unread--;
      items.removeWhere((x) => x['event_id'] == event);
    } catch (_) {
      if (current && epoch == _epoch) {
        items = [];
        cursor = null;
        unread = 0;
        failed = true;
      }
    } finally {
      if (current && epoch == _epoch) {
        busy = false;
        notifyListeners();
      }
      if (!current) clearOnAccountChange();
    }
  }

  Future<void> markRead(String event) async {
    if (!current || busy || !items.any((x) => x['event_id'] == event)) return;
    final epoch = ++_epoch;
    busy = true;
    failed = false;
    notifyListeners();
    try {
      final response = Map<String, dynamic>.from(
        await gateway.rpc('mark_my_app_inbox_read', {
          'p_request': _readRequests.putIfAbsent(event, newOrderRequestId),
          'p_event': event,
        }) as Map,
      );
      if (!current || epoch != _epoch) return;
      if (response['event_id'] != event || response['read'] != true) {
        throw StateError('Unconfirmed read receipt');
      }
      final row = items.firstWhere((x) => x['event_id'] == event);
      if (row['read'] != true && unread > 0) unread--;
      row['read'] = true;
      row['read_at'] = response['read_at'];
    } catch (_) {
      if (current && epoch == _epoch) {
        items = [];
        cursor = null;
        unread = 0;
        failed = true;
      }
    } finally {
      if (current && epoch == _epoch) {
        busy = false;
        notifyListeners();
      }
      if (!current) clearOnAccountChange();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}

class AppInboxScreen extends StatefulWidget {
  const AppInboxScreen({
    super.key,
    required this.client,
    this.controller,
    this.onOpenRecovery,
    this.onOpenOrders,
    this.onOpenMarketingLink,
    this.marketingGateway,
    this.operationalGateway,
    this.onOpenOperationalLink,
    this.liveTransport,
  });
  final SupabaseClient client;
  final AppInboxController? controller;
  final AppInboxLiveTransport? liveTransport;
  final Future<void> Function(String? caseId)? onOpenRecovery;
  final Future<void> Function()? onOpenOrders;
  final Future<void> Function(String deepLink)? onOpenMarketingLink;
  final CustomerMarketingInboxGateway? marketingGateway;
  final CustomerOperationalInboxGateway? operationalGateway;
  final Future<void> Function(String deepLink)? onOpenOperationalLink;
  @override
  State<AppInboxScreen> createState() => _AppInboxScreenState();
}

class _AppInboxScreenState extends State<AppInboxScreen>
    with WidgetsBindingObserver {
  late final AppInboxController flow;
  StreamSubscription<AuthState>? auth;
  late final AppInboxLiveTransport live;
  Timer? poll, debounce;
  bool foreground = true,
      active = false,
      dirty = true,
      identityLost = false,
      changingSession = false;
  int liveEpoch = 0, authEpoch = 0;
  late final String? boundActor;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    flow =
        widget.controller ??
        AppInboxController(
          gateway: SupabaseOfflineClaimGateway(widget.client),
          actorId: () => widget.client.auth.currentUser?.id,
        );
    live = widget.liveTransport ?? SupabaseAppInboxLiveTransport(widget.client);
    boundActor = widget.client.auth.currentUser?.id;
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    flow.addListener(changed);
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final same = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (same || event.event == AuthChangeEvent.initialSession) return;
      final session = widget.client.auth.currentSession;
      final sameActor =
          !identityLost &&
          boundActor != null &&
          session != null &&
          session.user.id == boundActor &&
          widget.client.auth.currentUser?.id == boundActor &&
          event.session?.user.id == boundActor &&
          event.session?.accessToken == session.accessToken;
      if (sameActor) {
        unawaited(renewSession());
      } else {
        authEpoch++;
        identityLost = true;
        syncVisibility();
        flow.resetForSession(invalidate: true);
      }
    });
    if (boundActor == null) {
      identityLost = true;
      flow.resetForSession(invalidate: true);
    }
  }

  Future<void> renewSession() async {
    final epoch = ++authEpoch;
    changingSession = true;
    syncVisibility();
    flow.resetForSession();
    try {
      await live.unsubscribe();
      await live.reauthenticate();
      if (!mounted ||
          identityLost ||
          epoch != authEpoch ||
          widget.client.auth.currentUser?.id != boundActor) {
        return;
      }
      changingSession = false;
      syncVisibility();
    } catch (_) {
      if (mounted && epoch == authEpoch) {
        changingSession = false;
        identityLost = true;
        syncVisibility();
        flow.resetForSession(invalidate: true);
      }
    }
  }

  void syncVisibility() {
    final next =
        mounted &&
        foreground &&
        !identityLost &&
        !changingSession &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (next == active) return;
    active = next;
    final epoch = ++liveEpoch;
    dirty = true;
    poll?.cancel();
    debounce?.cancel();
    debounce = null;
    if (!active) {
      unawaited(live.unsubscribe().catchError((Object _) {}));
      return;
    }
    // Broadcast carries no authority or content; every wake reads the RPC.
    void wake() {
      if (mounted && active && liveEpoch == epoch) hint();
    }

    unawaited(
      live.subscribe(onHint: wake, onReconnect: wake).catchError((Object _) {
        if (mounted && active && liveEpoch == epoch) hint();
      }),
    );
    poll = Timer.periodic(const Duration(seconds: 20), (_) => hint());
    hint();
  }

  void hint() {
    dirty = true;
    if (!active || flow.busy || debounce != null) return;
    debounce = Timer(const Duration(milliseconds: 150), () {
      debounce = null;
      if (!mounted || !active || !dirty || flow.busy) return;
      dirty = false;
      unawaited(flow.refresh());
    });
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    if (active && dirty && !flow.busy) hint();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncVisibility();
  }

  @override
  void didUpdateWidget(covariant AppInboxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.controller != widget.controller ||
        oldWidget.liveTransport != widget.liveTransport) {
      authEpoch++;
      identityLost = true;
      syncVisibility();
      flow.resetForSession(invalidate: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    syncVisibility();
  }

  @override
  void dispose() {
    poll?.cancel();
    debounce?.cancel();
    liveEpoch++;
    authEpoch++;
    active = false;
    unawaited(live.unsubscribe().catchError((Object _) {}));
    auth?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    flow.removeListener(changed);
    if (widget.controller == null) flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('الإشعارات', 'Notifications')),
      actions: [
        IconButton(
          key: const Key('inbox_refresh'),
          tooltip: t('تحديث', 'Refresh'),
          onPressed: flow.busy ? null : () => flow.refresh(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.onOpenOrders != null)
          OutlinedButton.icon(
            onPressed: widget.onOpenOrders,
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(t('طلباتي ومواعيدي', 'My orders & appointments')),
          ),
        Text(t('غير المقروءة: ${flow.unread}', 'Unread: ${flow.unread}')),
        if (flow.busy) const LinearProgressIndicator(),
        if (flow.failed)
          Text(
            t(
              'تعذر جلب الإشعارات. أعد المحاولة.',
              'Could not retrieve notifications. Try again.',
            ),
          ),
        if (!flow.busy && !flow.failed && flow.items.isEmpty)
          Text(t('لا توجد إشعارات متاحة.', 'No notifications available.')),
        for (final row in flow.items)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    row[t('title_ar', 'title_en')]?.toString() ?? '',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(row[t('body_ar', 'body_en')]?.toString() ?? ''),
                  const SizedBox(height: 8),
                  Text(_date(row['created_at'])),
                  if (row['read'] != true)
                    TextButton(
                      onPressed: flow.busy
                          ? null
                          : () => flow.markRead(row['event_id'] as String),
                      child: Text(t('تحديد كمقروء', 'Mark as read')),
                    ),
                  if (row['can_dismiss'] == true)
                    TextButton.icon(
                      onPressed: flow.busy
                          ? null
                          : () => flow.dismiss(row['event_id'] as String),
                      icon: const Icon(Icons.visibility_off_outlined),
                      label: Text(t('إزالة من قائمتي', 'Remove from my list')),
                    ),
                  if (row['source_kind'] == 'visit_recovery' &&
                      widget.onOpenRecovery != null)
                    TextButton(
                      onPressed: flow.busy
                          ? null
                          : () => widget.onOpenRecovery!(
                              row['case_reference']?.toString(),
                            ),
                      child: Text(t('متابعة الطلب', 'View request')),
                    ),
                ],
              ),
            ),
          ),
        if (flow.cursor != null)
          OutlinedButton(
            onPressed: flow.busy ? null : () => flow.refresh(more: true),
            child: Text(t('المزيد', 'More')),
          ),
        if (widget.marketingGateway != null)
          CustomerMarketingInboxSection(
            gateway: widget.marketingGateway!,
            onOpen: widget.onOpenMarketingLink,
          ),
        if (widget.operationalGateway != null)
          CustomerOperationalInboxSection(
            gateway: widget.operationalGateway!,
            onOpen: widget.onOpenOperationalLink,
          ),
      ],
    ),
  );
  String _date(dynamic value) {
    final stamp = DateTime.tryParse(value?.toString() ?? '');
    if (stamp == null) return '';
    final local = stamp.toLocal();
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(local)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }
}
