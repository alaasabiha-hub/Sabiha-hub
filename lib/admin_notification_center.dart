import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

abstract class AdminNotificationGateway {
  String? get actorId;
  bool get hasCurrentSession;
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters);
}

class SupabaseAdminNotificationGateway implements AdminNotificationGateway {
  SupabaseAdminNotificationGateway(this.client)
    : actorId = client.auth.currentUser?.id;
  final SupabaseClient client;
  @override
  final String? actorId;
  @override
  bool get hasCurrentSession =>
      actorId != null && client.auth.currentUser?.id == actorId;

  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) {
    if (!hasCurrentSession) {
      throw const PostgrestException(message: 'Session changed', code: '42501');
    }
    return client.rpc(name, params: parameters);
  }
}

const adminNotificationCategories = <String, (String, String, IconData)>{
  'bookings': ('الحجوزات', 'Bookings', Icons.calendar_month_outlined),
  'cashier': ('الكاشير والتحصيل', 'Cashier & collection', Icons.point_of_sale),
  'inventory': ('المخزون', 'Inventory', Icons.inventory_2_outlined),
  'expenses': ('المصروفات', 'Expenses', Icons.payments_outlined),
  'documents': (
    'المستندات والتراخيص',
    'Documents & licenses',
    Icons.description_outlined,
  ),
  'complaints': ('الشكاوى', 'Complaints', Icons.support_agent),
  'reviews': ('التقييمات', 'Reviews', Icons.rate_review_outlined),
  'recruitment': ('التوظيف', 'Recruitment', Icons.badge_outlined),
  'payroll': (
    'الرواتب والعمولات',
    'Payroll & commissions',
    Icons.account_balance_wallet_outlined,
  ),
};

class AdminNotificationCenterScreen extends StatefulWidget {
  const AdminNotificationCenterScreen({
    super.key,
    required this.client,
    required this.role,
    this.gateway,
  });

  final SupabaseClient client;
  final String role;
  final AdminNotificationGateway? gateway;

  @override
  State<AdminNotificationCenterScreen> createState() =>
      _AdminNotificationCenterScreenState();
}

class _AdminNotificationCenterScreenState
    extends State<AdminNotificationCenterScreen> {
  late final AdminNotificationGateway _gateway =
      widget.gateway ?? SupabaseAdminNotificationGateway(widget.client);
  final Map<String, String> _readRequests = {};
  Timer? _refreshTimer;
  StreamSubscription<AuthState>? _authSubscription;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _settings = [];
  String? _category, _error;
  bool _unreadOnly = false, _busy = false;
  int _unread = 0, _epoch = 0;
  bool get _owner => widget.role == 'owner';
  bool get _sessionCurrent =>
      _gateway.hasCurrentSession && _gateway.actorId != null;

  @override
  void initState() {
    super.initState();
    if (_gateway is SupabaseAdminNotificationGateway) {
      _authSubscription = widget.client.auth.onAuthStateChange.listen((_) {
        if (!mounted) return;
        _epoch++;
        if (!_sessionCurrent) {
          setState(() {
            _items = [];
            _settings = [];
            _unread = 0;
            _error = 'session';
            _busy = false;
          });
          _readRequests.clear();
        } else {
          unawaited(_load());
        }
      });
    }
    unawaited(_load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_busy) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (!_sessionCurrent || _busy) return;
    final generation = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = Map<String, dynamic>.from(
        await _gateway.rpc('list_admin_notifications', {
          'p_category': _category,
          'p_unread_only': _unreadOnly,
          'p_limit': 100,
        }) as Map,
      );
      if (!_sessionCurrent || generation != _epoch) return;
      final rows = (list['items'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      List<Map<String, dynamic>> settings = _settings;
      if (_owner) {
        final response = Map<String, dynamic>.from(
          await _gateway.rpc('get_admin_notification_settings', const {})
              as Map,
        );
        settings = (response['settings'] as List)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList();
      }
      if (!mounted || !_sessionCurrent || generation != _epoch) return;
      setState(() {
        _items = rows;
        _settings = settings;
        _unread = (list['unread_count'] as num?)?.toInt() ?? 0;
        _busy = false;
      });
    } catch (_) {
      if (!mounted || generation != _epoch) return;
      setState(() {
        _items = [];
        _settings = [];
        _unread = 0;
        _busy = false;
        _error = 'load';
      });
    }
  }

  Future<void> _markRead(Map<String, dynamic> row) async {
    if (_busy || !_sessionCurrent || row['read'] == true) return;
    final generation = ++_epoch;
    final event = row['event_id'] as String;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = Map<String, dynamic>.from(
        await _gateway.rpc('mark_admin_notification_read', {
          'p_request': _readRequests.putIfAbsent(event, newOrderRequestId),
          'p_event': event,
        }) as Map,
      );
      if (!mounted || !_sessionCurrent || generation != _epoch) return;
      if (response['event_id'] != event || response['read'] != true) {
        throw StateError('Read receipt not confirmed');
      }
      setState(() {
        row['read'] = true;
        row['read_at'] = response['read_at'];
        if (_unread > 0) _unread--;
        _busy = false;
      });
      if (_unreadOnly) unawaited(_load());
    } catch (_) {
      if (!mounted || generation != _epoch) return;
      setState(() {
        _busy = false;
        _error = 'save';
      });
    }
  }

  Future<void> _saveSetting(Map<String, dynamic> setting) async {
    if (!_owner || _busy || !_sessionCurrent) return;
    final generation = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final roles = (setting['recipient_roles'] as List).cast<String>();
      final result = Map<String, dynamic>.from(
        await _gateway.rpc('save_admin_notification_setting', {
          'p_category': setting['category'],
          'p_enabled': setting['enabled'],
          'p_roles': roles,
          'p_expected_version': setting['version'],
        }) as Map,
      );
      if (!mounted || !_sessionCurrent || generation != _epoch) return;
      final index = _settings.indexWhere(
        (v) => v['category'] == setting['category'],
      );
      if (index < 0 || result['version'] is! num) {
        throw StateError('Bad version');
      }
      setState(() {
        _settings[index] = {..._settings[index], 'version': result['version']};
        _busy = false;
      });
      await _load();
    } catch (_) {
      if (!mounted || generation != _epoch) return;
      setState(() {
        _busy = false;
        _error = 'save';
      });
      await _load();
    }
  }

  String _locale(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  @override
  void dispose() {
    _epoch++;
    _refreshTimer?.cancel();
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return Scaffold(
      appBar: AppBar(
        title: Text(_locale('مركز إشعارات الإدارة', 'Admin notifications')),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Center(
              child: Text('${_locale('غير مقروءة', 'Unread')}: $_unread'),
            ),
          ),
          IconButton(
            tooltip: _locale('تحديث', 'Refresh'),
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _busy && _items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _locale(
                            'تعذر تحديث الإشعارات. اسحب للتحديث أو أعد المحاولة.',
                            'Notifications could not be refreshed. Pull to retry.',
                          ),
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 260,
                        child: DropdownButtonFormField<String?>(
                          initialValue: _category,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _locale(
                              'نوع الإشعار',
                              'Notification type',
                            ),
                          ),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(_locale('كل الأنواع', 'All types')),
                            ),
                            for (final entry
                                in adminNotificationCategories.entries)
                              DropdownMenuItem<String?>(
                                value: entry.key,
                                child: Text(
                                  ar ? entry.value.$1 : entry.value.$2,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) {
                                  setState(() => _category = value);
                                  unawaited(_load());
                                },
                        ),
                      ),
                      FilterChip(
                        label: Text(_locale('غير المقروء فقط', 'Unread only')),
                        selected: _unreadOnly,
                        onSelected: _busy
                            ? null
                            : (v) {
                                setState(() => _unreadOnly = v);
                                unawaited(_load());
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_owner) _buildOwnerSettings(ar),
                  if (_owner) const SizedBox(height: 12),
                  if (_items.isEmpty && _error == null)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          _locale(
                            'لا توجد إشعارات مطابقة.',
                            'No matching notifications.',
                          ),
                        ),
                      ),
                    ),
                  for (final item in _items) _notificationCard(item, ar),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      _locale(
                        'مركز داخلي فقط؛ لا يرسل إشعارات هاتف أو رسائل خارجية.',
                        'Internal inbox only; no push or external messages are sent.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _notificationCard(Map<String, dynamic> row, bool ar) {
    final category = adminNotificationCategories[row['category']];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          category?.$3 ?? Icons.notifications_outlined,
          color: row['read'] == true
              ? Colors.blueGrey
              : const Color(0xff174B83),
        ),
        title: Text((ar ? row['title_ar'] : row['title_en'])?.toString() ?? ''),
        subtitle: Text(
          '${(ar ? row['body_ar'] : row['body_en']) ?? ''}\n${row['created_at'] ?? ''}',
        ),
        isThreeLine: true,
        trailing: row['read'] == true
            ? const Icon(Icons.done_all, color: Colors.blueGrey)
            : TextButton(
                onPressed: _busy ? null : () => _markRead(row),
                child: Text(_locale('مقروء', 'Mark read')),
              ),
      ),
    );
  }

  Widget _buildOwnerSettings(bool ar) {
    const roles = <String, (String, String)>{
      'owner': ('المالك', 'Owner'),
      'manager': ('المدير', 'Manager'),
      'employee': ('الموظف', 'Employee'),
      'cashier': ('الكاشير', 'Cashier'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _locale(
                'إعدادات ظهور الإشعارات',
                'Notification visibility settings',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final setting in _settings) ...[
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_categoryLabel(setting['category'] as String, ar)),
                subtitle: Text(
                  _locale(
                    'التغيير يحفظ سجل مراجعة ويطبق على الرؤية الحالية.',
                    'Changes are audited and apply to current visibility.',
                  ),
                ),
                value: setting['enabled'] == true,
                onChanged: _busy
                    ? null
                    : (value) {
                        final roles = (setting['recipient_roles'] as List)
                            .cast<String>();
                        _saveSetting({
                          ...setting,
                          'enabled': value,
                          'recipient_roles': roles,
                        });
                      },
              ),
              Wrap(
                spacing: 4,
                children: [
                  for (final role in roles.entries)
                    FilterChip(
                      label: Text(ar ? role.value.$1 : role.value.$2),
                      selected: (setting['recipient_roles'] as List).contains(
                        role.key,
                      ),
                      onSelected: _busy || role.key == 'owner'
                          ? null
                          : (selected) {
                              final selectedRoles =
                                  (setting['recipient_roles'] as List)
                                      .cast<String>()
                                      .toSet();
                              if (selected) {
                                selectedRoles.add(role.key);
                              } else {
                                selectedRoles.remove(role.key);
                              }
                              _saveSetting({
                                ...setting,
                                'recipient_roles': selectedRoles.toList()
                                  ..sort(),
                              });
                            },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _categoryLabel(String category, bool ar) {
    final value = adminNotificationCategories[category];
    return value == null ? category : (ar ? value.$1 : value.$2);
  }
}
