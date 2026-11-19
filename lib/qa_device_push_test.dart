import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum QaPushPermission { granted, provisional, denied }

abstract interface class QaDevicePushGateway {
  Future<QaPushPermission> requestPermission();
  Future<String?> getRegistrationToken();
  Stream<void> get foregroundMessages;
}

class FirebaseQaDevicePushGateway implements QaDevicePushGateway {
  @override
  Future<QaPushPermission> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized => QaPushPermission.granted,
      AuthorizationStatus.provisional => QaPushPermission.provisional,
      _ => QaPushPermission.denied,
    };
  }

  @override
  Future<String?> getRegistrationToken() =>
      FirebaseMessaging.instance.getToken();

  @override
  Stream<void> get foregroundMessages =>
      FirebaseMessaging.onMessage.map<void>((_) {});
}

bool canUseQaDevicePushTool({
  required bool debugMode,
  required bool isWeb,
  required String appEnvironment,
  required bool firebaseConfigured,
}) => debugMode && !isWeb && appEnvironment == 'staging' && firebaseConfigured;

class QaDevicePushTestScreen extends StatefulWidget {
  final QaDevicePushGateway? gateway;
  final Future<void> Function(String token)? copyToken;

  const QaDevicePushTestScreen({super.key, this.gateway, this.copyToken});

  @override
  State<QaDevicePushTestScreen> createState() => _QaDevicePushTestScreenState();
}

class _QaDevicePushTestScreenState extends State<QaDevicePushTestScreen> {
  late final QaDevicePushGateway _gateway =
      widget.gateway ?? FirebaseQaDevicePushGateway();
  StreamSubscription<void>? _foregroundSubscription;
  String? _token;
  QaPushPermission? _permission;
  bool _loading = false;
  bool _copied = false;
  int _foregroundCount = 0;

  @override
  void initState() {
    super.initState();
    _foregroundSubscription = _gateway.foregroundMessages.listen((_) {
      if (mounted) setState(() => _foregroundCount++);
    });
  }

  @override
  void dispose() {
    _foregroundSubscription?.cancel();
    super.dispose();
  }

  String _text(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  Future<void> _prepareDevice() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final permission = await _gateway.requestPermission();
      String? token;
      if (permission != QaPushPermission.denied) {
        token = await _gateway.getRegistrationToken();
        if (token != null && token.trim().isEmpty) token = null;
      }
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _token = token;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _text(
                'تعذر تجهيز رمز هذا الجهاز. تحقق من اتصال Firebase QA.',
                'Could not prepare this device token. Check Firebase QA setup.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyToken() async {
    final token = _token;
    if (token == null) return;
    await (widget.copyToken ?? _writeClipboard)(token);
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _writeClipboard(String token) =>
      Clipboard.setData(ClipboardData(text: token));

  @override
  Widget build(BuildContext context) {
    final granted =
        _permission == QaPushPermission.granted ||
        _permission == QaPushPermission.provisional;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _text('اختبار إشعارات هذا الجهاز', 'This-device push test'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(Icons.notifications_active_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              _text(
                'اختبار محلي لجهاز QA فقط',
                'Local test for this QA device only',
              ),
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _text(
                'لا يحتاج هذا الاختبار إلى حساب عميل، ولا يحفظ الرمز في Supabase ولا يربطه بأي حساب. الرمز يخص تثبيت هذا التطبيق على هذا الجهاز فقط.',
                'This test needs no customer account. It does not save the token to Supabase or link it to an account. The token is for this app installation on this device only.',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading ? null : _prepareDevice,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.phonelink_ring),
              label: Text(
                _text(
                  'طلب الإذن وتجهيز رمز الجهاز',
                  'Request permission and prepare token',
                ),
              ),
            ),
            if (_permission != null) ...[
              const SizedBox(height: 16),
              Text(
                _permission == QaPushPermission.denied
                    ? _text(
                        'إذن الإشعارات غير مسموح. فعّله من إعدادات Android ثم أعد المحاولة.',
                        'Notifications are not allowed. Enable them in Android settings and try again.',
                      )
                    : _text('الإذن مسموح.', 'Permission is granted.'),
              ),
            ],
            if (_token != null) ...[
              const SizedBox(height: 12),
              SelectableText(_token!, textDirection: TextDirection.ltr),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _copyToken,
                  icon: const Icon(Icons.copy),
                  label: Text(
                    _copied
                        ? _text('تم النسخ على جهازك', 'Copied on this device')
                        : _text('نسخ رمز الجهاز', 'Copy device token'),
                  ),
                ),
              ),
              Text(
                _text(
                  'لا ترسل الرمز في المحادثة. يمكنك لصقه بنفسك في Firebase Console ضمن رسالة اختبار موجّهة إلى رمز تسجيل واحد. لا تضغط إرسال قبل موافقتك الصريحة.',
                  'Do not send the token in chat. Paste it yourself into Firebase Console as a one-device test message. Do not send until you explicitly approve.',
                ),
              ),
            ],
            if (_foregroundCount > 0) ...[
              const SizedBox(height: 16),
              Text(
                _text(
                  'استقبل التطبيق $_foregroundCount إشعارًا أثناء فتحه.',
                  'The app received $_foregroundCount notification(s) while open.',
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (granted && _token == null)
              Text(
                _text(
                  'لم يُرجع Firebase رمزًا بعد. تحقق من أن Google Play services محدثة على الجهاز.',
                  'Firebase did not return a token. Check that Google Play services are up to date.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
