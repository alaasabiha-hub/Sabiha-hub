import 'package:flutter/material.dart';

enum CustomerPushPermission {
  notDetermined,
  authorized,
  provisional,
  denied,
  unavailable,
}

class CustomerNotificationPreferences {
  final bool operationalPush;
  final bool marketingPush;
  final bool marketingInApp;
  final bool saved;

  const CustomerNotificationPreferences({
    required this.operationalPush,
    required this.marketingPush,
    required this.marketingInApp,
    this.saved = true,
  });

  const CustomerNotificationPreferences.defaults({
    this.operationalPush = false,
    this.marketingPush = false,
    this.marketingInApp = false,
    this.saved = false,
  });

  CustomerNotificationPreferences copyWith({
    bool? operationalPush,
    bool? marketingPush,
    bool? marketingInApp,
    bool? saved,
  }) => CustomerNotificationPreferences(
    operationalPush: operationalPush ?? this.operationalPush,
    marketingPush: marketingPush ?? this.marketingPush,
    marketingInApp: marketingInApp ?? this.marketingInApp,
    saved: saved ?? this.saved,
  );
}

abstract interface class CustomerNotificationSettingsGateway {
  Future<CustomerPushPermission> permission();
  Future<CustomerPushPermission> requestPermission();
  Future<void> openSystemSettings();
  Future<void> synchronizePermission(CustomerPushPermission permission);
  Future<CustomerNotificationPreferences> loadPreferences();
  Future<void> savePreferences(CustomerNotificationPreferences preferences);
}

class CustomerNotificationSettingsPanel extends StatefulWidget {
  final CustomerNotificationSettingsGateway gateway;

  const CustomerNotificationSettingsPanel({super.key, required this.gateway});

  @override
  State<CustomerNotificationSettingsPanel> createState() =>
      _CustomerNotificationSettingsPanelState();
}

class _CustomerNotificationSettingsPanelState
    extends State<CustomerNotificationSettingsPanel>
    with WidgetsBindingObserver {
  CustomerPushPermission _permission = CustomerPushPermission.unavailable;
  CustomerNotificationPreferences _preferences =
      const CustomerNotificationPreferences.defaults();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  bool get _arabic => Localizations.localeOf(context).languageCode == 'ar';
  String _text(String ar, String en) => _arabic ? ar : en;
  bool get _pushAllowed =>
      _permission == CustomerPushPermission.authorized ||
      _permission == CustomerPushPermission.provisional;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    try {
      final permission = await widget.gateway.permission();
      await widget.gateway.synchronizePermission(permission);
      if (!mounted) return;
      setState(() {
        _permission = permission;
        if (!_preferences.saved &&
            (permission == CustomerPushPermission.authorized ||
                permission == CustomerPushPermission.provisional)) {
          _preferences = _preferences.copyWith(operationalPush: true);
        }
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final permission = await widget.gateway.permission();
      await widget.gateway.synchronizePermission(permission);
      final stored = await widget.gateway.loadPreferences();
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _preferences =
            !stored.saved &&
                (permission == CustomerPushPermission.authorized ||
                    permission == CustomerPushPermission.provisional)
            ? stored.copyWith(operationalPush: true)
            : stored;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _text(
            'تعذر تحميل إعدادات الإشعارات.',
            'Could not load notification settings.',
          );
        });
      }
    }
  }

  Future<void> _permissionAction() async {
    if (_permission == CustomerPushPermission.denied) {
      try {
        await widget.gateway.openSystemSettings();
      } catch (_) {
        if (mounted) {
          setState(
            () => _notice = _text(
              'افتح إعدادات التطبيق ثم فعّل الإشعارات.',
              'Open app settings and enable notifications.',
            ),
          );
        }
      }
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final permission = await widget.gateway.requestPermission();
      await widget.gateway.synchronizePermission(permission);
      if (!mounted) return;
      setState(() {
        _permission = permission;
        if (permission == CustomerPushPermission.authorized ||
            permission == CustomerPushPermission.provisional) {
          _preferences = _preferences.copyWith(operationalPush: true);
        }
      });
      if (_pushAllowed) await _save(alreadySaving: true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            'تعذر طلب إذن الإشعارات. حاول مرة أخرى.',
            'Could not request notification permission. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save({bool alreadySaving = false}) async {
    if (_saving && !alreadySaving) return;
    final hasPushPreference =
        _preferences.operationalPush || _preferences.marketingPush;
    if (hasPushPreference && !_pushAllowed) {
      setState(() {
        _error = _text(
          'اسمح بإشعارات الهاتف أولًا. لا يمكن للتطبيق تجاوز قرارك.',
          'Allow phone notifications first. The app cannot override your choice.',
        );
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.gateway.savePreferences(_preferences);
      if (!mounted) return;
      setState(() {
        _preferences = _preferences.copyWith(saved: true);
        _notice = _text('تم حفظ الإعدادات.', 'Settings saved.');
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            'تعذر حفظ الإعدادات. حاول مرة أخرى.',
            'Could not save settings. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final permissionLabel = switch (_permission) {
      CustomerPushPermission.authorized => _text('مسموح', 'Allowed'),
      CustomerPushPermission.provisional => _text(
        'مسموح مؤقتًا',
        'Provisional',
      ),
      CustomerPushPermission.denied => _text('مرفوض', 'Denied'),
      CustomerPushPermission.notDetermined => _text(
        'لم يُطلب بعد',
        'Not requested',
      ),
      CustomerPushPermission.unavailable => _text(
        'غير متاح على هذا الجهاز',
        'Unavailable on this device',
      ),
    };
    final permissionButtonLabel = _permission == CustomerPushPermission.denied
        ? _text('فتح إعدادات إشعارات التطبيق', 'Open app notification settings')
        : _text(
            'طلب إذن إشعارات الهاتف',
            'Request phone notification permission',
          );
    return Card(
      key: const ValueKey('customer_notification_settings'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(_text('إعدادات الإشعارات', 'Notification settings')),
              subtitle: Text(
                _text(
                  'حالة إذن الهاتف: $permissionLabel',
                  'Phone permission: $permissionLabel',
                ),
              ),
            ),
            if (!_pushAllowed &&
                _permission != CustomerPushPermission.unavailable)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _permissionAction,
                    icon: const Icon(Icons.settings_outlined),
                    label: Text(permissionButtonLabel),
                  ),
                ),
              ),
            SwitchListTile(
              value: _preferences.operationalPush,
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(
                  operationalPush: value,
                ),
              ),
              title: Text(
                _text(
                  'إشعارات الحجوزات والخدمة',
                  'Booking and service updates',
                ),
              ),
              subtitle: Text(
                _text(
                  'تأكيد الحجز والتذكير وتحديث الخدمة وجاهزية السيارة والولاء.',
                  'Booking confirmation/reminders, service status, vehicle readiness and loyalty.',
                ),
              ),
            ),
            SwitchListTile(
              value: _preferences.marketingInApp,
              onChanged: (value) => setState(
                () =>
                    _preferences = _preferences.copyWith(marketingInApp: value),
              ),
              title: Text(_text('العروض داخل التطبيق', 'In-app offers')),
              subtitle: Text(
                _text(
                  'اختياري ومستقل عن إشعارات الهاتف.',
                  'Optional and separate from phone notifications.',
                ),
              ),
            ),
            SwitchListTile(
              value: _preferences.marketingPush,
              onChanged: (value) => setState(
                () =>
                    _preferences = _preferences.copyWith(marketingPush: value),
              ),
              title: Text(
                _text('العروض على الهاتف', 'Marketing push notifications'),
              ),
              subtitle: Text(
                _text(
                  'اختياري ويتطلب موافقتك الصريحة وإذن النظام.',
                  'Optional; requires your explicit consent and system permission.',
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_notice != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_notice!)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    _saving
                        ? _text('جارٍ الحفظ...', 'Saving...')
                        : _text(
                            'حفظ إعدادات الإشعارات',
                            'Save notification settings',
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
