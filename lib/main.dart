import 'dart:async';
import 'dart:convert';

import 'mixed_points_earnings.dart';
import 'owner_catalog_editor.dart';
import 'catalog_refresh.dart';
import 'catalog_media.dart' show enrichCatalogImages;
import 'owner_service_commission.dart';
import 'service_quality.dart';
import 'printer_device_settings.dart';

import 'package:flutter/services.dart';

import 'customer_visuals.dart';
import 'customer_booking_ui.dart';

import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_build_policy.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_config.dart';
import 'qa_environment_banner.dart';
import 'app_language_controller.dart';
import 'customer_notification_settings.dart';
import 'customer_push_policy.dart';
import 'customer_session_guard.dart';
import 'qa_device_push_test.dart';
import 'workflow.dart';
import 'service_work.dart';
import 'service_booking_attempt.dart';
import 'customer_service_reward.dart';
import 'invoice_presentation.dart';
import 'customer_booking_changes.dart';
import 'offline_customer_claim.dart';
import 'offline_history.dart';
import 'customer_financial_consent_route.dart';
import 'app_inbox.dart';
import 'app_inbox_live.dart';
import 'admin_notification_center.dart';
import 'visit_recovery_evidence.dart';
import 'owner_visit_recovery.dart';
import 'companies_fleets_catalogue.dart';
import 'fleet_contract_drafts.dart';
import 'owner_system_health.dart';
import 'owner_reward_issuer.dart';
import 'owner_tax_invoice_settings.dart';
import 'owner_notifications.dart';
import 'payment_settings_hub.dart';
import 'payment_finance.dart';
import 'owner_business_insights.dart';
import 'owner_finance_dashboard.dart';
import 'loyalty_policy.dart';
import 'loyalty_visit_lifecycle.dart';
import 'hr_payroll.dart';
import 'recruitment.dart';
import 'admin_console.dart';
import 'owner_daily_closure.dart';
import 'document_assistant.dart';
import 'delivery_support.dart';
import 'branch_settings.dart';
import 'customer_care.dart';
import 'cashier_shifts.dart';
import 'cashier_point_of_sale.dart';
import 'vehicle_inspections.dart';
import 'invoices.dart';
import 'sabiha_splash.dart';
import 'sabiha_web_startup.dart';
import 'offers_catalog.dart';
import 'public_landing.dart';
import 'offer_management.dart';
import 'owner_coupons.dart';
import 'current_catalog.dart';
import 'vehicle_pricing.dart';
import 'welcome_ui.dart' show approvedBrandAsset;
import 'staff_profile.dart';

final supabase = Supabase.instance.client;
final appNavigatorKey = GlobalKey<NavigatorState>();
AppLanguageController? _activeSabihaLanguage;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: ios
              ? const String.fromEnvironment('FIREBASE_IOS_API_KEY')
              : const String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
          appId: ios
              ? const String.fromEnvironment('FIREBASE_IOS_APP_ID')
              : const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
          messagingSenderId: const String.fromEnvironment(
            'FIREBASE_MESSAGING_SENDER_ID',
          ),
          projectId: const String.fromEnvironment('FIREBASE_PROJECT_ID'),
          iosBundleId: ios
              ? const String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID')
              : null,
        ),
      );
    }
    if (kDebugMode) {
      debugPrint(
        'FCM QA: background message received (${message.messageId ?? 'no-id'})',
      );
    }
  } catch (error) {
    if (kDebugMode) {
      debugPrint('FCM QA: background handler failed (${error.runtimeType})');
    }
  }
}

Future<void> _changeSabihaLanguage(String language) =>
    _activeSabihaLanguage?.setLanguage(language) ?? Future<void>.value();

Locale get _sabihaCurrentLocale =>
    _activeSabihaLanguage?.locale ?? const Locale('ar');

Future<void> pushAppRoute(
  BuildContext context, {
  required String name,
  required WidgetBuilder builder,
  Object? arguments,
  bool replace = false,
  bool clearStack = false,
}) {
  final navigator = Navigator.of(context);
  if (kIsWeb) {
    if (clearStack) {
      return navigator.pushNamedAndRemoveUntil<void>(
        name,
        (_) => false,
        arguments: arguments,
      );
    } else if (replace) {
      return navigator.pushReplacementNamed<void, void>(
        name,
        arguments: arguments,
      );
    } else {
      return navigator.pushNamed<void>(name, arguments: arguments);
    }
  }
  final route = MaterialPageRoute<void>(
    settings: RouteSettings(name: name, arguments: arguments),
    builder: builder,
  );
  if (clearStack) {
    return navigator.pushAndRemoveUntil<void>(route, (_) => false);
  } else if (replace) {
    return navigator.pushReplacement<void, void>(route);
  } else {
    return navigator.push<void>(route);
  }
}

void _toggleSabihaLanguage() {
  // Locale changes are routed through the app root; no page or drawer context
  // is retained while the root rebuilds and deactivates the old subtree.
  final current = _sabihaCurrentLocale.languageCode;
  unawaited(_changeSabihaLanguage(current == 'ar' ? 'en' : 'ar'));
}

PreferredSizeWidget _publicDesktopHeader(BuildContext context) => AppBar(
  automaticallyImplyLeading: false,
  toolbarHeight: 82,
  backgroundColor: Colors.white,
  foregroundColor: navy,
  titleSpacing: 8,
  leadingWidth: 190,
  leading: Padding(
    padding: const EdgeInsetsDirectional.only(start: 18, top: 6, bottom: 6),
    child: Row(
      children: [
        SizedBox(
          width: 62,
          height: 68,
          child: Image.asset(
            approvedBrandAsset,
            fit: BoxFit.contain,
            semanticLabel: 'Sabiha Hub',
          ),
        ),
        const SizedBox(width: 8),
        const Flexible(
          child: Text(
            'Sabiha Hub',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.ltr,
            style: TextStyle(
              color: navy,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    ),
  ),
  title: Wrap(
    spacing: 4,
    children: [
      for (final entry in [
        ('/', 'الرئيسية', 'Home'),
        ('/services', 'الخدمات', 'Services'),
        ('/offers', 'العروض والباقات', 'Offers'),
        ('/booking', 'الحجز', 'Booking'),
        ('/shop', 'المتجر', 'Shop'),
      ])
        TextButton(
          onPressed: () => pushAppRoute(
            context,
            name: entry.$1,
            builder: (_) => switch (entry.$1) {
              '/services' => const PublicServicesScreen(),
              '/offers' => const CustomerOffersScreen(),
              '/booking' => _customerPageForRoute('/booking'),
              '/shop' => const CustomerShopScreen(),
              _ => HomeScreen(
                locale: _sabihaCurrentLocale,
                onLanguageChanged: _changeSabihaLanguage,
              ),
            },
          ),
          style: TextButton.styleFrom(foregroundColor: navy),
          child: Text(
            tr(context, entry.$2, entry.$3),
            style: const TextStyle(color: navy, fontWeight: FontWeight.w700),
          ),
        ),
    ],
  ),
  actions: [
    TextButton(
      onPressed: _toggleSabihaLanguage,
      style: TextButton.styleFrom(foregroundColor: navy),
      child: Text(
        Localizations.localeOf(context).languageCode == 'ar' ? 'EN' : 'العربية',
        style: const TextStyle(color: navy, fontWeight: FontWeight.w700),
      ),
    ),
    TextButton(
      onPressed: () => pushAppRoute(
        context,
        name: '/account',
        builder: (_) => _customerPageForRoute('/account'),
      ),
      style: TextButton.styleFrom(foregroundColor: navy),
      child: Text(
        tr(context, 'حساب العميل', 'Customer sign in'),
        style: const TextStyle(color: navy, fontWeight: FontWeight.w700),
      ),
    ),
    const SizedBox(width: 18),
  ],
);

Future<void> openCustomerInbox(BuildContext context) async {
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => _guardCustomerPage(
        '/inbox',
        AppInboxScreen(
          client: supabase,
          marketingGateway: SupabaseCustomerMarketingInboxGateway(supabase),
          operationalGateway: SupabaseCustomerOperationalInboxGateway(supabase),
          onOpenMarketingLink: PushNotificationService.openCustomerDeepLink,
          onOpenOperationalLink: PushNotificationService.openCustomerDeepLink,
          onOpenRecovery: (_) async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => VisitRecoveryEvidenceScreen(client: supabase),
              ),
            );
          },
          onOpenOrders: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => FulfillmentOrdersScreen(client: supabase),
              ),
            );
          },
        ),
      ),
    ),
  );
}

Future<void> openOwnerInbox(BuildContext context) async {
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => AppInboxScreen(
        client: supabase,
        onOpenRecovery: (_) async {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => OwnerVisitRecoveryScreen(
                client: supabase,
                onCanonicalReview: (context, claimId) async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          OwnerOfflineClaimReviewsScreen(client: supabase),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );
}

class PushNotificationService {
  static String? _registeredToken;
  static String? _registeredUserId;
  static StreamSubscription<AuthState>? _authSubscription;
  static bool _permissionPromptOpen = false;
  static const MethodChannel _notificationSettingsChannel = MethodChannel(
    'com.sabihahub.app/notification_settings',
  );
  static const _androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static String get _apiKey =>
      defaultTargetPlatform == TargetPlatform.iOS ? _iosApiKey : _androidApiKey;
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
  static const _iosPushDisabledForPersonalTeam = bool.fromEnvironment(
    'IOS_QA_DISABLE_PUSH',
    defaultValue: false,
  );
  static bool _initialized = false;
  static RemoteMessage? _pendingInitialMessage;
  static final Set<String> _shownForegroundMessageIds = {};

  static void _log(String event, {String? messageId, Object? error}) {
    if (!kDebugMode) return;
    final id = messageId == null ? '' : ' id=$messageId';
    final failure = error == null ? '' : ' error=${error.runtimeType}';
    debugPrint('FCM QA: $event$id$failure');
  }

  static bool get isConfigured => pushAllowedForBuild(
    configured:
        _apiKey.isNotEmpty &&
        _projectId.isNotEmpty &&
        _senderId.isNotEmpty &&
        ((defaultTargetPlatform == TargetPlatform.android &&
                _androidAppId.isNotEmpty) ||
            (defaultTargetPlatform == TargetPlatform.iOS &&
                _iosAppId.isNotEmpty)),
    isIos: defaultTargetPlatform == TargetPlatform.iOS,
    disableIosPush: _iosPushDisabledForPersonalTeam,
  );

  static Future<void> initialize() async {
    if (_initialized || kIsWeb || !isConfigured) return;
    final appId = defaultTargetPlatform == TargetPlatform.iOS
        ? _iosAppId
        : _androidAppId;
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: _apiKey,
        appId: appId,
        messagingSenderId: _senderId,
        projectId: _projectId,
        iosBundleId: defaultTargetPlatform == TargetPlatform.iOS
            ? _iosBundleId
            : null,
      ),
    );
    _initialized = true;
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen((message) {
      _log('foreground-received', messageId: message.messageId);
      _showForegroundMessage(message);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _log('opened', messageId: message.messageId);
      _handleOpenedMessage(message);
    });
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message == null) return;
      _pendingInitialMessage = message;
      flushPendingMessage();
    });
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _log('token-refreshed');
      _saveRegisteredToken(token);
    });
    _authSubscription ??= supabase.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedOut) {
        _registeredToken = null;
        _registeredUserId = null;
        return;
      }
      unawaited(registerIfConsented());
    });
    await registerIfConsented();
  }

  static Future<CustomerPushPermission> permissionStatus() async {
    if (!_initialized || kIsWeb || !isConfigured) {
      return CustomerPushPermission.unavailable;
    }
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return _permissionFromAuthorization(settings.authorizationStatus);
  }

  static CustomerPushPermission _permissionFromAuthorization(
    AuthorizationStatus status,
  ) => switch (status) {
    AuthorizationStatus.authorized => CustomerPushPermission.authorized,
    AuthorizationStatus.provisional => CustomerPushPermission.provisional,
    AuthorizationStatus.denied => CustomerPushPermission.denied,
    AuthorizationStatus.notDetermined => CustomerPushPermission.notDetermined,
  };

  static Future<CustomerPushPermission> requestCustomerPermission() async {
    if (!_initialized || kIsWeb || !isConfigured) {
      return CustomerPushPermission.unavailable;
    }
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final permission = _permissionFromAuthorization(
      settings.authorizationStatus,
    );
    if (permission == CustomerPushPermission.authorized ||
        permission == CustomerPushPermission.provisional) {
      await registerIfConsented();
    }
    return permission;
  }

  static Future<void> openSystemNotificationSettings() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _notificationSettingsChannel.invokeMethod<void>(
        'openNotificationSettings',
      );
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final opened = await launchUrl(
        Uri.parse('app-settings:'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('Could not open iOS notification settings');
    }
  }

  static Future<void> showFirstRunPermissionEducation() async {
    if (kIsWeb || !isConfigured || _permissionPromptOpen) return;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('push_permission_explainer_seen_v1') == true) {
      return;
    }
    final signedIn = supabase.auth.currentUser;
    if (signedIn != null) {
      try {
        final staff = await supabase
            .from('staff_profiles')
            .select('is_active')
            .eq('user_id', signedIn.id)
            .maybeSingle();
        if (staff?['is_active'] == true) return;
      } catch (_) {
        // Do not block the app if role lookup is temporarily unavailable.
      }
    }
    CustomerPushPermission current;
    try {
      current = await permissionStatus();
    } catch (error) {
      _log('permission-status-failed', error: error);
      return;
    }
    if (current == CustomerPushPermission.unavailable) return;
    if (current == CustomerPushPermission.authorized ||
        current == CustomerPushPermission.provisional) {
      await preferences.setBool('push_permission_explainer_seen_v1', true);
      await registerIfConsented();
      return;
    }
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    _permissionPromptOpen = true;
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    try {
      final ask = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.notifications_active_outlined),
          title: Text(arabic ? 'ابقَ على اطلاع' : 'Stay up to date'),
          content: Text(
            arabic
                ? 'يمكن للإشعارات إبلاغك بتأكيد الحجز وتحديث الخدمة وجاهزية السيارة. العروض التسويقية اختيارية ولن تُرسل دون موافقتك.'
                : 'Notifications can share booking confirmations, service updates and vehicle readiness. Marketing offers are optional and will not be sent without your consent.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(arabic ? 'لاحقًا' : 'Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                current == CustomerPushPermission.denied
                    ? (arabic ? 'فتح الإعدادات' : 'Open settings')
                    : (arabic ? 'متابعة' : 'Continue'),
              ),
            ),
          ],
        ),
      );
      await preferences.setBool('push_permission_explainer_seen_v1', true);
      if (ask == true) {
        if (current == CustomerPushPermission.denied) {
          await openSystemNotificationSettings();
        } else {
          await requestCustomerPermission();
        }
      }
    } finally {
      _permissionPromptOpen = false;
    }
  }

  static Future<void> registerIfConsented() async {
    if (!_initialized || kIsWeb) return;
    final session = supabase.auth.currentSession;
    final cachedUser = supabase.auth.currentUser;
    if (session == null || cachedUser == null) return;
    try {
      final verifiedUser = (await supabase.auth.getUser()).user;
      if (verifiedUser == null || verifiedUser.id != cachedUser.id) return;
      final user = verifiedUser;
      if (_registeredUserId != null && _registeredUserId != user.id) {
        // Never silently carry a device token across customer identities.
        // The supported account-switch path unregisters before sign-out.
        _log('account-switch-needs-unlink');
        return;
      }
      final staff = await supabase
          .from('staff_profiles')
          .select('user_id,is_active')
          .eq('user_id', user.id)
          .maybeSingle();
      // Customer tokens are never attached to a staff login. Staff push needs
      // its own explicit preference flow and must not inherit customer consent.
      if (staff?['is_active'] == true) return;
      const audience = 'customer';
      final profile = await supabase
          .from('customers')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();
      if (profile == null || profile['id'] != user.id) return;
      final systemPermission = await permissionStatus();
      final authorized =
          systemPermission == CustomerPushPermission.authorized ||
          systemPermission == CustomerPushPermission.provisional;
      if (!authorized) return;
      if (audience == 'customer') {
        var preference = await supabase
            .from('customer_marketing_preferences')
            .select('marketing_push_enabled,order_push_enabled')
            .eq('customer_id', user.id)
            .maybeSingle();
        if (shouldDefaultOperationalPush(
          hasSavedPreference: preference != null,
          systemPermissionGranted: authorized,
        )) {
          // OS permission is the opt-in for operational messages. Marketing
          // stays off until the customer explicitly enables it in Account.
          try {
            await supabase.from('customer_marketing_preferences').insert({
              'customer_id': user.id,
              'order_push_enabled': true,
            });
          } catch (_) {
            // A concurrent login/device may have created the row.
          }
          preference = await supabase
              .from('customer_marketing_preferences')
              .select('marketing_push_enabled,order_push_enabled')
              .eq('customer_id', user.id)
              .maybeSingle();
        }
        if (!shouldRegisterCustomerPushToken(
          hasValidSession: supabase.auth.currentUser?.id == user.id,
          hasMatchingCustomerProfile: profile['id'] == user.id,
          systemPermissionGranted: authorized,
          operationalConsent: preference?['order_push_enabled'] == true,
          marketingConsent: preference?['marketing_push_enabled'] == true,
        )) {
          return;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveRegisteredToken(token);
    } catch (error) {
      _log('registration-failed', error: error);
    }
  }

  static Future<void> _saveRegisteredToken(String token) async {
    final cachedUser = supabase.auth.currentUser;
    final session = supabase.auth.currentSession;
    if (cachedUser == null || session == null || token.isEmpty) return;
    try {
      final verifiedUser = (await supabase.auth.getUser()).user;
      if (verifiedUser == null ||
          verifiedUser.id != cachedUser.id ||
          supabase.auth.currentUser?.id != verifiedUser.id) {
        return;
      }
      final user = verifiedUser;
      final permission = await permissionStatus();
      if (permission != CustomerPushPermission.authorized &&
          permission != CustomerPushPermission.provisional) {
        return;
      }
      final staff = await supabase
          .from('staff_profiles')
          .select('user_id,is_active')
          .eq('user_id', user.id)
          .maybeSingle();
      if (staff?['is_active'] == true) return;
      const audience = 'customer';
      final profile = await supabase
          .from('customers')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();
      if (profile == null || profile['id'] != user.id) return;
      final preference = await supabase
          .from('customer_marketing_preferences')
          .select('marketing_push_enabled,order_push_enabled')
          .eq('customer_id', user.id)
          .maybeSingle();
      if (!shouldRegisterCustomerPushToken(
        hasValidSession:
            session.user.id == user.id &&
            supabase.auth.currentUser?.id == user.id,
        hasMatchingCustomerProfile: profile['id'] == user.id,
        systemPermissionGranted:
            permission == CustomerPushPermission.authorized ||
            permission == CustomerPushPermission.provisional,
        operationalConsent: preference?['order_push_enabled'] == true,
        marketingConsent: preference?['marketing_push_enabled'] == true,
      )) {
        return;
      }
      final platform = defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'android';
      final preferences = await SharedPreferences.getInstance();
      final appLocale = preferences.getString('app_language') == 'en'
          ? 'en'
          : 'ar';
      final now = DateTime.now().toUtc().toIso8601String();
      final previousToken = _registeredToken;
      if (previousToken != null && previousToken != token) {
        await supabase
            .from('push_device_tokens')
            .delete()
            .eq('user_id', user.id)
            .eq('device_token', previousToken);
      }
      await supabase.from('push_device_tokens').upsert({
        'user_id': user.id,
        'audience': audience,
        'device_token': token,
        'platform': platform,
        'locale': appLocale,
        'is_active': true,
        'last_seen_at': now,
        'updated_at': now,
      }, onConflict: 'user_id,audience,device_token');
      _registeredToken = token;
      _registeredUserId = user.id;
    } catch (_) {}
  }

  static Future<void> unregisterCurrentDevice() async {
    final user = supabase.auth.currentUser;
    if (!_initialized || user == null) return;
    try {
      final token = _registeredToken;
      final tokenToRemove =
          token ?? await FirebaseMessaging.instance.getToken();
      if (tokenToRemove != null) {
        await supabase
            .from('push_device_tokens')
            .delete()
            .eq('user_id', user.id)
            .eq('device_token', tokenToRemove);
      }
      _registeredToken = null;
      _registeredUserId = null;
    } catch (_) {}
  }

  static Future<void> signOut({
    SignOutScope scope = SignOutScope.global,
  }) async {
    // Delete this installation's token while the current user session still
    // has permission to remove its own row, then end the session.
    await unregisterCurrentDevice();
    await supabase.auth.signOut(scope: scope);
  }

  static Future<void> unregisterCustomerDevices() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    try {
      await supabase
          .from('push_device_tokens')
          .delete()
          .eq('user_id', user.id)
          .eq('audience', 'customer');
      _registeredToken = null;
      _registeredUserId = null;
    } catch (_) {}
  }

  static void flushPendingMessage() {
    final message = _pendingInitialMessage;
    if (message == null || appNavigatorKey.currentState == null) return;
    _pendingInitialMessage = null;
    _handleOpenedMessage(message);
  }

  static Future<void> openCustomerDeepLink(String destination) async {
    final routeName = safeCustomerNotificationRoute(destination);
    if (routeName == null) return;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;
    final Widget route = _customerPageForRoute(routeName);
    await navigator.push(MaterialPageRoute<void>(builder: (_) => route));
  }

  static void _showForegroundMessage(RemoteMessage message) {
    final context = appNavigatorKey.currentContext;
    if (context == null || message.notification == null) return;
    final id = message.messageId;
    if (id != null && !_shownForegroundMessageIds.add(id)) {
      _log('foreground-duplicate-suppressed', messageId: id);
      return;
    }
    if (_shownForegroundMessageIds.length > 256) {
      _shownForegroundMessageIds.clear();
      if (id != null) _shownForegroundMessageIds.add(id);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${message.notification?.title ?? ''} · ${message.notification?.body ?? ''}',
        ),
        action: SnackBarAction(
          label: tr(context, 'فتح', 'Open'),
          onPressed: () => _handleOpenedMessage(message),
        ),
      ),
    );
  }

  static Future<void> _handleOpenedMessage(RemoteMessage message) async {
    _log('open-handler', messageId: message.messageId);
    final data = message.data;
    final context = appNavigatorKey.currentContext;
    if (context == null) {
      _pendingInitialMessage = message;
      return;
    }
    if (data['type'] == 'marketing_campaign' && data['recipient_id'] != null) {
      try {
        await supabase.rpc(
          'record_marketing_open',
          params: {'p_recipient_id': data['recipient_id']},
        );
      } catch (_) {}
    }
    final destination = data['deep_link']?.toString() ?? '/offers';
    await openCustomerDeepLink(destination);
  }
}

class _SupabaseCustomerNotificationSettingsGateway
    implements CustomerNotificationSettingsGateway {
  final SupabaseClient client;

  const _SupabaseCustomerNotificationSettingsGateway(this.client);

  @override
  Future<CustomerPushPermission> permission() =>
      PushNotificationService.permissionStatus();

  @override
  Future<CustomerPushPermission> requestPermission() =>
      PushNotificationService.requestCustomerPermission();

  @override
  Future<void> openSystemSettings() =>
      PushNotificationService.openSystemNotificationSettings();

  @override
  Future<void> synchronizePermission(CustomerPushPermission permission) async {
    if (permission == CustomerPushPermission.denied ||
        permission == CustomerPushPermission.notDetermined) {
      await PushNotificationService.unregisterCurrentDevice();
    }
  }

  @override
  Future<CustomerNotificationPreferences> loadPreferences() async {
    final session = client.auth.currentSession;
    final cached = client.auth.currentUser;
    if (session == null || cached == null) {
      throw StateError('Customer session is required');
    }
    final user = (await client.auth.getUser()).user;
    if (user == null || user.id != cached.id) {
      throw StateError('Customer session is not valid');
    }
    final profile = await client
        .from('customers')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();
    if (profile == null || profile['id'] != user.id) {
      throw StateError('Customer profile is not linked');
    }
    final row = await client
        .from('customer_marketing_preferences')
        .select(
          'marketing_in_app_enabled,marketing_push_enabled,order_push_enabled',
        )
        .eq('customer_id', user.id)
        .maybeSingle();
    if (row == null) return const CustomerNotificationPreferences.defaults();
    return CustomerNotificationPreferences(
      operationalPush: row['order_push_enabled'] == true,
      marketingPush: row['marketing_push_enabled'] == true,
      marketingInApp: row['marketing_in_app_enabled'] == true,
    );
  }

  @override
  Future<void> savePreferences(
    CustomerNotificationPreferences preferences,
  ) async {
    final session = client.auth.currentSession;
    final cached = client.auth.currentUser;
    if (session == null || cached == null) {
      throw StateError('Customer session is required');
    }
    final user = (await client.auth.getUser()).user;
    if (user == null || user.id != cached.id) {
      throw StateError('Customer session is not valid');
    }
    final profile = await client
        .from('customers')
        .select('id')
        .eq('id', user.id)
        .maybeSingle();
    if (profile == null || profile['id'] != user.id) {
      throw StateError('Customer profile is not linked');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await client.from('customer_marketing_preferences').upsert({
      'customer_id': user.id,
      'marketing_in_app_enabled': preferences.marketingInApp,
      'marketing_push_enabled': preferences.marketingPush,
      'order_push_enabled': preferences.operationalPush,
      'consent_updated_at': preferences.marketingPush ? now : null,
      'updated_at': now,
    }, onConflict: 'customer_id');
    if (preferences.operationalPush || preferences.marketingPush) {
      await PushNotificationService.registerIfConsented();
    } else {
      await PushNotificationService.unregisterCustomerDevices();
    }
  }
}

Future<void> _pushInitialization = Future<void>.value();

Future<void> _initializePushForLaunch() async {
  try {
    await PushNotificationService.initialize();
  } catch (_) {
    // Keep first paint and the cinematic splash independent of FCM startup.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final configError = AppConfig.validate();
  if (configError != null) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(configError, textDirection: TextDirection.rtl),
            ),
          ),
        ),
      ),
    );
    return;
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
  );
  // Firebase is transport-only: initialize it alongside Flutter's first
  // frame instead of keeping the native static splash up while it starts.
  _pushInitialization = _initializePushForLaunch();

  InvoiceLinkCoordinator.initialize(supabase, appNavigatorKey);
  CustomerRoutes.navigate = navigateCustomer;
  CustomerRoutes.menu = customerMenuExtras;
  CustomerRoutes.toggleLanguage = _toggleSabihaLanguage;
  runApp(const SabihaHubApp());
}

class SabihaHubApp extends StatefulWidget {
  const SabihaHubApp({super.key});

  @override
  State<SabihaHubApp> createState() => _SabihaHubAppState();
}

class _SabihaHubAppState extends State<SabihaHubApp> {
  late final AppLanguageController _language = AppLanguageController();
  Locale get _locale => _language.locale;
  String get localeCode => _language.languageCode;
  late final Future<Widget>? _startup;
  late final Future<Widget> _webStartup;

  @override
  void initState() {
    super.initState();
    _activeSabihaLanguage = _language;
    _language.addListener(_onLanguageChanged);
    _startup = kIsWeb ? null : _loadStartup();
    _webStartup = _loadPublicStartup();
  }

  void _onLanguageChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _language.removeListener(_onLanguageChanged);
    if (identical(_activeSabihaLanguage, _language)) {
      _activeSabihaLanguage = null;
    }
    _language.dispose();
    super.dispose();
  }

  Future<Widget> _loadPublicStartup() async {
    // Authentication is not a web entry-point router: refresh always restores
    // the public site, while account pages require an explicit user action.
    await _loadLanguage();
    return HomeScreen(
      locale: _locale,
      onLanguageChanged: _changeSabihaLanguage,
    );
  }

  Future<Widget> _loadStartup() async {
    await _loadLanguage();
    final home = HomeScreen(
      locale: _locale,
      onLanguageChanged: _changeSabihaLanguage,
    );
    try {
      if (supabase.auth.currentSession == null) return home;
      final user = (await supabase.auth.getUser().timeout(
        const Duration(seconds: 8),
      )).user;
      if (user == null) return home;
      final staff = await supabase
          .from('staff_profiles')
          .select('role,permissions,full_name,is_active')
          .eq('user_id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (staff != null) {
        if (staff['is_active'] != true) return home;
        return StaffDashboardScreen(
          role: '${staff['role']}',
          permissions: Map<String, dynamic>.from(staff['permissions'] ?? {}),
          fullName: '${staff['full_name'] ?? ''}',
        );
      }
      // A persisted Supabase session is not a request to open a private screen.
      // Start customers at the public landing page on every cold launch; a
      // protected route verifies the server session and profile when requested.
      return home;
    } catch (_) {
      // Offline or expired verification returns to the public home; database
      // permissions remain authoritative on every subsequent operation.
      return home;
    }
  }

  void _startupReady() {
    PushNotificationService.flushPendingMessage();
    InvoiceLinkCoordinator.flushIfInitialized(appNavigatorKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showPushEducationAfterStartup());
    });
  }

  Future<void> _showPushEducationAfterStartup() async {
    await _pushInitialization;
    await PushNotificationService.showFirstRunPermissionEducation();
  }

  Future<void> _loadLanguage() async {
    await _language.load();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      title: 'Sabiha Hub',
      locale: _locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoNaskhArabic',
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF123B70),
          primary: const Color(0xFF123B70),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF071A36),
          foregroundColor: Colors.white,
          centerTitle: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFDCE2EA)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFDCE2EA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF2463A6), width: 1.5),
          ),
        ),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: _locale.languageCode == 'ar'
              ? TextDirection.rtl
              : TextDirection.ltr,
          child: QaEnvironmentFrame(
            enabled: kIsWeb && AppConfig.isQaStaging,
            locale: _locale,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      onGenerateRoute: kIsWeb ? _generateWebRoute : null,
      home: kIsWeb
          ? SabihaWebStartup(
              destination: _webStartup,
              fallbackHome: HomeScreen(
                locale: _locale,
                onLanguageChanged: _changeSabihaLanguage,
              ),
              onReady: _startupReady,
            )
          : SabihaSplashScreen(destination: _startup!, onReady: _startupReady),
    );
  }

  Route<dynamic> _generateWebRoute(RouteSettings settings) {
    final name = settings.name ?? '/';
    final args = settings.arguments is Map
        ? Map<String, dynamic>.from(settings.arguments! as Map)
        : const <String, dynamic>{};
    Widget publicHome() =>
        HomeScreen(locale: _locale, onLanguageChanged: _changeSabihaLanguage);
    final Widget page = switch (name) {
      '/' => publicHome(),
      '/services' => const PublicServicesScreen(),
      '/shop' => const CustomerShopScreen(),
      '/login' => CustomerLoginScreen(
        openBookingAfterLogin: args['openBooking'] == true,
        returnToPreviousAfterLogin: args['returnToPrevious'] == true,
        returnRouteAfterLogin: args['returnRoute']?.toString(),
        bookingServiceId: args['serviceId']?.toString(),
      ),
      '/register' => const RegisterScreen(),
      '/verify' => OtpVerificationScreen(
        email: args['email']?.toString() ?? '',
        customerName: args['customerName']?.toString() ?? '',
      ),
      '/forgot-password' => const ForgotPasswordScreen(),
      '/booking' => _customerPageForRoute(
        '/booking',
        serviceId: args['serviceId']?.toString(),
      ),
      '/orders' => _customerPageForRoute('/orders'),
      '/account' => _customerPageForRoute('/account'),
      '/vehicles' => _customerPageForRoute('/vehicles'),
      '/offers' => const CustomerOffersScreen(),
      '/reviews' => _customerPageForRoute('/reviews'),
      '/complaints' => _customerPageForRoute('/complaints'),
      '/inbox' => _customerPageForRoute('/inbox'),
      '/careers' => RecruitmentScreen(client: supabase),
      '/customer' => _customerPageForRoute('/customer'),
      '/staff-login' => const StaffLoginScreen(),
      '/staff-home' => const StaffStartupGuard(),
      _ => publicHome(),
    };
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }
}

/// A direct staff-dashboard URL is authenticated and role checked separately
/// from customer startup. Network failures remain a retryable state instead
/// of being misreported as a sign-in failure.
class StaffStartupGuard extends StatefulWidget {
  const StaffStartupGuard({super.key});

  @override
  State<StaffStartupGuard> createState() => _StaffStartupGuardState();
}

class _StaffStartupGuardState extends State<StaffStartupGuard> {
  late Future<Widget> _destination;

  @override
  void initState() {
    super.initState();
    _destination = _resolve();
  }

  Future<Widget> _resolve() async {
    final session = supabase.auth.currentSession;
    if (session == null) return const StaffLoginScreen();
    final user = (await supabase.auth.getUser().timeout(
      const Duration(seconds: 8),
    )).user;
    if (user == null) return const StaffLoginScreen();
    final profile = await supabase
        .from('staff_profiles')
        .select('role,permissions,full_name,is_active')
        .eq('user_id', user.id)
        .maybeSingle()
        .timeout(const Duration(seconds: 8));
    if (profile == null || profile['is_active'] != true) {
      return const StaffLoginScreen();
    }
    return StaffDashboardScreen(
      role: '${profile['role']}',
      permissions: Map<String, dynamic>.from(profile['permissions'] ?? {}),
      fullName: '${profile['full_name'] ?? ''}',
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    future: _destination,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(
          backgroundColor: navy,
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        );
      }
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(
            title: Text(tr(context, 'دخول الموظفين', 'Staff sign in')),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr(
                        context,
                        'تعذر التحقق من صلاحية الموظف بسبب الاتصال. لم يتم فتح لوحة الإدارة.',
                        'Staff access could not be verified because of a connection problem. The dashboard was not opened.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          setState(() => _destination = _resolve()),
                      icon: const Icon(Icons.refresh),
                      label: Text(tr(context, 'إعادة المحاولة', 'Retry')),
                    ),
                    TextButton(
                      onPressed: () => pushAppRoute(
                        context,
                        name: '/',
                        builder: (_) => HomeScreen(
                          locale: _sabihaCurrentLocale,
                          onLanguageChanged: _changeSabihaLanguage,
                        ),
                      ),
                      child: Text(tr(context, 'العودة للموقع', 'Back to site')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return snapshot.data ?? const StaffLoginScreen();
    },
  );
}

String tr(BuildContext context, String ar, String en) {
  return Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
}

String authFailureMessage({
  required String languageCode,
  required String message,
  String? statusCode,
}) {
  final normalized = message.toLowerCase();
  final invalidCredentials =
      normalized.contains('invalid login credentials') ||
      normalized.contains('invalid_credentials');
  if (invalidCredentials) {
    return languageCode == 'ar'
        ? 'البريد الإلكتروني أو كلمة المرور غير صحيحة.'
        : 'The email or password is incorrect.';
  }
  if (normalized.contains('customer profile was not found') ||
      normalized.contains('لم يتم العثور على ملف العميل')) {
    return languageCode == 'ar'
        ? 'لم يتم العثور على ملف العميل. تواصل مع الإدارة.'
        : 'Customer profile was not found. Please contact support.';
  }
  final networkFailure =
      const [
        'name resolution',
        'failed to fetch',
        'clientexception',
        'socketexception',
        'authretryablefetchexception',
        'networkerror',
        'xmlhttprequest',
        'connection timed out',
        'connection refused',
      ].any(normalized.contains) ||
      (statusCode == null && normalized.contains('dns'));
  if (networkFailure) {
    return languageCode == 'ar'
        ? 'تعذر الاتصال بخدمة تسجيل الدخول. تحقق من اتصال الإنترنت ثم أعد المحاولة؛ لم يتم التحقق من كلمة المرور.'
        : 'Could not reach the sign-in service. Check your internet connection and retry; the password was not checked.';
  }
  return languageCode == 'ar'
      ? 'تعذر تسجيل الدخول. حاول مرة أخرى.'
      : 'Sign-in failed. Please try again.';
}

String authEmailFailureMessage({
  required String languageCode,
  required String message,
  String? statusCode,
  String? code,
}) {
  final normalized = '${code ?? ''} $message'.toLowerCase();
  final arabic = languageCode == 'ar';
  if (code == 'over_email_send_rate_limit' ||
      normalized.contains('over_email_send_rate_limit')) {
    return arabic
        ? 'بلغ إرسال البريد الحد الحالي للمشروع. انتظر حتى يتجدد الحد قبل طلب رسالة أخرى؛ لم يتغير الحساب.'
        : 'This project has reached its email sending limit. Wait for it to reset before requesting another message; your account was not changed.';
  }
  if (code == 'over_request_rate_limit' ||
      normalized.contains('over_request_rate_limit')) {
    return arabic
        ? 'تم إرسال طلبات كثيرة لهذا البريد. انتظر دقيقة قبل إعادة المحاولة.'
        : 'Too many requests for this email. Wait one minute before trying again.';
  }
  if (code == 'email_address_not_authorized' ||
      normalized.contains('email_address_not_authorized')) {
    return arabic
        ? 'مزود البريد التجريبي لا يسمح بإرسال الرسائل لهذا العنوان. يحتاج المشروع إلى SMTP مخصص موثّق.'
        : 'The default test mailer cannot send to this address. The project needs an authenticated custom SMTP provider.';
  }
  if (code == 'otp_expired' ||
      code == 'invalid_otp' ||
      normalized.contains('token has expired') ||
      normalized.contains('invalid otp')) {
    return arabic
        ? 'رمز البريد غير صحيح أو انتهت صلاحيته. اطلب رمزًا جديدًا بعد انتهاء مهلة الإرسال.'
        : 'The email code is invalid or expired. Request a new code after the send cooldown.';
  }
  if (statusCode == '429') {
    return arabic
        ? 'تم إيقاف الإرسال مؤقتًا بسبب حد المعدل. انتظر قبل إعادة المحاولة.'
        : 'Sending is temporarily rate-limited. Wait before trying again.';
  }
  if (code == 'smtp_error' ||
      normalized.contains('smtp') ||
      (statusCode != null &&
          int.tryParse(statusCode) != null &&
          int.parse(statusCode) >= 500)) {
    return arabic
        ? 'تعذر على مزود البريد تسليم الرسالة. حاول لاحقًا؛ لم يتغير الحساب.'
        : 'The email provider could not deliver the message. Try again later; your account was not changed.';
  }
  return arabic
      ? 'تعذر إرسال رسالة البريد. تحقق من الاتصال وحاول لاحقًا.'
      : 'Could not send the email. Check the connection and try again later.';
}

const Color navy = Color(0xFF071A36);
const Color _publicRoyal = Color(0xFF174B83);

ThemeData _publicDesktopTheme(BuildContext context) =>
    Theme.of(context).copyWith(
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      colorScheme: const ColorScheme.light(
        primary: navy,
        secondary: _publicRoyal,
        surface: Colors.white,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: navy,
      ),
      textTheme: Theme.of(context).textTheme
          .apply(bodyColor: navy, displayColor: navy),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: navy,
        elevation: 0,
      ),
      iconTheme: const IconThemeData(color: navy),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFC5CBD5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF7F9FC),
        hintStyle: const TextStyle(color: Color(0xFF5C6F83)),
        labelStyle: const TextStyle(color: navy),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFC5CBD5)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFC5CBD5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _publicRoyal, width: 1.5),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: navy),
      ),
    );
const Color royalBlue = Color(0xFF174B83);
const Color silver = Color(0xFFC5CBD5);

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

Widget brandLogo({double size = 76, bool onDark = false}) {
  return SizedBox(
    width: size,
    height: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: onDark ? const Color(0xFFF5F7FB) : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: EdgeInsets.all(onDark ? 10 : 0),
        child: Image.asset(
          'assets/sabiha_brand_approved.png',
          fit: BoxFit.contain,
          semanticLabel: 'Sabiha Hub — A New Concept in Total Care',
        ),
      ),
    ),
  );
}

Widget _guardCustomerPage(String route, Widget child, {String? serviceId}) =>
    CustomerSessionGuard(
      gateway: SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ),
      child: child,
      loginBuilder: (_) => CustomerLoginScreen(
        returnRouteAfterLogin: route,
        bookingServiceId: serviceId,
      ),
      notCustomerBuilder: (_) => const CustomerAccessDeniedScreen(),
    );

Widget _customerPageForRoute(String route, {String? serviceId}) {
  final Widget page = switch (route) {
    '/booking' => CreateBookingScreen(initialServiceId: serviceId),
    '/orders' => const MyOrdersScreen(),
    '/account' => const CustomerAccountScreen(),
    '/vehicles' => const MyVehiclesScreen(),
    '/reviews' => EmployeeReviewsScreen(client: supabase),
    '/complaints' => ComplaintsScreen(client: supabase),
    '/inbox' => AppInboxScreen(
      client: supabase,
      marketingGateway: SupabaseCustomerMarketingInboxGateway(supabase),
      operationalGateway: SupabaseCustomerOperationalInboxGateway(supabase),
      onOpenMarketingLink: PushNotificationService.openCustomerDeepLink,
      onOpenOperationalLink: PushNotificationService.openCustomerDeepLink,
    ),
    '/customer' => CustomerDashboardScreen(
      customerName:
          supabase.auth.currentUser?.userMetadata?['full_name']?.toString() ??
          '',
    ),
    '/offers' => const CustomerOffersScreen(),
    '/shop' => const CustomerShopScreen(),
    _ => const CustomerDashboardScreen(customerName: ''),
  };
  if (route == '/offers' || route == '/shop') return page;
  return _guardCustomerPage(route, page, serviceId: serviceId);
}

class CustomerAccessDeniedScreen extends StatelessWidget {
  const CustomerAccessDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'صفحة خاصة بالعملاء', 'Customer-only page')),
    ),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, size: 48),
            const SizedBox(height: 14),
            Text(
              tr(
                context,
                'هذا الحساب غير مرتبط بملف عميل نشط. استخدم دخول الموظفين إذا كان حسابك إداريًا.',
                'This account is not linked to an active customer profile. Use staff sign-in for an employee account.',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => pushAppRoute(
                context,
                name: '/',
                replace: true,
                builder: (_) => HomeScreen(
                  locale: _sabihaCurrentLocale,
                  onLanguageChanged: _changeSabihaLanguage,
                ),
              ),
              child: Text(tr(context, 'العودة للرئيسية', 'Back to home')),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget languageButton(
  BuildContext context,
  Future<void> Function(String) onChanged,
) {
  final isArabic = Localizations.localeOf(context).languageCode == 'ar';

  return PopupMenuButton<String>(
    tooltip: tr(context, 'تغيير اللغة', 'Change language'),
    onSelected: onChanged,
    itemBuilder: (context) => [
      const PopupMenuItem(value: 'ar', child: Text('العربية')),
      const PopupMenuItem(value: 'en', child: Text('English')),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: silver.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.language, color: silver, size: 19),
          const SizedBox(width: 5),
          Text(
            isArabic ? 'عربي' : 'EN',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    ),
  );
}

// الشاشة الرئيسية
Widget _homeSupport() {
  try {
    return WhatsAppSupportButton(client: supabase);
  } catch (_) {
    return const SizedBox.shrink();
  }
}

class HomeScreen extends StatelessWidget {
  final Locale locale;
  final Future<void> Function(String) onLanguageChanged;

  const HomeScreen({
    super.key,
    required this.locale,
    required this.onLanguageChanged,
  });

  @override
  Widget build(BuildContext context) {
    void login({bool booking = false}) {
      final destination = booking ? '/booking' : '/account';
      pushAppRoute(
        context,
        name: '/login',
        arguments: {'openBooking': booking, 'returnRoute': destination},
        builder: (_) => CustomerLoginScreen(
          openBookingAfterLogin: booking,
          returnRouteAfterLogin: destination,
        ),
      );
    }

    return PublicLandingScreen(
      support: _homeSupport(),
      loadOffers: () async => Map<String, dynamic>.from(
        await supabase.rpc('get_public_promotions'),
      ),
      onLanguage: () {
        final next = _sabihaCurrentLocale.languageCode == 'ar' ? 'en' : 'ar';
        onLanguageChanged(next);
      },
      onAccount: () => login(),
      onBooking: () => login(booking: true),
      onServices: () => pushAppRoute(
        context,
        name: '/services',
        builder: (_) => const PublicServicesScreen(),
      ),
      onStaff: () => pushAppRoute(
        context,
        name: '/staff-login',
        builder: (_) => const StaffLoginScreen(),
      ),
      onCareers: () => pushAppRoute(
        context,
        name: '/careers',
        builder: (_) => RecruitmentScreen(client: supabase),
      ),
      onShop: () => pushAppRoute(
        context,
        name: '/shop',
        builder: (_) => const CustomerShopScreen(),
      ),
      onBookOffer: (offer) {
        if (offer['service_id'] == null) return;
        BranchSelection.current = offer['branch_id'];
        final serviceId = offer['service_id']?.toString();
        pushAppRoute(
          context,
          name: '/booking',
          arguments: {'openBooking': true, 'serviceId': serviceId},
          builder: (_) =>
              _customerPageForRoute('/booking', serviceId: serviceId),
        );
      },
    );
  }
}

// تسجيل دخول العميل
class CustomerLoginScreen extends StatefulWidget {
  final bool openBookingAfterLogin;
  final bool returnToPreviousAfterLogin;
  final String? returnRouteAfterLogin;
  final String? bookingServiceId;
  const CustomerLoginScreen({
    super.key,
    this.openBookingAfterLogin = false,
    this.returnToPreviousAfterLogin = false,
    this.returnRouteAfterLogin,
    this.bookingServiceId,
  });

  @override
  State<CustomerLoginScreen> createState() => _CustomerLoginScreenState();
}

class _CustomerLoginScreenState extends State<CustomerLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final loginFailedMessage = tr(context, 'تعذر تسجيل الدخول', 'Login failed');
    final customerProfileMissingMessage = tr(
      context,
      'لم يتم العثور على ملف العميل. تواصل مع الإدارة.',
      'Customer profile was not found. Please contact support.',
    );

    if (email.isEmpty || password.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'أدخل البريد الإلكتروني وكلمة المرور',
          'Enter email and password',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      final response = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = response.user;

      if (user == null) {
        throw Exception(loginFailedMessage);
      }

      final staffProfile = await supabase
          .from('staff_profiles')
          .select('user_id,is_active')
          .eq('user_id', user.id)
          .maybeSingle();
      if (staffProfile?['is_active'] == true) {
        await PushNotificationService.signOut(scope: SignOutScope.local);
        if (mounted) {
          showMessage(
            context,
            tr(
              context,
              'هذا حساب موظف. استخدم شاشة دخول الموظفين.',
              'This is a staff account. Use staff sign-in.',
            ),
          );
        }
        return;
      }

      final profile = await supabase
          .from('customers')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        await PushNotificationService.signOut();
        throw Exception(customerProfileMissingMessage);
      }

      if (!mounted) return;

      if (widget.returnToPreviousAfterLogin) {
        Navigator.pop(context);
        return;
      }

      if (widget.returnRouteAfterLogin != null) {
        final route = widget.returnRouteAfterLogin!;
        pushAppRoute(
          context,
          name: route,
          replace: true,
          builder: (_) =>
              _customerPageForRoute(route, serviceId: widget.bookingServiceId),
        );
        return;
      }

      pushAppRoute(
        context,
        name: '/customer',
        replace: true,
        arguments: {
          'openBooking': widget.openBookingAfterLogin,
          'serviceId': widget.bookingServiceId,
        },
        builder: (_) => _guardCustomerPage(
          '/customer',
          CustomerDashboardScreen(
            customerName: user.userMetadata?['full_name']?.toString() ?? '',
            openBookingOnArrival: widget.openBookingAfterLogin,
            bookingServiceId: widget.bookingServiceId,
          ),
        ),
      );
    } on AuthException catch (e) {
      if (mounted) {
        showMessage(
          context,
          authFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          authFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.toString(),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'دخول العميل', 'Customer Login'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  const SizedBox(height: 15),
                  brandLogo(),
                  const SizedBox(height: 15),
                  Text(
                    tr(
                      context,
                      'مرحباً بك في Sabiha Hub',
                      'Welcome to Sabiha Hub',
                    ),
                    style: const TextStyle(
                      color: navy,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textCapitalization: TextCapitalization.none,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'البريد الإلكتروني',
                        'Email address',
                      ),
                      prefixIcon: const Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: _hidePassword,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textCapitalization: TextCapitalization.none,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr(context, 'كلمة المرور', 'Password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() => _hidePassword = !_hidePassword);
                        },
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => pushAppRoute(
                        context,
                        name: '/forgot-password',
                        builder: (_) => const ForgotPasswordScreen(),
                      ),
                      child: Text(
                        tr(context, 'نسيت كلمة المرور؟', 'Forgot password?'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: navy,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _loading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(
                              tr(context, 'تسجيل الدخول', 'Sign in'),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(tr(context, 'ليس لديك حساب؟', 'New customer?')),
                      TextButton(
                        onPressed: () => pushAppRoute(
                          context,
                          name: '/register',
                          builder: (_) => const RegisterScreen(),
                        ),
                        child: Text(
                          tr(context, 'إنشاء حساب', 'Create account'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  if (canUseQaDevicePushTool(
                    debugMode: kDebugMode,
                    isWeb: kIsWeb,
                    appEnvironment: const String.fromEnvironment('APP_ENV'),
                    firebaseConfigured: PushNotificationService.isConfigured,
                  )) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => pushAppRoute(
                        context,
                        name: '/qa-device-push-test',
                        builder: (_) => const QaDevicePushTestScreen(),
                      ),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: Text(
                        tr(
                          context,
                          'أداة اختبار إشعارات جهاز QA',
                          'QA device push test tool',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// إنشاء حساب عميل
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _birthController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _birthController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;
    final birthDate = _birthController.text.trim();

    if (name.isEmpty ||
        phone.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'يرجى إدخال جميع البيانات المطلوبة',
          'Please complete all required fields',
        ),
      );
      return;
    }

    if (password.length < 8) {
      showMessage(
        context,
        tr(
          context,
          'كلمة المرور يجب ألا تقل عن 8 أحرف',
          'Password must be at least 8 characters',
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      showMessage(
        context,
        tr(context, 'كلمتا المرور غير متطابقتين', 'Passwords do not match'),
      );
      return;
    }

    final signupFailedMessage = tr(
      context,
      'تعذر إنشاء الحساب',
      'Could not create account',
    );

    setState(() => _loading = true);

    try {
      final response = await supabase.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': name, 'phone': phone, 'date_of_birth': birthDate},
      );

      if (response.user == null) {
        throw Exception(signupFailedMessage);
      }

      if (!mounted) return;

      pushAppRoute(
        context,
        name: response.session != null ? '/customer' : '/verify',
        replace: true,
        arguments: {'email': email, 'customerName': name},
        builder: (_) => response.session != null
            ? _customerPageForRoute('/customer')
            : OtpVerificationScreen(email: email, customerName: name),
      );
    } on AuthException catch (e) {
      if (mounted) {
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showMessage(context, e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseBirthDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime(2000),
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
    );

    if (selected != null) {
      _birthController.text =
          '${selected.year.toString().padLeft(4, '0')}-'
          '${selected.month.toString().padLeft(2, '0')}-'
          '${selected.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'إنشاء حساب جديد', 'Create Account')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  brandLogo(size: 65),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: tr(context, 'الاسم بالكامل', 'Full name'),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    decoration: InputDecoration(
                      labelText: tr(context, 'رقم الهاتف', 'Phone number'),
                      prefixIcon: const Icon(Icons.phone_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textCapitalization: TextCapitalization.none,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'البريد الإلكتروني',
                        'Email address',
                      ),
                      prefixIcon: const Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _birthController,
                    readOnly: true,
                    onTap: _chooseBirthDate,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'تاريخ الميلاد (اختياري)',
                        'Date of birth (optional)',
                      ),
                      prefixIcon: const Icon(Icons.calendar_month_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: _hidePassword,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textCapitalization: TextCapitalization.none,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr(context, 'كلمة المرور', 'Password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            _hidePassword = !_hidePassword;
                          });
                        },
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _confirmPasswordController,
                    obscureText: _hideConfirmPassword,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.left,
                    textCapitalization: TextCapitalization.none,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'تأكيد كلمة المرور',
                        'Confirm password',
                      ),
                      prefixIcon: const Icon(Icons.lock_reset_outlined),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            _hideConfirmPassword = !_hideConfirmPassword;
                          });
                        },
                        icon: Icon(
                          _hideConfirmPassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _register,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: navy,
                        foregroundColor: Colors.white,
                      ),
                      child: _loading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Text(
                              tr(
                                context,
                                'إنشاء الحساب وإرسال رمز التحقق',
                                'Create account and send code',
                              ),
                            ),
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

// التحقق من البريد الإلكتروني
class OtpVerificationScreen extends StatefulWidget {
  final String email;
  final String customerName;

  const OtpVerificationScreen({
    super.key,
    required this.email,
    required this.customerName,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final _codeController = TextEditingController();
  bool _loading = false;
  int _resendCooldownSeconds = 60;
  Timer? _resendCooldownTimer;

  @override
  void initState() {
    super.initState();
    _startResendCooldown(60);
  }

  void _startResendCooldown(int seconds) {
    _resendCooldownTimer?.cancel();
    _resendCooldownSeconds = seconds;
    _resendCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldownSeconds <= 0) {
        timer.cancel();
        return;
      }
      setState(() => _resendCooldownSeconds--);
    });
  }

  @override
  void dispose() {
    _resendCooldownTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();

    if (!isValidEmailOtp(code)) {
      showMessage(
        context,
        tr(
          context,
          'أدخل رمز التحقق الرقمي الذي وصلك بالبريد',
          'Enter the numeric verification code from your email',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.verifyOTP(
        email: widget.email,
        token: code,
        type: OtpType.signup,
      );

      if (!mounted) return;

      pushAppRoute(
        context,
        name: '/customer',
        clearStack: true,
        builder: (_) => _customerPageForRoute('/customer'),
      );
    } on AuthException catch (e) {
      if (mounted) {
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    if (_loading || _resendCooldownSeconds > 0) return;
    setState(() => _loading = true);
    try {
      await supabase.auth.resend(email: widget.email, type: OtpType.signup);

      if (mounted) {
        _startResendCooldown(60);
        showMessage(
          context,
          tr(
            context,
            'تم طلب إرسال رمز جديد إلى بريدك',
            'A new code has been requested',
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        if (e.code == 'over_email_send_rate_limit') {
          _startResendCooldown(const Duration(hours: 1).inSeconds);
        } else if (e.code == 'over_request_rate_limit') {
          _startResendCooldown(60);
        }
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'تأكيد البريد الإلكتروني', 'Verify Email')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 35),
            const Icon(
              Icons.mark_email_read_outlined,
              size: 75,
              color: royalBlue,
            ),
            const SizedBox(height: 20),
            Text(
              tr(
                context,
                'أرسلنا رمز التحقق إلى',
                'We sent a verification code to',
              ),
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 8),
            Text(
              widget.email,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: royalBlue,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: tr(context, 'رمز التحقق', 'Verification code'),
                counterText: '',
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _loading ? null : _verify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: navy,
                  foregroundColor: Colors.white,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(tr(context, 'تأكيد الحساب', 'Verify account')),
              ),
            ),
            TextButton(
              onPressed: _loading || _resendCooldownSeconds > 0
                  ? null
                  : _resend,
              child: Text(
                _resendCooldownSeconds > 0
                    ? tr(
                        context,
                        'إعادة الإرسال بعد ${(_resendCooldownSeconds / 60).ceil()} دقيقة',
                        'Resend in ${(_resendCooldownSeconds / 60).ceil()} min',
                      )
                    : tr(context, 'إعادة إرسال الرمز', 'Resend code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// استعادة كلمة المرور - ثلاث مراحل
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = 0;
  bool _loading = false;
  bool _hidePassword = true;
  bool _hideConfirmPassword = true;
  int _emailCooldownSeconds = 0;
  Timer? _emailCooldownTimer;

  void _startEmailCooldown(int seconds) {
    _emailCooldownTimer?.cancel();
    if (!mounted) return;
    setState(() => _emailCooldownSeconds = seconds);
    if (seconds <= 0) return;
    _emailCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _emailCooldownSeconds <= 1) {
        timer.cancel();
        if (mounted) setState(() => _emailCooldownSeconds = 0);
        return;
      }
      setState(() => _emailCooldownSeconds--);
    });
  }

  @override
  void dispose() {
    _emailCooldownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    final qaRecoveryPage = AppConfig.qaPasswordRecoveryPage;
    if (AppConfig.isQaStaging && qaRecoveryPage == null) {
      showMessage(
        context,
        tr(
          context,
          'استعادة كلمة مرور QA متوقفة حتى تجهيز صفحة HTTPS الآمنة. لم يتم إرسال طلب استعادة.',
          'QA password recovery is paused until its secure HTTPS page is configured. No reset request was sent.',
        ),
      );
      return;
    }
    if (qaRecoveryPage != null) {
      setState(() => _loading = true);
      try {
        final launched = await launchUrl(
          qaRecoveryPage,
          mode: LaunchMode.externalApplication,
        );
        if (mounted && !launched) {
          showMessage(
            context,
            tr(
              context,
              'تعذر فتح صفحة الاستعادة الآمنة. تحقق من اتصالك وحاول مرة أخرى.',
              'Could not open the secure recovery page. Check your connection and try again.',
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          showMessage(
            context,
            tr(
              context,
              'تعذر فتح صفحة الاستعادة الآمنة. تحقق من اتصالك وحاول مرة أخرى.',
              'Could not open the secure recovery page. Check your connection and try again.',
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    final email = _emailController.text.trim();

    if (email.isEmpty) {
      showMessage(
        context,
        tr(context, 'أدخل البريد الإلكتروني', 'Enter your email address'),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.resetPasswordForEmail(email);

      if (!mounted) return;

      _startEmailCooldown(60);
      setState(() => _step = 1);

      showMessage(
        context,
        tr(
          context,
          'إذا كان البريد مسجلاً، ستصلك رسالة تحتوي على رمز الاستعادة',
          'If the email is registered, you will receive a reset code',
        ),
      );
    } on AuthException catch (e) {
      if (mounted) {
        if (e.code == 'over_email_send_rate_limit') {
          _startEmailCooldown(const Duration(hours: 1).inSeconds);
        } else if (e.code == 'over_request_rate_limit') {
          _startEmailCooldown(60);
        }
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyResetCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();

    if (!isValidEmailOtp(code)) {
      showMessage(
        context,
        tr(
          context,
          'أدخل رمز التحقق الرقمي الذي وصلك بالبريد',
          'Enter the numeric verification code from your email',
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.recovery,
      );

      if (!mounted) return;

      setState(() => _step = 2);

      showMessage(
        context,
        tr(
          context,
          'تم التحقق من الرمز. أدخل كلمة المرور الجديدة',
          'Code verified. Enter your new password',
        ),
      );
    } on AuthException catch (e) {
      if (mounted) {
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updatePassword() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (password.length < 8) {
      showMessage(
        context,
        tr(
          context,
          'كلمة المرور يجب ألا تقل عن 8 أحرف',
          'Password must be at least 8 characters',
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      showMessage(
        context,
        tr(context, 'كلمتا المرور غير متطابقتين', 'Passwords do not match'),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      await supabase.auth.updateUser(UserAttributes(password: password));
      await PushNotificationService.signOut();

      if (!mounted) return;

      showMessage(
        context,
        tr(
          context,
          'تم تغيير كلمة المرور بنجاح',
          'Your password has been changed successfully',
        ),
      );

      Navigator.pop(context);
    } on AuthException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendResetCode() async {
    if (_loading || _emailCooldownSeconds > 0) return;
    if (AppConfig.isQaStaging && AppConfig.qaPasswordRecoveryPage == null) {
      showMessage(
        context,
        tr(
          context,
          'استعادة كلمة مرور QA متوقفة حتى تجهيز صفحة HTTPS الآمنة. لم يتم إرسال طلب استعادة.',
          'QA password recovery is paused until its secure HTTPS page is configured. No reset request was sent.',
        ),
      );
      return;
    }
    final email = _emailController.text.trim();

    setState(() => _loading = true);

    try {
      await supabase.auth.resetPasswordForEmail(email);

      if (mounted) {
        _startEmailCooldown(60);
        _codeController.clear();
        showMessage(
          context,
          tr(
            context,
            'تم طلب إرسال رمز استعادة جديد',
            'A new recovery code has been requested',
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        if (e.code == 'over_email_send_rate_limit') {
          _startEmailCooldown(const Duration(hours: 1).inSeconds);
        } else if (e.code == 'over_request_rate_limit') {
          _startEmailCooldown(60);
        }
        showMessage(
          context,
          authEmailFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
            code: e.code,
          ),
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildEmailStep() {
    if (AppConfig.isQaStaging && AppConfig.qaPasswordRecoveryPage == null) {
      return Text(
        tr(
          context,
          'استعادة كلمة مرور QA متوقفة مؤقتًا. ستُتاح بعد تجهيز صفحة HTTPS آمنة؛ لن نرسل رابطًا إلى localhost.',
          'QA password recovery is temporarily unavailable. It will be enabled after a secure HTTPS page is configured; no localhost link will be sent.',
        ),
        textAlign: TextAlign.center,
      );
    }
    if (AppConfig.qaPasswordRecoveryPage != null) {
      return Column(
        children: [
          Text(
            tr(
              context,
              'افتح صفحة الاستعادة الآمنة وأدخل بريد حساب QA هناك. الرابط يعمل على iPhone والماك.',
              'Open the secure recovery page and enter your QA account email there. The link works on iPhone and Mac.',
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          _actionButton(
            label: tr(
              context,
              'فتح صفحة الاستعادة الآمنة',
              'Open secure recovery page',
            ),
            onPressed: _sendResetCode,
          ),
        ],
      );
    }

    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل بريدك الإلكتروني لإرسال رمز استعادة كلمة المرور',
            'Enter your email to receive a password recovery code',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(context, 'البريد الإلكتروني', 'Email address'),
            prefixIcon: const Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'إرسال رمز التحقق', 'Send verification code'),
          onPressed: _sendResetCode,
        ),
      ],
    );
  }

  Widget _buildCodeStep() {
    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل رمز التحقق الذي أرسلناه إلى',
            'Enter the verification code sent to',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          _emailController.text.trim(),
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontWeight: FontWeight.bold, color: royalBlue),
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          maxLength: 8,
          decoration: InputDecoration(
            labelText: tr(context, 'رمز التحقق', 'Verification code'),
            counterText: '',
            prefixIcon: const Icon(Icons.password),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'التحقق من الرمز', 'Verify code'),
          onPressed: _verifyResetCode,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading || _emailCooldownSeconds > 0
              ? null
              : _resendResetCode,
          child: Text(
            _emailCooldownSeconds > 0
                ? tr(
                    context,
                    'إعادة الإرسال بعد ${(_emailCooldownSeconds / 60).ceil()} دقيقة',
                    'Resend in ${(_emailCooldownSeconds / 60).ceil()} min',
                  )
                : tr(context, 'إعادة إرسال الرمز', 'Resend code'),
          ),
        ),
        TextButton(
          onPressed: _loading
              ? null
              : () {
                  setState(() {
                    _step = 0;
                    _codeController.clear();
                  });
                },
          child: Text(
            tr(context, 'تغيير البريد الإلكتروني', 'Change email address'),
          ),
        ),
      ],
    );
  }

  Widget _buildNewPasswordStep() {
    return Column(
      children: [
        Text(
          tr(
            context,
            'أدخل كلمة المرور الجديدة لحسابك',
            'Enter a new password for your account',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 25),
        TextField(
          controller: _passwordController,
          obscureText: _hidePassword,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(context, 'كلمة المرور الجديدة', 'New password'),
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () {
                setState(() => _hidePassword = !_hidePassword);
              },
              icon: Icon(
                _hidePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmPasswordController,
          obscureText: _hideConfirmPassword,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(
              context,
              'تأكيد كلمة المرور الجديدة',
              'Confirm new password',
            ),
            prefixIcon: const Icon(Icons.lock_reset_outlined),
            suffixIcon: IconButton(
              onPressed: () {
                setState(() {
                  _hideConfirmPassword = !_hideConfirmPassword;
                });
              },
              icon: Icon(
                _hideConfirmPassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        _actionButton(
          label: tr(context, 'حفظ كلمة المرور الجديدة', 'Save new password'),
          onPressed: _updatePassword,
        ),
      ],
    );
  }

  Widget _actionButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'استعادة كلمة المرور', 'Reset Password')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 20),
              const Icon(Icons.lock_reset, size: 75, color: royalBlue),
              const SizedBox(height: 20),
              Text(
                tr(
                  context,
                  'استعادة حساب Sabiha Hub',
                  'Recover your Sabiha Hub account',
                ),
                style: const TextStyle(
                  color: navy,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  context,
                  'الخطوة ${_step + 1} من 3',
                  'Step ${_step + 1} of 3',
                ),
                style: const TextStyle(
                  color: royalBlue,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 25),
              if (_step == 0) _buildEmailStep(),
              if (_step == 1) _buildCodeStep(),
              if (_step == 2) _buildNewPasswordStep(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductAdPrices extends StatelessWidget {
  final Map<String, dynamic> ad;
  const _ProductAdPrices({required this.ad});

  @override
  Widget build(BuildContext context) {
    final original = (ad['original_price'] as num?)?.toDouble() ?? 0;
    final discounted = (ad['discounted_price'] as num?)?.toDouble();
    return Wrap(
      spacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (discounted != null && discounted < original)
          Text(
            '${original.toStringAsFixed(2)} ج.م',
            style: const TextStyle(
              decoration: TextDecoration.lineThrough,
              color: Colors.grey,
            ),
          ),
        Text(
          '${(discounted != null && discounted < original ? discounted : original).toStringAsFixed(2)} ج.م',
          style: const TextStyle(
            color: navy,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class ProductAdDetailScreen extends StatefulWidget {
  final Map<String, dynamic> ad;
  const ProductAdDetailScreen({super.key, required this.ad});

  @override
  State<ProductAdDetailScreen> createState() => _ProductAdDetailScreenState();
}

class _ProductAdDetailScreenState extends State<ProductAdDetailScreen> {
  final _noteController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  String _newRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _buy() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final response = await supabase.rpc(
        'place_customer_ad_product_order',
        params: {
          'p_ad_id': widget.ad['ad_id'],
          'p_request_id': _newRequestId(),
          'p_customer_note': _noteController.text.trim(),
        },
      );
      final result = response is List
          ? Map<String, dynamic>.from(response.first as Map)
          : Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      showMessage(
        context,
        tr(
          context,
          'تم استلام طلبك رقم ${result['order_number']}. الدفع عند الاستلام.',
          'Order ${result['order_number']} received. Pay on delivery.',
        ),
      );
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر شراء المنتج. تحقق من توفره ثم أعد المحاولة.',
            'Could not order this product. Check availability and try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.ad['image_url']?.toString() ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'تفاصيل المنتج', 'Product details')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (image.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.network(image, height: 240, fit: BoxFit.cover),
            ),
          const SizedBox(height: 18),
          Text(
            widget.ad['product_name']?.toString() ?? '',
            style: const TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.bold,
              color: navy,
            ),
          ),
          const SizedBox(height: 8),
          Text(widget.ad['description']?.toString() ?? ''),
          const SizedBox(height: 12),
          _ProductAdPrices(ad: widget.ad),
          const SizedBox(height: 24),
          TextField(
            controller: _noteController,
            maxLines: 3,
            maxLength: 1000,
            decoration: InputDecoration(
              labelText: tr(
                context,
                'عنوان التوصيل أو ملاحظات الطلب',
                'Delivery address or order notes',
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _buy,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.shopping_bag_outlined),
              label: Text(
                _saving
                    ? tr(context, 'جارٍ تأكيد الطلب...', 'Placing order...')
                    : tr(
                        context,
                        'اطلب الآن · الدفع عند الاستلام',
                        'Order now · Pay on delivery',
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// لوحة العميل
void navigateCustomer(BuildContext context, int index) {
  final routeName = switch (index) {
    0 => '/customer',
    1 => '/services',
    2 => '/orders',
    3 => '/shop',
    _ => '/account',
  };
  Widget publicHome() => HomeScreen(
    locale: _sabihaCurrentLocale,
    onLanguageChanged: _changeSabihaLanguage,
  );
  final Widget destination = switch (index) {
    0 => CustomerSessionGuard(
      gateway: SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ),
      child: CustomerDashboardScreen(
        customerName:
            supabase.auth.currentUser?.userMetadata?['full_name']?.toString() ??
            '',
      ),
      // A signed-out visit to the Home tab returns to the public site rather
      // than converting an expired cached session into a customer dashboard.
      loginBuilder: (_) => publicHome(),
      notCustomerBuilder: (_) => const CustomerAccessDeniedScreen(),
    ),
    1 => const PublicServicesScreen(),
    2 => _customerPageForRoute('/orders'),
    3 => const CustomerShopScreen(),
    _ => _customerPageForRoute('/account'),
  };
  pushAppRoute(
    context,
    name: routeName,
    replace: true,
    builder: (_) => destination,
  );
}

List<Widget> customerMenuExtras(BuildContext context) => [
  ListTile(
    key: const ValueKey('customer-careers-sidebar'),
    leading: const Icon(Icons.work_outline),
    title: Text(tr(context, 'الوظائف المتاحة', 'Careers')),
    onTap: () {
      Navigator.pop(context);
      pushAppRoute(
        context,
        name: '/careers',
        builder: (_) => RecruitmentScreen(client: supabase),
      );
    },
  ),
  ListTile(
    leading: const Icon(Icons.language),
    title: Text(tr(context, 'English / اللغة', 'العربية / Language')),
    onTap: () {
      Navigator.pop(context);
      _toggleSabihaLanguage();
    },
  ),
  ListTile(
    leading: const Icon(Icons.directions_car_outlined),
    title: Text(tr(context, 'سياراتي', 'My vehicles')),
    onTap: () {
      Navigator.pop(context);
      pushAppRoute(
        context,
        name: '/vehicles',
        builder: (_) => _customerPageForRoute('/vehicles'),
      );
    },
  ),

  ListTile(
    leading: const Icon(Icons.local_offer_outlined),
    title: Text(tr(context, 'العروض ونقاط الولاء', 'Offers & loyalty')),
    onTap: () {
      Navigator.pop(context);
      pushAppRoute(
        context,
        name: '/offers',
        builder: (_) => const CustomerOffersScreen(),
      );
    },
  ),
  ListTile(
    leading: const Icon(Icons.star_outline),
    title: Text(tr(context, 'التقييمات', 'Reviews')),
    onTap: () {
      Navigator.pop(context);
      pushAppRoute(
        context,
        name: '/reviews',
        builder: (_) => _customerPageForRoute('/reviews'),
      );
    },
  ),
  ListTile(
    leading: const Icon(Icons.support_agent),
    title: Text(tr(context, 'الشكاوى والدعم', 'Complaints & support')),
    onTap: () {
      Navigator.pop(context);
      pushAppRoute(
        context,
        name: '/complaints',
        builder: (_) => ComplaintsScreen(client: supabase),
      );
    },
  ),
];

class CustomerDashboardScreen extends StatefulWidget {
  final String customerName;

  final bool openBookingOnArrival;
  final String? bookingServiceId;
  const CustomerDashboardScreen({
    super.key,
    required this.customerName,
    this.openBookingOnArrival = false,
    this.bookingServiceId,
  });

  @override
  State<CustomerDashboardScreen> createState() =>
      _CustomerDashboardScreenState();
}

class _CustomerDashboardScreenState extends State<CustomerDashboardScreen> {
  @override
  void dispose() {
    _featuredRefresh?.dispose();
    super.dispose();
  }

  bool _productAdChecked = false;
  List<Map<String, dynamic>> _featured = [];
  bool _featuredFailed = false;
  CatalogRefresh? _featuredRefresh;
  Future<void> _loadFeatured() async {
    try {
      final data = Map<String, dynamic>.from(
        await supabase.rpc('get_public_home') as Map,
      );
      final branches = List<Map<String, dynamic>>.from(data['branches'] ?? []);
      final branch =
          BranchSelection.current ??
          (branches.isEmpty ? null : branches.first['branch_id']);
      final published =
          List<Map<String, dynamic>>.from(data['catalog'] ?? [])
              .where(
                (s) => s['item_type'] == 'service' && s['branch_id'] == branch,
              )
              .toList()
            ..sort(
              (a, b) =>
                  customerServiceOrder(a).compareTo(customerServiceOrder(b)),
            );
      try {
        await enrichCatalogImages(supabase, published.take(3).toList());
      } catch (_) {
        /* Approved asset fallback. */
      }
      if (mounted) {
        setState(() {
          _featured = published.take(3).toList();
          _featuredFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _featuredFailed = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadFeatured();
    _featuredRefresh = CatalogRefresh(
      refresh: _loadFeatured,
      allowed: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    );
    if (widget.openBookingOnArrival) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _customerPageForRoute(
                '/booking',
                serviceId: widget.bookingServiceId,
              ),
            ),
          );
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => InvoiceLinkCoordinator.markNavigationReady(appNavigatorKey),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkProductAd());
  }

  Future<void> _checkProductAd() async {
    if (_productAdChecked) return;
    _productAdChecked = true;
    try {
      final response = await supabase.rpc('claim_customer_product_ad');
      if (!mounted || response is! List || response.isEmpty) return;
      final ad = Map<String, dynamic>.from(response.first as Map);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          contentPadding: const EdgeInsets.all(18),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((ad['image_url']?.toString() ?? '').isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      ad['image_url'].toString(),
                      height: 170,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  ad['title']?.toString() ?? '',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  ad['product_name']?.toString() ?? '',
                  style: const TextStyle(
                    color: navy,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  ad['description']?.toString() ?? '',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                _ProductAdPrices(ad: ad),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await supabase.rpc(
                  'record_customer_product_ad_event',
                  params: {'p_ad_id': ad['ad_id'], 'p_event_type': 'dismiss'},
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              icon: const Icon(Icons.close),
              label: Text(tr(context, 'إغلاق الإعلان', 'Close ad')),
            ),
            FilledButton.icon(
              onPressed: () async {
                await supabase.rpc(
                  'record_customer_product_ad_event',
                  params: {'p_ad_id': ad['ad_id'], 'p_event_type': 'click'},
                );
                if (!dialogContext.mounted || !mounted) return;
                Navigator.pop(dialogContext);
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProductAdDetailScreen(ad: ad),
                  ),
                );
              },
              icon: const Icon(Icons.arrow_forward),
              label: Text(tr(context, 'اكتشف المنتج', 'Discover product')),
            ),
          ],
        ),
      );
    } catch (_) {
      // Product ads stay optional while their migration or preference is unavailable.
    }
  }

  Future<void> _logout(BuildContext context) async {
    await PushNotificationService.signOut();

    if (!context.mounted) return;

    pushAppRoute(
      context,
      name: '/',
      clearStack: true,
      builder: (_) => HomeScreen(
        locale: _sabihaCurrentLocale,
        onLanguageChanged: _changeSabihaLanguage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.customerName.isEmpty
        ? tr(context, 'عميلنا العزيز', 'Dear customer')
        : widget.customerName;
    return CustomerShell(
      showHomeTagline: true,
      title: tr(context, 'مرحبًا بك، $name', 'Welcome, $name'),
      subtitle: tr(
        context,
        'العناية المتكاملة لسيارتك',
        'Complete care for your car',
      ),
      selected: 0,
      onNavigate: (i) => navigateCustomer(context, i),
      onNotifications: () => openCustomerInbox(context),
      notificationAction: AppInboxButton(
        client: supabase,
        color: Colors.white,
        onOpen: () => openCustomerInbox(context),
      ),
      menuExtras: [
        ...customerMenuExtras(context),
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(tr(context, 'تسجيل الخروج', 'Sign out')),
          onTap: () => _logout(context),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        children: [
          LayoutBuilder(
            builder: (context, box) => Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final action in <(String, IconData, VoidCallback)>[
                  (
                    tr(context, 'حجز خدمة', 'Book a service'),
                    Icons.event_available_outlined,
                    () => pushAppRoute(
                      context,
                      name: '/booking',
                      builder: (_) => _customerPageForRoute('/booking'),
                    ),
                  ),
                  (
                    tr(context, 'خدماتنا وأسعارنا', 'Services & prices'),
                    Icons.directions_car_outlined,
                    () => navigateCustomer(context, 1),
                  ),
                  (
                    tr(context, 'عروضي ونقاطي', 'Offers & loyalty'),
                    Icons.local_offer_outlined,
                    () => pushAppRoute(
                      context,
                      name: '/offers',
                      builder: (_) => const CustomerOffersScreen(),
                    ),
                  ),
                  (
                    tr(context, 'متجر المنتجات', 'Shop products'),
                    Icons.shopping_bag_outlined,
                    () => navigateCustomer(context, 3),
                  ),
                ])
                  SizedBox(
                    width: (box.maxWidth - 12) / 2,
                    child: CustomerActionTile(
                      label: action.$1,
                      icon: action.$2,
                      onTap: action.$3,
                      gold: action.$2 == Icons.event_available_outlined,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          CustomerPanel(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.spaceAround,
              children: [
                IconButton(
                  tooltip: tr(context, 'سياراتي', 'My vehicles'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _customerPageForRoute('/vehicles'),
                    ),
                  ),
                  icon: const Icon(Icons.directions_car_outlined),
                ),
                IconButton(
                  tooltip: tr(context, 'التقييمات', 'Reviews'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _customerPageForRoute('/reviews'),
                    ),
                  ),
                  icon: const Icon(Icons.star_outline),
                ),
                IconButton(
                  tooltip: tr(context, 'فحص سيارتي', 'Vehicle inspections'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _guardCustomerPage(
                        '/customer',
                        InspectionHubScreen(client: supabase),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.car_crash_outlined),
                ),
                IconButton(
                  tooltip: tr(context, 'فواتيري', 'My invoices'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _guardCustomerPage(
                        '/customer',
                        InvoiceDocumentsScreen(client: supabase),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long_outlined),
                ),
              ],
            ),
          ),
          Text(
            tr(context, 'خدمات العناية بسيارتك', 'Car care services'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          if (_featuredFailed)
            TextButton(
              onPressed: _loadFeatured,
              child: Text(
                tr(context, 'إعادة تحميل الخدمات', 'Reload services'),
              ),
            ),
          for (final service in _featured)
            CustomerServiceTile(
              service: service,
              onBook: () {
                BranchSelection.current = service['branch_id'];
                pushAppRoute(
                  context,
                  name: '/booking',
                  arguments: {'serviceId': service['item_id']?.toString()},
                  builder: (_) => _customerPageForRoute(
                    '/booking',
                    serviceId: service['item_id']?.toString(),
                  ),
                );
              },
            ),
          WhatsAppSupportButton(client: supabase),
        ],
      ),
    );
  }
}

// شاشة حجز خدمة من قائمة الخدمات المشتركة
class CreateBookingScreen extends StatefulWidget {
  final String? initialServiceId;
  final Duration catalogRefreshInterval;
  const CreateBookingScreen({
    super.key,
    this.initialServiceId,
    this.catalogRefreshInterval = const Duration(seconds: 30),
  });

  @override
  State<CreateBookingScreen> createState() => _CreateBookingScreenState();
}

class _CreateBookingScreenState extends State<CreateBookingScreen> {
  late final _attempt = ServiceBookingAttempt.forClient(supabase);
  bool _rewardMode = false;
  Map<String, dynamic> get _normalPayload => {
    'p_service': _service?['item_id'],
    'p_branch': _branchId,
    'p_vehicle': _vehicle?['id'],
    'p_date': _dateValue(_date),
    'p_time': _timeValue(_time),
    'p_expected_price': servicePriceForVehicle(_service ?? const {}, _vehicle),
    'p_notes': _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim(),
  };
  bool _closedAttemptHandled = false;
  void _attemptChanged() {
    if (!mounted) return;
    if (_attempt.state == 'closed' && !_closedAttemptHandled) {
      _closedAttemptHandled = true;
      _rewardMode = false;
      _slotReviewed = false;
      _loadOptions();
    } else if (_attempt.state != 'closed') {
      _closedAttemptHandled = false;
    }
    setState(() {});
  }

  Widget _rewardPanel() => CustomerServiceRewardPanel(
    client: supabase,
    attempt: _attempt,
    normalPayload: _normalPayload,
    appointmentReviewed: _slotReviewed,
    onModeChanged: (value) {
      if (mounted) setState(() => _rewardMode = value);
    },
    onAcknowledged: () {
      if (mounted) Navigator.pop(context);
    },
  );
  List<Map<String, dynamic>> _services = [];
  List<Map<String, dynamic>> _branches = [];
  String? _branchId;
  List<Map<String, dynamic>> _vehicles = [];
  Map<String, dynamic>? _service;
  Map<String, dynamic>? _vehicle;
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  final _notesController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _slotReviewed = false;
  CatalogRefresh? _bookingCatalogRefresh;
  String? _catalogNotice;

  @override
  void initState() {
    super.initState();
    _attempt.addListener(_attemptChanged);
    _attempt.initialize();
    _loadOptions();
    _bookingCatalogRefresh = CatalogRefresh(
      interval: widget.catalogRefreshInterval,
      refresh: () => _loadOptions(preserveSelection: true),
      allowed: () =>
          mounted &&
          !_loading &&
          !_saving &&
          !_attempt.locked &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  @override
  void dispose() {
    _bookingCatalogRefresh?.dispose();
    _attempt.removeListener(_attemptChanged);
    _attempt.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadOptions({bool preserveSelection = false}) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('Please sign in again.');
      final branches = List<Map<String, dynamic>>.from(
        await supabase
            .from('business_branches')
            .select()
            .eq('is_active', true)
            .order('name_ar'),
      );
      if (!AppConfig.multiBranchEnabled) {
        _branchId = branches.firstWhere(
          (b) => b['is_default'] == true,
        )['branch_id'];
      } else {
        _branchId ??=
            BranchSelection.current ??
            branches.firstWhere(
              (b) => b['is_default'] == true,
              orElse: () => branches.first,
            )['branch_id'];
      }
      _branches = branches;
      final requestedBranch = _branchId;
      final results = await Future.wait<dynamic>([
        supabase
            .from('business_catalog_items')
            .select(
              'item_id, name, name_en, description, price, vehicle_type, duration_minutes',
            )
            .eq('branch_id', _branchId!)
            .eq('item_type', 'service')
            .eq('is_active', true)
            .eq('is_public', true)
            .order('name'),
        supabase
            .from('vehicles')
            .select('id, brand, model, year, plate_number, vehicle_class_code')
            .eq('customer_id', userId)
            .order('created_at'),
      ]);
      if (!mounted ||
          supabase.auth.currentUser?.id != userId ||
          _branchId != requestedBranch ||
          preserveSelection && (_saving || _attempt.locked)) {
        return;
      }
      try {
        await enrichCatalogImages(
          supabase,
          List<Map<String, dynamic>>.from(results[0] as List),
        );
      } catch (_) {
        /* Existing photo fallback. */
      }
      if (!mounted ||
          supabase.auth.currentUser?.id != userId ||
          _branchId != requestedBranch ||
          preserveSelection && (_saving || _attempt.locked)) {
        return;
      }
      final previousService = _service, previousVehicle = _vehicle;
      final vehicleRows = List<Map<String, dynamic>>.from(results[1] as List);
      final serviceRows = List<Map<String, dynamic>>.from(results[0] as List)
          .where(isCurrentService)
          .toList();
      final selectedVehicle = preserveSelection
          ? vehicleRows
                .where((v) => v['id'] == previousVehicle?['id'])
                .firstOrNull
          : (vehicleRows.isEmpty ? null : vehicleRows.first);
      if (selectedVehicle != null) {
        final pricing = Map<String, dynamic>.from(
          await supabase.rpc(
            'get_customer_service_price_options',
            params: {
              'p_branch': requestedBranch,
              'p_vehicle': selectedVehicle['id'],
            },
          ) as Map,
        );
        if (!mounted ||
            supabase.auth.currentUser?.id != userId ||
            _branchId != requestedBranch ||
            preserveSelection && (_saving || _attempt.locked)) {
          return;
        }
        final prices = <String, dynamic>{
          for (final item in List<Map<String, dynamic>>.from(
            pricing['services'] ?? const [],
          ))
            item['item_id'] as String: item['price'],
        };
        for (final service in serviceRows) {
          service['vehicle_prices'] = {
            '${pricing['vehicle_class_code'] ?? ''}':
                prices[service['item_id']],
          };
          service['price'] = prices[service['item_id']];
          service['vehicle_class_code'] = pricing['vehicle_class_code'];
          service['vehicle_class_name_ar'] = pricing['vehicle_class_name_ar'];
          service['vehicle_class_name_en'] = pricing['vehicle_class_name_en'];
        }
      }
      setState(() {
        _services = serviceRows;
        _vehicles = vehicleRows;
        if (preserveSelection) {
          _service = _services
              .where((s) => s['item_id'] == previousService?['item_id'])
              .firstOrNull;
          _vehicle = _vehicles
              .where((v) => v['id'] == previousVehicle?['id'])
              .firstOrNull;
          if (_service?['item_id'] != previousService?['item_id'] ||
              jsonEncode(_service?['vehicle_prices']) !=
                  jsonEncode(previousService?['vehicle_prices']) ||
              _service?['duration_minutes'] !=
                  previousService?['duration_minutes'] ||
              _vehicle?['id'] != previousVehicle?['id']) {
            _slotReviewed = false;
            _catalogNotice = tr(
              context,
              'تغير سعر الخدمة أو توفرها. راجع الخدمة والسيارة والموعد قبل التأكيد.',
              'Service price or availability changed. Review the service, vehicle and appointment before confirming.',
            );
          }
        } else {
          _service = _services.isEmpty
              ? null
              : _services.firstWhere(
                  (s) => s['item_id'] == widget.initialServiceId,
                  orElse: () => _services.first,
                );
          _vehicle = selectedVehicle;
          _catalogNotice = null;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          if (preserveSelection) {
            _slotReviewed = false;
            _catalogNotice = tr(
              context,
              'تعذر تحديث الخدمات. أعد التحقق من التوفر عند عودة الاتصال.',
              'Could not refresh services. Recheck availability when connected.',
            );
          }
        });
      }
      if (mounted && !preserveSelection) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحميل الخدمات والسيارات.',
            'Could not load services and vehicles.',
          ),
        );
      }
    }
  }

  String _dateValue(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _timeValue(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:00';

  Future<void> _chooseAvailableSlot() async {
    if (_service == null || _branchId == null) return;
    try {
      final rows = await supabase.rpc(
        'available_booking_slots',
        params: {
          'p_branch': _branchId,
          'p_service': _service!['item_id'],
          'p_date': _dateValue(_date),
        },
      );
      if (!mounted) return;
      final slots = List<Map<String, dynamic>>.from(rows as List);
      final selected = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: customerBlack,
        builder: (c) => Theme(
          data: customerTheme(c),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    tr(c, 'اختر موعدك', 'Choose your time'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${_dateValue(_date)} · ${tr(c, 'بتوقيت القاهرة', 'Cairo time')}',
                    style: const TextStyle(color: customerGold),
                  ),
                  const SizedBox(height: 20),
                  if (slots.isEmpty)
                    Text(
                      tr(
                        c,
                        'لا توجد مواعيد متاحة لهذا اليوم.',
                        'No available times on this date.',
                      ),
                      style: const TextStyle(color: customerIce),
                    ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final slot in slots)
                        OutlinedButton(
                          onPressed: () => Navigator.pop(c, slot['slot_time']),
                          child: Text(
                            slot['slot_time'].toString().substring(0, 5),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      if (selected != null && mounted) {
        final bits = selected.split(':');
        setState(() {
          _time = TimeOfDay(
            hour: int.parse(bits[0]),
            minute: int.parse(bits[1]),
          );
          _slotReviewed = true;
        });
      }
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحميل المواعيد.',
            'Could not load available times.',
          ),
        );
      }
    }
  }

  Future<void> _submit() async {
    final service = _service;
    final vehicle = _vehicle;
    final userId = supabase.auth.currentUser?.id;
    if (_saving ||
        _attempt.locked ||
        _rewardMode ||
        userId == null ||
        service == null ||
        vehicle == null ||
        servicePriceForVehicle(service, vehicle) == null) {
      return;
    }
    if (!_slotReviewed) {
      showMessage(
        context,
        tr(
          context,
          'اختر موعدًا من قائمة المواعيد المتاحة.',
          'Choose an available time first.',
        ),
      );
      return;
    }
    if (!isFutureBooking(_date, _time.hour, _time.minute, DateTime.now())) {
      showMessage(
        context,
        tr(context, 'اختر موعداً في المستقبل.', 'Choose a future appointment.'),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _attempt.submit('normal', _normalPayload);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_attempt.locked,
      child: CustomerAdaptiveFrame(
        title: tr(context, 'الخدمة والموعد', 'Service & appointment'),
        subtitle: tr(
          context,
          'اختر فرعك وسيارتك وموعدك المتاح',
          'Choose your branch, car and available time',
        ),
        selected: 1,
        appBar: AppBar(title: Text(tr(context, 'حجز خدمة', 'Book a service'))),
        body: _attempt.locked
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [_rewardPanel()],
              )
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : _services.isEmpty || _vehicles.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (AppConfig.multiBranchEnabled)
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _branchId,
                          decoration: const InputDecoration(
                            labelText: 'Branch / الفرع',
                          ),
                          items: _branches
                              .map(
                                (b) => DropdownMenuItem(
                                  value: b['branch_id'] as String,
                                  child: Text(
                                    branchName(b, context),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (id) {
                            setState(() {
                              _branchId = id;
                              _loading = true;
                              _slotReviewed = false;
                            });
                            _loadOptions();
                          },
                        ),
                      Text(
                        _services.isEmpty
                            ? tr(
                                context,
                                'لا توجد خدمات متاحة للحجز الآن.',
                                'No services are available to book right now.',
                              )
                            : tr(
                                context,
                                'أضف سيارة إلى حسابك قبل الحجز.',
                                'Add a vehicle to your account before booking.',
                              ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_catalogNotice != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _catalogNotice!,
                        style: const TextStyle(
                          color: royalBlue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (_service != null)
                    CustomerPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: CustomerCatalogPhoto(
                              item: _service!,
                              height: 130,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr(
                              context,
                              '${_service!['name']}',
                              '${_service!['name_en'] ?? _service!['name']}',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            servicePriceForVehicle(_service!, _vehicle) == null
                                ? tr(
                                    context,
                                    'السعر غير مضبوط لهذه الفئة',
                                    'Price unavailable for this class',
                                  )
                                : '${servicePriceForVehicle(_service!, _vehicle)} EGP',
                            style: const TextStyle(
                              color: customerGold,
                              fontSize: 23,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (AppConfig.multiBranchEnabled)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: ValueKey(_branchId),
                      initialValue: _branchId,
                      decoration: InputDecoration(
                        labelText: tr(context, 'الفرع', 'Branch'),
                      ),
                      items: _branches
                          .map(
                            (b) => DropdownMenuItem(
                              value: b['branch_id'] as String,
                              child: Text(
                                branchName(b, context),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _saving || _attempt.locked
                          ? null
                          : (id) {
                              setState(() {
                                _branchId = id;
                                BranchSelection.current = id;
                                _slotReviewed = false;
                                _loading = true;
                              });
                              _loadOptions();
                            },
                    ),
                  if (_branches.isNotEmpty)
                    Text(
                      _branches.firstWhere(
                            (b) => b['branch_id'] == _branchId,
                          )[Localizations.localeOf(context).languageCode == 'en'
                              ? 'address_en'
                              : 'address_ar'] ??
                          '',
                    ),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    isExpanded: true,
                    initialValue: _service,
                    decoration: InputDecoration(
                      labelText: tr(context, 'الخدمة', 'Service'),
                    ),
                    items: _services
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(
                              '${tr(context, '${item['name']}', '${item['name_en'] ?? item['name']}')} · ${servicePriceForVehicle(item, _vehicle) == null ? tr(context, 'السعر غير متاح لهذه الفئة', 'No price for this class') : '${servicePriceForVehicle(item, _vehicle)} ${tr(context, 'ج.م', 'EGP')}'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _attempt.locked
                        ? null
                        : (value) => setState(() {
                            _service = value;
                            _slotReviewed = false;
                          }),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    isExpanded: true,
                    initialValue: _vehicle,
                    decoration: InputDecoration(
                      labelText: tr(context, 'السيارة', 'Vehicle'),
                    ),
                    items: _vehicles
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(
                              '${item['brand']} ${item['model']} · ${item['plate_number']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _attempt.locked
                        ? null
                        : (value) {
                            setState(() {
                              _vehicle = value;
                              _loading = true;
                              _slotReviewed = false;
                            });
                            _loadOptions(preserveSelection: true);
                          },
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _attempt.locked
                        ? null
                        : () async {
                            final selected = await showCustomerDatePicker(
                              context: context,
                              initialDate: _date,
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(
                                const Duration(days: 180),
                              ),
                            );
                            if (selected != null && mounted) {
                              setState(() {
                                _date = selected;
                                _slotReviewed = false;
                              });
                            }
                          },
                    icon: const Icon(Icons.calendar_month),
                    label: Text(
                      '${tr(context, 'التاريخ', 'Date')}: ${_dateValue(_date)}',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _attempt.locked ? null : _chooseAvailableSlot,
                    icon: const Icon(Icons.schedule),
                    label: Text(
                      '${tr(context, 'الوقت', 'Time')}: ${_time.format(context)}',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    enabled: !_attempt.locked,
                    onChanged: (_) => setState(() {}),
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'ملاحظات إضافية',
                        'Additional notes',
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _rewardPanel(),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _saving || _attempt.locked || _rewardMode
                        ? null
                        : _submit,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(
                      _saving
                          ? tr(context, 'جارٍ الإرسال...', 'Sending...')
                          : tr(
                              context,
                              'إرسال طلب الحجز',
                              'Send booking request',
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class CustomerShopScreen extends StatefulWidget {
  const CustomerShopScreen({super.key});

  @override
  State<CustomerShopScreen> createState() => _CustomerShopScreenState();
}

class _CustomerShopScreenState extends State<CustomerShopScreen> {
  List<Map<String, dynamic>> _products = [];
  final Map<String, int> _cart = {};
  final _deliveryNoteController = TextEditingController();
  final _couponCodeController = TextEditingController();
  Map<String, dynamic>? _couponPreview;
  String? _couponError;
  bool _checkingCoupon = false;
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  String _requestId = _newRequestId();
  String _paymentPreference = 'cash_on_receipt';
  bool _terminalPaymentChoiceAvailable = false;
  String? _submittedPaymentPreference;

  @override
  void dispose() {
    _deliveryNoteController.dispose();
    _couponCodeController.dispose();
    super.dispose();
  }

  static String _newRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadPaymentOptions();
  }

  Future<void> _loadPaymentOptions() async {
    try {
      final data = await supabase.rpc('get_customer_payment_options');
      if (mounted &&
          data is Map &&
          data['card_terminal_intent_supported'] == true) {
        setState(() => _terminalPaymentChoiceAvailable = true);
      }
    } catch (_) {
      // Older local schemas retain their existing cash checkout until upgraded.
    }
  }

  Future<void> _load() async {
    try {
      // Anonymous users must read only the deliberately published projection.
      // Direct table SELECT is revoked for anon and correctly returns 401.
      final response = await supabase.rpc('get_public_home');
      final publicData = Map<String, dynamic>.from(response as Map);
      final rows = List<Map<String, dynamic>>.from(
        publicData['catalog'] as List? ?? const [],
      )..removeWhere((item) => item['item_type'] != 'product');
      rows.sort((a, b) => '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}'));
      if (mounted) {
        setState(() {
          _products = rows;
          _loading = false;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  double get _total {
    double total = 0;
    for (final product in _products) {
      final quantity = _cart[product['item_id'].toString()] ?? 0;
      total += ((product['price'] as num?)?.toDouble() ?? 0) * quantity;
    }
    return total;
  }

  double get _discount =>
      ((_couponPreview?['discount_amount'] as num?)?.toDouble() ?? 0);

  void _cartChanged(VoidCallback change) {
    setState(() {
      change();
      _couponPreview = null;
      _couponError = null;
    });
  }

  Future<bool> _requireCustomerSession() async {
    var access = await SupabaseCustomerSessionGateway(
      supabase,
      beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
    ).verify();
    if (!mounted) return false;
    if (access.status == CustomerSessionStatus.signedOut) {
      await pushAppRoute(
        context,
        name: '/login',
        arguments: const {'returnToPrevious': true},
        builder: (_) =>
            const CustomerLoginScreen(returnToPreviousAfterLogin: true),
      );
      if (!mounted) return false;
      access = await SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ).verify();
    }
    if (access.status == CustomerSessionStatus.authorized) return true;
    if (mounted) {
      showMessage(
        context,
        access.status == CustomerSessionStatus.unavailable
            ? tr(
                context,
                'تعذر التحقق من جلسة العميل. تحقق من الاتصال وأعد المحاولة.',
                'Could not verify the customer session. Check the connection and retry.',
              )
            : tr(
                context,
                'يلزم حساب عميل نشط لإتمام الطلب.',
                'An active customer account is required for checkout.',
              ),
      );
    }
    return false;
  }

  Future<void> _previewCoupon() async {
    if (!await _requireCustomerSession()) return;
    final code = _couponCodeController.text.trim().toUpperCase();
    if (code.isEmpty || _cart.isEmpty || _checkingCoupon) return;
    setState(() {
      _checkingCoupon = true;
      _couponError = null;
      _couponPreview = null;
    });
    try {
      final items = _cart.entries
          .map((entry) => {'item_id': entry.key, 'quantity': entry.value})
          .toList();
      final response = await supabase.rpc(
        'preview_customer_coupon',
        params: {'p_code': code, 'p_items': items},
      );
      final result = Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      setState(() {
        if (result['is_valid'] == true) {
          _couponPreview = result;
          _couponError = null;
        } else {
          _couponPreview = null;
          _couponError =
              result['reason']?.toString() ??
              tr(
                context,
                'الكوبون غير صالح لهذه السلة.',
                'This coupon cannot be used for this cart.',
              );
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _couponError = tr(
            context,
            'تعذر التحقق من الكوبون. أعد المحاولة.',
            'Could not validate the coupon. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingCoupon = false);
    }
  }

  Future<void> _checkout() async {
    if (!await _requireCustomerSession()) return;
    if (_cart.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final payload = _cart.entries
          .map((entry) => {'item_id': entry.key, 'quantity': entry.value})
          .toList();
      final response = await supabase.rpc(
        _terminalPaymentChoiceAvailable
            ? 'place_product_order_with_payment'
            : 'place_customer_product_order',
        params: {
          'p_items': payload,
          if (_terminalPaymentChoiceAvailable)
            'p_preference': _submittedPaymentPreference ??= _paymentPreference,
          'p_request_id': _requestId,
          'p_customer_note': _deliveryNoteController.text.trim(),
          'p_coupon_code': _couponPreview == null
              ? null
              : _couponCodeController.text.trim().toUpperCase(),
        },
      );
      final result = response is List
          ? Map<String, dynamic>.from(response.first as Map)
          : Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _couponPreview = null;
        _couponCodeController.clear();
        _requestId = _newRequestId();
        _submittedPaymentPreference = null;
      });
      showMessage(
        context,
        tr(
          context,
          _paymentPreference == 'card_terminal'
              ? 'تم استلام طلبك رقم ${result['order_number']} بإجمالي ${result['total']} ج.م. بانتظار الدفع بالبطاقة عند الكاشير.'
              : 'تم استلام طلبك رقم ${result['order_number']} بإجمالي ${result['total']} ج.م. الدفع عند الاستلام.',
          _paymentPreference == 'card_terminal'
              ? 'Order ${result['order_number']} received. Total ${result['total']} EGP. Awaiting card payment at cashier.'
              : 'Order ${result['order_number']} received. Total ${result['total']} EGP. Pay on delivery.',
        ),
      );
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر إتمام الطلب. تحقق من توفر المنتجات ثم أعد المحاولة.',
            'Could not place the order. Check product availability and try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = kIsWeb && MediaQuery.sizeOf(context).width >= 900;
    return Theme(
      data: desktop ? _publicDesktopTheme(context) : customerTheme(context),
      child: Scaffold(
        backgroundColor: desktop ? Colors.white : customerBlack,
        appBar: kIsWeb && MediaQuery.sizeOf(context).width >= 900
            ? _publicDesktopHeader(context)
            : AppBar(title: Text(tr(context, 'متجر المنتجات', 'Product shop'))),
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? 1280 : double.infinity,
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        desktop ? 28 : 150,
                      ),
                      children: [
                        if (desktop)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 14, 8, 16),
                            child: Text(
                              tr(context, 'متجر المنتجات', 'Product shop'),
                              style: const TextStyle(
                                color: navy,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        if (_loadFailed)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                tr(
                                  context,
                                  'تعذر تحميل المتجر. تحقق من الاتصال وأعد المحاولة.',
                                  'Could not load the shop. Check the connection and retry.',
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(color: desktop ? navy : null),
                              ),
                            ),
                          ),
                        if (_products.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              tr(
                                context,
                                'لا توجد منتجات منشورة حالياً.',
                                'There are no published products right now.',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: desktop ? navy : null),
                            ),
                          ),
                        if (_products.isNotEmpty)
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final columns = constraints.maxWidth >= 1000
                                  ? 3
                                  : constraints.maxWidth >= 650
                                  ? 2
                                  : 1;
                              const gap = 16.0;
                              final width =
                                  (constraints.maxWidth - gap * (columns - 1)) /
                                  columns;
                              return Wrap(
                                spacing: gap,
                                runSpacing: gap,
                                children: _products.map((product) {
                                  final id = product['item_id'].toString();
                                  final quantity = _cart[id] ?? 0;
                                  final english =
                                      Localizations.localeOf(context)
                                          .languageCode ==
                                      'en';
                                  final name =
                                      english &&
                                          '${product['name_en'] ?? ''}'
                                              .trim()
                                              .isNotEmpty
                                      ? '${product['name_en']}'
                                      : '${product['name'] ?? ''}';
                                  final description =
                                      english &&
                                          '${product['description_en'] ?? ''}'
                                              .trim()
                                              .isNotEmpty
                                      ? '${product['description_en']}'
                                      : '${product['description'] ?? ''}';
                                  return SizedBox(
                                    width: width,
                                    child: Card(
                                      child: ListTile(
                                        title: Text(
                                          name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        subtitle: Text(
                                          '$description\n${product['price']} ${tr(context, 'ج.م', 'EGP')}',
                                        ),
                                        isThreeLine: true,
                                        trailing: quantity == 0
                                            ? IconButton(
                                                icon: const Icon(
                                                  Icons.add_shopping_cart,
                                                ),
                                                tooltip: tr(
                                                  context,
                                                  'أضف للسلة',
                                                  'Add to cart',
                                                ),
                                                onPressed: () => _cartChanged(
                                                  () => _cart[id] = 1,
                                                ),
                                              )
                                            : Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  IconButton(
                                                    icon: const Icon(
                                                      Icons.remove,
                                                    ),
                                                    onPressed: () =>
                                                        _cartChanged(() {
                                                          if (quantity <= 1) {
                                                            _cart.remove(id);
                                                          } else {
                                                            _cart[id] =
                                                                quantity - 1;
                                                          }
                                                        }),
                                                  ),
                                                  Text('$quantity'),
                                                  IconButton(
                                                    icon: const Icon(Icons.add),
                                                    onPressed: () =>
                                                        _cartChanged(
                                                          () => _cart[id] =
                                                              quantity + 1,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _couponCodeController,
                                textCapitalization:
                                    TextCapitalization.characters,
                                onChanged: (_) {
                                  if (_couponPreview != null ||
                                      _couponError != null) {
                                    setState(() {
                                      _couponPreview = null;
                                      _couponError = null;
                                    });
                                  }
                                },
                                decoration: InputDecoration(
                                  labelText: tr(
                                    context,
                                    'كود الخصم',
                                    'Coupon code',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: _checkingCoupon || _cart.isEmpty
                                  ? null
                                  : _previewCoupon,
                              child: _checkingCoupon
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(tr(context, 'تحقق', 'Apply')),
                            ),
                          ],
                        ),
                        if (_couponError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _couponError!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        if (_couponPreview case final preview?) ...[
                          const SizedBox(height: 6),
                          Text(
                            '${preview['title']} · ${tr(context, 'الخصم', 'Discount')}: ${_discount.toStringAsFixed(2)} ج.م',
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if ((preview['eligible_items'] as List? ?? [])
                              .isNotEmpty)
                            Text(
                              '${tr(context, 'يشمل', 'Included')}: ${(preview['eligible_items'] as List).map((item) => (item as Map)['name']).join('، ')}',
                            ),
                          if ((preview['excluded_items'] as List? ?? [])
                              .isNotEmpty)
                            Text(
                              '${tr(context, 'مستثنى', 'Excluded')}: ${(preview['excluded_items'] as List).map((item) => (item as Map)['name']).join('، ')}',
                            ),
                        ],
                        TextField(
                          controller: _deliveryNoteController,
                          maxLines: 2,
                          maxLength: 1000,
                          decoration: InputDecoration(
                            labelText: tr(
                              context,
                              'عنوان التوصيل أو ملاحظات الطلب',
                              'Delivery address or order notes',
                            ),
                          ),
                        ),
                        if (kIsWeb)
                          Padding(
                            padding: const EdgeInsets.only(top: 22, bottom: 24),
                            child: Center(
                              child: TextButton.icon(
                                key: const ValueKey('public-staff-footer'),
                                onPressed: () => pushAppRoute(
                                  context,
                                  name: '/staff-login',
                                  builder: (_) => const StaffLoginScreen(),
                                ),
                                icon: const Icon(Icons.badge_outlined),
                                label: Text(
                                  tr(context, 'دخول الموظفين', 'Staff sign in'),
                                  style: TextStyle(
                                    color: desktop ? navy : customerIce,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: desktop ? navy : customerIce,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_discount > 0)
                  Text(
                    '${tr(context, 'الإجمالي قبل الخصم', 'Subtotal')}: ${_total.toStringAsFixed(2)} ج.م · ${tr(context, 'الخصم', 'Discount')}: -${_discount.toStringAsFixed(2)} ج.م',
                  ),
                Text(
                  '${tr(context, 'إجمالي السلة', 'Cart total')}: ${(_total - _discount).toStringAsFixed(2)} ج.م',
                ),
                if (_terminalPaymentChoiceAvailable)
                  DropdownButtonFormField<String>(
                    initialValue: _paymentPreference,
                    decoration: InputDecoration(
                      labelText: tr(context, 'طريقة الدفع', 'Payment method'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'cash_on_receipt',
                        child: Text(
                          tr(context, 'نقدًا عند الوصول', 'Cash on arrival'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'card_terminal',
                        child: Text(
                          tr(
                            context,
                            'بطاقة على ماكينة الكاشير',
                            'Card at cashier terminal',
                          ),
                        ),
                      ),
                    ],
                    onChanged: _saving || _submittedPaymentPreference != null
                        ? null
                        : (value) =>
                              setState(() => _paymentPreference = value!),
                  ),
                Text(
                  tr(
                    context,
                    'سيتم تفعيل خدمة الدفع الإلكتروني قريبًا',
                    'Online payment will be available soon',
                  ),
                ),
                if (_paymentPreference == 'card_terminal')
                  Text(
                    tr(
                      context,
                      'بانتظار الدفع بالبطاقة عند الكاشير؛ لا تُطلب بيانات بطاقتك هنا.',
                      'Awaiting card payment at cashier; no card details are requested here.',
                    ),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _cart.isEmpty || _saving ? null : _checkout,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      _saving
                          ? tr(
                              context,
                              'جارٍ إرسال الطلب...',
                              'Placing order...',
                            )
                          : tr(
                              context,
                              _paymentPreference == 'card_terminal'
                                  ? 'تأكيد الطلب · الدفع بالبطاقة عند الكاشير'
                                  : 'تأكيد الطلب · الدفع عند الاستلام',
                              _paymentPreference == 'card_terminal'
                                  ? 'Place order · Card at cashier'
                                  : 'Place order · Pay on delivery',
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CustomerOffersScreen extends StatefulWidget {
  const CustomerOffersScreen({super.key});

  @override
  State<CustomerOffersScreen> createState() => _CustomerOffersScreenState();
}

class _CustomerOffersScreenState extends State<CustomerOffersScreen> {
  List<Map<String, dynamic>> offers = [], coupons = [];
  Map<String, dynamic>? serviceVisits;
  int? points;
  bool loading = true, failed = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        failed = false;
      });
    }
    try {
      final result = Map<String, dynamic>.from(
        await supabase.rpc('get_public_promotions'),
      );
      final user = supabase.auth.currentUser;
      List<Map<String, dynamic>> nextCoupons = [];
      Map<String, dynamic>? nextVisits;
      int? nextPoints;
      if (user != null) {
        try {
          nextVisits = Map<String, dynamic>.from(
            await supabase.rpc('get_my_canonical_service_visits') as Map,
          );
        } catch (_) {
          // A missing/unavailable visit ledger must never become a zero balance.
          nextVisits = null;
        }
        final rows = List<Map<String, dynamic>>.from(
          await supabase
              .from('business_loyalty_balances')
              .select('points_balance')
              .eq('customer_id', user.id),
        );
        nextPoints = rows.isEmpty
            ? 0
            : (rows.first['points_balance'] as num).toInt();
        nextCoupons = List<Map<String, dynamic>>.from(
          await supabase.rpc('get_public_customer_coupons'),
        );
      }
      if (mounted) {
        setState(() {
          offers = List<Map<String, dynamic>>.from(result['offers']);
          coupons = nextCoupons;
          points = nextPoints;
          serviceVisits = nextVisits;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          failed = true;
          points = null;
        });
      }
    }
  }

  void book(Map<String, dynamic> offer) {
    if (offer['service_id'] == null) return;
    BranchSelection.current = offer['branch_id'];
    final serviceId = offer['service_id']?.toString();
    pushAppRoute(
      context,
      name: '/booking',
      arguments: {'serviceId': serviceId},
      builder: (_) => _customerPageForRoute('/booking', serviceId: serviceId),
    );
  }

  Widget _publicOffersView(BuildContext context) => OffersCatalogPage(
    offers: offers,
    coupons: coupons,
    points: points,
    loading: loading,
    failed: failed,
    onRetry: load,
    onBookOffer: book,
    onHome: () => pushAppRoute(
      context,
      name: '/',
      replace: true,
      builder: (_) => HomeScreen(
        locale: _sabihaCurrentLocale,
        onLanguageChanged: _changeSabihaLanguage,
      ),
    ),
    onServices: () => pushAppRoute(
      context,
      name: '/services',
      builder: (_) => const PublicServicesScreen(),
    ),
    onShop: () => pushAppRoute(
      context,
      name: '/shop',
      builder: (_) => const CustomerShopScreen(),
    ),
    onBooking: () => pushAppRoute(
      context,
      name: '/booking',
      builder: (_) => _customerPageForRoute('/booking'),
    ),
    onAccount: () => pushAppRoute(
      context,
      name: '/account',
      builder: (_) => _customerPageForRoute('/account'),
    ),
    onLanguage: _toggleSabihaLanguage,
  );

  @override
  Widget build(BuildContext context) {
    if (supabase.auth.currentUser == null) return _publicOffersView(context);
    return CustomerSessionGuard(
      gateway: SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ),
      child: _internalOffersView(context),
      loginBuilder: (_) => _publicOffersView(context),
      notCustomerBuilder: (_) => _publicOffersView(context),
    );
  }

  Widget _internalOffersView(BuildContext context) => failed
      ? CustomerAdaptiveFrame(
          title: tr(context, 'العروض ونقاط الولاء', 'Offers & loyalty'),
          body: Center(
            child: TextButton(
              onPressed: load,
              child: Text(
                tr(
                  context,
                  'تعذر التحميل — إعادة المحاولة',
                  'Unable to load — retry',
                ),
              ),
            ),
          ),
        )
      : CustomerAdaptiveFrame(
          title: tr(context, 'العروض ونقاط الولاء', 'Offers & loyalty'),
          subtitle: tr(
            context,
            'عروض منشورة ومكافآت حسابك',
            'Published offers and your account rewards',
          ),
          selected: 4,
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    children: [
                      if (supabase.auth.currentUser != null)
                        MixedPointsEarningsPanel(
                          key: ValueKey(
                            'offers-points-${supabase.auth.currentUser!.id}',
                          ),
                          client: supabase,
                        ),
                      CustomerPanel(
                        child: Row(
                          children: [
                            const Icon(
                              Icons.stars_rounded,
                              color: customerGold,
                              size: 64,
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr(
                                      context,
                                      'رصيد نقاط الولاء',
                                      'Loyalty points',
                                    ),
                                    style: const TextStyle(color: customerIce),
                                  ),
                                  Text(
                                    '$points',
                                    style: const TextStyle(
                                      color: customerGold,
                                      fontSize: 40,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    tr(
                                      context,
                                      'رصيد حسابك من النظام',
                                      'Your balance from the shared system',
                                    ),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      CanonicalServiceVisitsCard(summary: serviceVisits),
                      CustomerRewardWallet(client: supabase),
                      if (coupons.isNotEmpty)
                        Text(
                          tr(context, 'كوبوناتك المتاحة', 'Available coupons'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      for (final coupon in coupons)
                        CustomerPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${coupon['title']}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                coupon['discount_type'] == 'percentage'
                                    ? '${coupon['discount_value']}%'
                                    : '${coupon['discount_value']} EGP',
                                style: const TextStyle(
                                  color: customerGold,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                '${tr(context, 'الحد الأدنى', 'Minimum')}: ${coupon['minimum_subtotal']} EGP${coupon['max_discount'] == null ? '' : ' · ${tr(context, 'حد الخصم', 'Discount cap')}: ${coupon['max_discount']} EGP'}${coupon['first_purchase_only'] == true ? ' · ${tr(context, 'لأول شراء فقط', 'First purchase only')}' : ''}',
                                style: const TextStyle(color: customerIce),
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.copy),
                                label: Text('${coupon['code']}'),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: '${coupon['code']}'),
                                  );
                                  if (context.mounted) {
                                    showMessage(
                                      context,
                                      tr(
                                        context,
                                        'تم نسخ الكوبون',
                                        'Coupon copied',
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      if (offers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            tr(
                              context,
                              'لا توجد عروض متاحة حاليًا.',
                              'No active offers right now.',
                            ),
                            style: const TextStyle(color: customerIce),
                          ),
                        ),
                      for (final offer in offers)
                        CustomerPanel(
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(20),
                                ),
                                child: Image.asset(
                                  customerServicePhoto('${offer['name']}'),
                                  height: 140,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '${offer['name'] ?? ''}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${offer['description'] ?? ''}',
                                      style: const TextStyle(
                                        color: customerIce,
                                      ),
                                    ),
                                    if (offer['visits_required'] != null)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        child: Text(
                                          '${tr(context, 'الزيارات المطلوبة', 'Required visits')}: ${offer['visits_required']}',
                                          style: const TextStyle(
                                            color: customerGold,
                                          ),
                                        ),
                                      ),
                                    GoldButton(
                                      label: tr(
                                        context,
                                        'تصفح الخدمات',
                                        'Explore services',
                                      ),
                                      icon: Icons.arrow_forward,
                                      onPressed: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const PublicServicesScreen(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        );
}

class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key});

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _storeOrders = [];
  List<Map<String, dynamic>> _storeItems = [];
  bool _loading = true;
  String _query = '';
  String _view = 'all';
  String _section = 'bookings';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('Sign in required');
      final bookings = List<Map<String, dynamic>>.from(
        await supabase.rpc('get_customer_booking_history'),
      );
      final orders = await supabase
          .from('business_orders')
          .select(
            'order_id, order_number, service_name, status, order_type, created_at, coupon_code, coupon_discount',
          )
          .eq('customer_id', userId)
          .order('created_at', ascending: false);
      final orderIds = List<Map<String, dynamic>>.from(orders)
          .map((row) => row['order_id'] as String)
          .toList();
      final allOrders = List<Map<String, dynamic>>.from(orders);
      final storeOrders = allOrders
          .where((row) => row['order_type'] == 'product')
          .toList();
      final storeOrderIds = storeOrders
          .map((row) => row['order_id'] as String)
          .toList();
      final storeItems = storeOrderIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await supabase
                  .from('business_order_items')
                  .select('order_id, item_name, quantity, unit_price, subtotal')
                  .inFilter('order_id', storeOrderIds),
            );
      final invoices = orderIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await supabase
                  .from('business_invoices')
                  .select(
                    'invoice_id, invoice_number:display_number, order_id, service_name, total, status, issued_at',
                  )
                  .inFilter('order_id', orderIds)
                  .order('issued_at', ascending: false),
            );
      if (!mounted) return;
      setState(() {
        _bookings = List<Map<String, dynamic>>.from(bookings);
        _invoices = invoices;
        _storeOrders = storeOrders;
        _storeItems = storeItems;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحميل الطلبات والفواتير.',
            'Could not load orders and invoices.',
          ),
        );
      }
    }
  }

  void _details(Map<String, dynamic> booking) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: customerNavy,
      builder: (context) => Theme(
        data: customerTheme(context),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${booking['service_name']}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  '${tr(context, 'رقم الحجز', 'Booking number')}: ${bookingReference(booking)}',
                  style: const TextStyle(color: customerIce),
                ),
                const SizedBox(height: 12),
                Text(
                  bookingAppointmentLabel(context, booking),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  bookingPaymentLabel(
                    booking['payment_status'],
                    Localizations.localeOf(context).languageCode == 'ar',
                  ),
                  style: const TextStyle(color: customerIce),
                ),
                if (booking['invoice_token'] != null) ...[
                  const SizedBox(height: 16),
                  GoldButton(
                    label: tr(context, 'عرض الفاتورة', 'View invoice'),
                    icon: Icons.receipt_long,
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(
                        this.context,
                        MaterialPageRoute(
                          builder: (_) => _guardCustomerPage(
                            '/orders',
                            InvoiceDocumentsScreen(
                              client: supabase,
                              initialToken: booking['invoice_token'],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      context,
                      'لا توجد فاتورة مرتبطة بهذا الحجز بعد.',
                      'No invoice is linked to this booking yet.',
                    ),
                    style: const TextStyle(color: customerIce),
                  ),
                ],
                CustomerBookingChanges(
                  booking: booking,
                  arabic: Localizations.localeOf(context).languageCode == 'ar',
                  onChanged: () {
                    Navigator.pop(context);
                    _load();
                  },
                ),
                const SizedBox(height: 16),
                GoldButton(
                  label: tr(
                    context,
                    'صور وفحص سيارتي',
                    'Vehicle inspection & photos',
                  ),
                  icon: Icons.car_crash_outlined,
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      this.context,
                      MaterialPageRoute(
                        builder: (_) => _guardCustomerPage(
                          '/orders',
                          InspectionHubScreen(
                            client: supabase,
                            bookingId: booking['id'],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                WhatsAppSupportButton(
                  client: supabase,
                  reference: 'حجز ${booking['id']}',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final visible = filterCustomerBookings(_bookings, _query, _view);
    return CustomerShell(
      title: tr(context, 'طلباتي ومواعيدي', 'Orders & appointments'),
      subtitle: tr(
        context,
        'تابع جميع حجوزاتك وخدماتك السابقة والحالية',
        'Your current and previous car care visits',
      ),
      icon: Icons.event_available_outlined,
      selected: 2,
      onNavigate: (i) => navigateCustomer(context, i),
      onNotifications: () => openCustomerInbox(context),
      notificationAction: AppInboxButton(
        client: supabase,
        color: Colors.white,
        onOpen: () => openCustomerInbox(context),
      ),
      menuExtras: customerMenuExtras(context),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 7,
                    children: [
                      for (final tab in [
                        ('bookings', 'الحجوزات', 'Bookings'),
                        ('shop', 'طلبات المتجر', 'Shop orders'),
                        ('invoices', 'الفواتير', 'Invoices'),
                      ])
                        ChoiceChip(
                          label: Text(tr(context, tab.$2, tab.$3)),
                          selected: _section == tab.$1,
                          onSelected: (_) => setState(() => _section = tab.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_failed)
                    TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        tr(
                          context,
                          'تعذر تحميل البيانات — إعادة المحاولة',
                          'Could not load data — Retry',
                        ),
                      ),
                    ),
                  if (_section == 'bookings') ...[
                    TextField(
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Colors.white,
                        ),
                        hintText: tr(
                          context,
                          'ابحث برقم الحجز أو الخدمة أو السيارة',
                          'Search booking number, service or vehicle',
                        ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        for (final view in [
                          ('all', 'الكل', 'All'),
                          ('current', 'الحالية', 'Current'),
                          ('past', 'السابقة', 'Past'),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: ChoiceChip(
                                showCheckmark: false,
                                label: Text(
                                  '${tr(context, view.$2, view.$3)} (${filterCustomerBookings(_bookings, '', view.$1).length})',
                                  style: TextStyle(
                                    color: _view == view.$1
                                        ? customerBlack
                                        : Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                selected: _view == view.$1,
                                onSelected: (_) =>
                                    setState(() => _view = view.$1),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (!_failed && visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr(
                            context,
                            'لا توجد حجوزات مطابقة.',
                            'No matching bookings.',
                          ),
                          style: const TextStyle(color: customerIce),
                        ),
                      ),
                    for (final booking in visible)
                      CustomerBookingCard(
                        key: ValueKey('booking-${booking['id']}'),
                        booking: booking,
                        arabic: ar,
                        onDetails: () => _details(booking),
                        onInspection: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _guardCustomerPage(
                              '/orders',
                              InspectionHubScreen(
                                client: supabase,
                                bookingId: booking['id'],
                              ),
                            ),
                          ),
                        ),
                        support: WhatsAppSupportButton(
                          client: supabase,
                          reference: 'حجز ${booking['id']}',
                        ),
                      ),
                  ],
                  if (_section == 'shop') ...[
                    GoldButton(
                      label: tr(
                        context,
                        'تتبع التوصيل والاستلام',
                        'Track delivery & pickup',
                      ),
                      icon: Icons.local_shipping_outlined,
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _guardCustomerPage(
                            '/orders',
                            FulfillmentOrdersScreen(client: supabase),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!_failed && _storeOrders.isEmpty)
                      Text(
                        tr(
                          context,
                          'لا توجد طلبات متجر بعد.',
                          'No shop orders yet.',
                        ),
                      ),
                    for (final order in _storeOrders)
                      CustomerPanel(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.shopping_bag_outlined,
                            color: customerGold,
                          ),
                          title: Text(
                            '${order['order_number']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${order['status']} · ${order['created_at']}',
                            style: const TextStyle(color: customerIce),
                          ),
                          onTap: () => showDialog(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text('${order['order_number']}'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final item in _storeItems.where(
                                    (i) => i['order_id'] == order['order_id'],
                                  ))
                                    Text(
                                      '${item['item_name']} × ${item['quantity']} · ${item['subtotal']} EGP',
                                    ),
                                  WhatsAppSupportButton(
                                    client: supabase,
                                    reference: 'طلب ${order['order_number']}',
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c),
                                  child: Text(tr(c, 'إغلاق', 'Close')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                  if (_section == 'invoices') ...[
                    GoldButton(
                      label: tr(
                        context,
                        'فتح الفواتير الآمنة وQR',
                        'Open secure invoices & QR',
                      ),
                      icon: Icons.qr_code,
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _guardCustomerPage(
                            '/orders',
                            InvoiceDocumentsScreen(client: supabase),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final invoice in _invoices)
                      CustomerPanel(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.receipt_long,
                            color: customerGold,
                          ),
                          title: Text(
                            invoiceNumber(invoice),
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            '${invoice['service_name']} · ${invoiceDate(invoice, ar)}',
                            style: const TextStyle(color: customerIce),
                          ),
                          trailing: Text(
                            '${invoice['total']} EGP',
                            style: const TextStyle(color: customerGold),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

class CustomerAccountScreen extends StatefulWidget {
  const CustomerAccountScreen({super.key});

  @override
  State<CustomerAccountScreen> createState() => _CustomerAccountScreenState();
}

class _CustomerAccountScreenState extends State<CustomerAccountScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  DateTime? _birthDate;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController.text =
        supabase.auth.currentUser?.userMetadata?['full_name']?.toString() ?? '';
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final row = await supabase
          .from('customers')
          .select('full_name, phone, date_of_birth')
          .eq('id', userId)
          .maybeSingle();
      if (!mounted) return;
      if (row != null) {
        _nameController.text =
            row['full_name']?.toString() ?? _nameController.text;
        _phoneController.text = row['phone']?.toString() ?? '';
        _birthDate = DateTime.tryParse(row['date_of_birth']?.toString() ?? '');
      }
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحميل بيانات الملف الشخصي.',
            'Could not load profile details.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _logout() async {
    final confirmed = await showCustomerDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'تسجيل الخروج', 'Log out')),
        content: Text(
          tr(context, 'هل تريد تسجيل الخروج؟', 'Do you want to log out?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.logout),
            label: Text(tr(context, 'تسجيل الخروج', 'Log out')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await PushNotificationService.signOut();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => HomeScreen(
            locale: _sabihaCurrentLocale,
            onLanguageChanged: _changeSabihaLanguage,
          ),
        ),
        (route) => false,
      );
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تسجيل الخروج. حاول مرة أخرى.',
            'Could not log out. Please try again.',
          ),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    final user = supabase.auth.currentUser;
    final fullName = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    if (user == null || fullName.isEmpty || phone.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'أدخل الاسم ورقم الهاتف.',
          'Enter your name and phone number.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await supabase
          .from('customers')
          .update({
            'full_name': fullName,
            'phone': phone,
            'date_of_birth': _birthDate == null
                ? null
                : _dateString(_birthDate!),
          })
          .eq('id', user.id);
      await supabase.auth.updateUser(
        UserAttributes(data: {...?user.userMetadata, 'full_name': fullName}),
      );
      if (mounted) {
        showMessage(
          context,
          tr(context, 'تم حفظ بيانات الملف الشخصي.', 'Profile details saved.'),
        );
      }
    } on PostgrestException catch (error) {
      if (mounted) {
        showMessage(
          context,
          error.message.contains('duplicate')
              ? tr(
                  context,
                  'رقم الهاتف مستخدم في حساب آخر.',
                  'This phone number is already used by another account.',
                )
              : tr(
                  context,
                  'تعذر حفظ الملف الشخصي.',
                  'Could not save profile details.',
                ),
        );
      }
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر حفظ الملف الشخصي.',
            'Could not save profile details.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = supabase.auth.currentUser;
    return CustomerAdaptiveFrame(
      title: tr(context, 'الملف الشخصي والإعدادات', 'Profile & settings'),
      selected: 4,
      appBar: AppBar(title: Text(tr(context, 'حسابي', 'My account'))),
      bottomNavigationBar: SafeArea(
        child: WhatsAppSupportButton(client: supabase),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                CustomerPanel(
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 34,
                        backgroundColor: customerBlue,
                        child: Icon(
                          Icons.person_outline,
                          color: customerBlack,
                          size: 38,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _nameController.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        user?.email ?? '',
                        style: const TextStyle(color: customerIce),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(context, 'حساب Sabiha Hub', 'Sabiha Hub account'),
                        style: const TextStyle(color: customerIce),
                      ),
                    ],
                  ),
                ),

                Card(
                  child: ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: Text(user?.email ?? ''),
                    subtitle: Text(
                      tr(
                        context,
                        'البريد الإلكتروني المسجل',
                        'Registered email address',
                      ),
                    ),
                  ),
                ),
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: tr(context, 'الاسم الكامل', 'Full name'),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: tr(context, 'رقم الهاتف', 'Phone number'),
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showCustomerDatePicker(
                      context: context,
                      initialDate: _birthDate ?? DateTime(1995),
                      firstDate: DateTime(1920),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _birthDate = picked);
                  },
                  icon: const Icon(Icons.cake_outlined),
                  label: Text(
                    _birthDate == null
                        ? tr(
                            context,
                            'تاريخ الميلاد (اختياري)',
                            'Date of birth (optional)',
                          )
                        : _dateString(_birthDate!),
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: _saving ? null : _saveProfile,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _saving
                        ? tr(context, 'جارٍ الحفظ...', 'Saving...')
                        : tr(context, 'حفظ بياناتي', 'Save profile'),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.link_outlined),
                    title: Text(
                      tr(
                        context,
                        'استرجاع زياراتي السابقة',
                        'Recover my previous visits',
                      ),
                    ),
                    subtitle: Text(
                      tr(
                        context,
                        'طلب آمن ومراجعة المالك بعد مطابقة المعلومات',
                        'A secure request with owner review after matching information',
                      ),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            VisitRecoveryEvidenceScreen(client: supabase),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                CustomerFinancialConsentLink(client: supabase),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.history_outlined),
                    title: Text(
                      tr(
                        context,
                        'سجل زيارات الاستقبال السابق',
                        'Previous reception history',
                      ),
                    ),
                    subtitle: Text(
                      tr(
                        context,
                        'الزيارات والفواتير بعد التحقق من الربط',
                        'Visits and invoices after verified linking',
                      ),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => OfflineHistoryScreen(client: supabase),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock_reset),
                    title: Text(
                      tr(context, 'تغيير كلمة المرور', 'Change password'),
                    ),
                    subtitle: Text(
                      tr(
                        context,
                        'حدّث كلمة مرور حسابك بأمان',
                        'Update your account password securely',
                      ),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ChangeCustomerPasswordScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                CustomerNotificationSettingsPanel(
                  gateway: _SupabaseCustomerNotificationSettingsGateway(
                    supabase,
                  ),
                ),
                const SizedBox(height: 18),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: Text(
                      tr(context, 'تسجيل الخروج', 'Log out'),
                      style: const TextStyle(color: Colors.red),
                    ),
                    subtitle: Text(
                      tr(
                        context,
                        'إنهاء الجلسة مع الاحتفاظ ببيانات حسابك.',
                        'End this session without deleting your account data.',
                      ),
                    ),
                    onTap: _logout,
                  ),
                ),
              ],
            ),
    );
  }
}

class ChangeCustomerPasswordScreen extends StatefulWidget {
  const ChangeCustomerPasswordScreen({super.key});

  @override
  State<ChangeCustomerPasswordScreen> createState() =>
      _ChangeCustomerPasswordScreenState();
}

class _ChangeCustomerPasswordScreenState
    extends State<ChangeCustomerPasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final user = supabase.auth.currentUser;
    final email = user?.email;
    final current = _currentController.text;
    final next = _newController.text;
    if (email == null ||
        current.isEmpty ||
        next.length < 8 ||
        next != _confirmController.text) {
      showMessage(
        context,
        tr(
          context,
          'أدخل كلمة المرور الحالية، واجعل الجديدة 8 أحرف على الأقل وأعد تأكيدها.',
          'Enter your current password, use at least 8 characters for the new password, and confirm it.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await supabase.auth.signInWithPassword(email: email, password: current);
      await supabase.auth.updateUser(UserAttributes(password: next));
      if (!mounted) return;
      showMessage(
        context,
        tr(context, 'تم تحديث كلمة المرور.', 'Password updated.'),
      );
      Navigator.pop(context);
    } on AuthException catch (error) {
      if (mounted) showMessage(context, error.message);
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحديث كلمة المرور.',
            'Could not update the password.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomerAdaptiveFrame(
      title: tr(context, 'الأمان وتسجيل الدخول', 'Security & sign in'),
      selected: 4,
      appBar: AppBar(
        title: Text(tr(context, 'تغيير كلمة المرور', 'Change password')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _currentController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: tr(context, 'كلمة المرور الحالية', 'Current password'),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _newController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: tr(context, 'كلمة المرور الجديدة', 'New password'),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _confirmController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: tr(
                context,
                'تأكيد كلمة المرور الجديدة',
                'Confirm new password',
              ),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _saving ? null : _changePassword,
            child: Text(
              _saving
                  ? tr(context, 'جارٍ الحفظ...', 'Saving...')
                  : tr(context, 'حفظ كلمة المرور', 'Save password'),
            ),
          ),
        ],
      ),
    );
  }
}

// شاشة سيارات العميل
class MyVehiclesScreen extends StatefulWidget {
  const MyVehiclesScreen({super.key});

  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  List<Map<String, dynamic>> _vehicles = [];
  bool _loading = true;
  CustomerSessionStatus _accessStatus = CustomerSessionStatus.signedOut;
  String? _verifiedCustomerId;

  String get _userId => _verifiedCustomerId ?? '';

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  Future<void> _loadVehicles() async {
    if (mounted) setState(() => _loading = true);

    try {
      final access = await SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ).verify();
      if (!mounted) return;
      if (access.status != CustomerSessionStatus.authorized ||
          access.userId == null) {
        setState(() {
          _accessStatus = access.status;
          _verifiedCustomerId = null;
          _vehicles = [];
          _loading = false;
        });
        return;
      }
      final customerId = access.userId!;
      final result = await supabase
          .from('vehicles')
          .select()
          .eq('customer_id', customerId)
          .order('created_at', ascending: false);

      if (!mounted) return;

      setState(() {
        _accessStatus = CustomerSessionStatus.authorized;
        _verifiedCustomerId = customerId;
        _vehicles = List<Map<String, dynamic>>.from(result);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _accessStatus = CustomerSessionStatus.unavailable;
        _verifiedCustomerId = null;
        _vehicles = [];
        _loading = false;
      });
      _message(tr(context, 'تعذر تحميل السيارات', 'Could not load vehicles'));
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _showVehicleDialog({Map<String, dynamic>? vehicle}) async {
    final access = await SupabaseCustomerSessionGateway(
      supabase,
      beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
    ).verify();
    if (!mounted) return;
    if (access.status != CustomerSessionStatus.authorized ||
        access.userId == null ||
        (vehicle != null && vehicle['customer_id'] != access.userId)) {
      _message(
        tr(
          context,
          'انتهت صلاحية الجلسة. أعد تسجيل الدخول للمتابعة.',
          'Your session is no longer valid. Sign in again to continue.',
        ),
      );
      await _loadVehicles();
      return;
    }
    _verifiedCustomerId = access.userId;
    List<Map<String, dynamic>> vehicleClasses;
    try {
      vehicleClasses = List<Map<String, dynamic>>.from(
        await supabase.rpc('get_customer_vehicle_class_options') as List,
      );
    } catch (_) {
      if (!mounted) return;
      _message(
        tr(
          context,
          'تعذر تحميل فئات السيارات.',
          'Could not load vehicle classes.',
        ),
      );
      return;
    }
    if (!mounted) return;
    String? selectedVehicleClassCode =
        vehicle?['vehicle_class_code'] as String?;
    selectedVehicleClassCode ??= vehicleClasses.isEmpty
        ? null
        : vehicleClasses.first['class_code'] as String;
    final brand = TextEditingController(
      text: vehicle?['brand']?.toString() ?? '',
    );
    final model = TextEditingController(
      text: vehicle?['model']?.toString() ?? '',
    );
    final year = TextEditingController(
      text: vehicle?['year']?.toString() ?? '',
    );
    final color = TextEditingController(
      text: vehicle?['color']?.toString() ?? '',
    );
    final plate = TextEditingController(
      text: vehicle?['plate_number']?.toString() ?? '',
    );

    await showCustomerDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            vehicle == null
                ? tr(context, 'إضافة سيارة', 'Add vehicle')
                : tr(context, 'تعديل السيارة', 'Edit vehicle'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: brand,
                  decoration: InputDecoration(
                    labelText: tr(context, 'الماركة', 'Brand'),
                  ),
                ),
                TextField(
                  controller: model,
                  decoration: InputDecoration(
                    labelText: tr(context, 'الموديل', 'Model'),
                  ),
                ),
                TextField(
                  controller: year,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr(context, 'سنة الصنع', 'Year'),
                  ),
                ),
                TextField(
                  controller: color,
                  decoration: InputDecoration(
                    labelText: tr(context, 'اللون', 'Color'),
                  ),
                ),
                TextField(
                  controller: plate,
                  decoration: InputDecoration(
                    labelText: tr(context, 'رقم اللوحة', 'Plate number'),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedVehicleClassCode,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: tr(context, 'فئة السيارة', 'Vehicle class'),
                    helperText: vehicle?['vehicle_class_code'] != null
                        ? tr(
                            context,
                            'لتصحيح الفئة تواصل مع المالك.',
                            'Ask the owner to correct this class.',
                          )
                        : null,
                  ),
                  items: vehicleClasses
                      .map(
                        (row) => DropdownMenuItem<String>(
                          value: row['class_code'] as String,
                          child: Text(
                            '${Localizations.localeOf(context).languageCode == 'ar' ? row['name_ar'] : row['name_en']}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: vehicle?['vehicle_class_code'] != null
                      ? null
                      : (value) {
                          selectedVehicleClassCode = value;
                          setDialogState(() {});
                        },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(context, 'إلغاء', 'Cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final currentAccess = await SupabaseCustomerSessionGateway(
                  supabase,
                ).verify();
                if (!dialogContext.mounted) return;
                if (!mounted) {
                  Navigator.pop(dialogContext);
                  return;
                }
                if (currentAccess.status != CustomerSessionStatus.authorized ||
                    currentAccess.userId != _verifiedCustomerId) {
                  Navigator.pop(dialogContext);
                  if (mounted) await _loadVehicles();
                  return;
                }
                final enteredYear = year.text.trim();
                final parsedYear = enteredYear.isEmpty
                    ? null
                    : int.tryParse(enteredYear);

                if (brand.text.trim().isEmpty ||
                    model.text.trim().isEmpty ||
                    plate.text.trim().isEmpty ||
                    selectedVehicleClassCode == null) {
                  _message(
                    tr(
                      context,
                      'أدخل الماركة والموديل ورقم اللوحة وفئة السيارة',
                      'Enter the make, model, plate number and vehicle class',
                    ),
                  );
                  return;
                }

                if (enteredYear.isNotEmpty &&
                    (parsedYear == null ||
                        parsedYear < 1950 ||
                        parsedYear > 2100)) {
                  _message(
                    tr(context, 'سنة الصنع غير صحيحة', 'Invalid vehicle year'),
                  );
                  return;
                }

                final data = <String, dynamic>{
                  'brand': brand.text.trim(),
                  'model': model.text.trim(),
                  'year': parsedYear,
                  'color': color.text.trim().isEmpty ? null : color.text.trim(),
                  'plate_number': plate.text.trim(),
                };

                try {
                  if (vehicle == null) {
                    await supabase.from('vehicles').insert({
                      ...data,
                      'customer_id': _userId,
                      'vehicle_class_code': selectedVehicleClassCode,
                    });
                  } else {
                    final updateData = <String, dynamic>{...data};
                    if (vehicle['vehicle_class_code'] == null) {
                      updateData['vehicle_class_code'] =
                          selectedVehicleClassCode;
                    }
                    await supabase
                        .from('vehicles')
                        .update(updateData)
                        .eq('id', vehicle['id'])
                        .eq('customer_id', _userId);
                  }

                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  await _loadVehicles();

                  if (mounted) {
                    _message(
                      tr(context, 'تم حفظ السيارة بنجاح', 'Vehicle saved'),
                    );
                  }
                } catch (e) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          tr(
                            dialogContext,
                            'تعذر حفظ السيارة. تحقق من رقم اللوحة والبيانات.',
                            'Could not save vehicle. Check the plate number and details.',
                          ),
                        ),
                      ),
                    );
                  }
                }
              },
              child: Text(tr(context, 'حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteVehicle(Map<String, dynamic> vehicle) async {
    final access = await SupabaseCustomerSessionGateway(
      supabase,
      beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
    ).verify();
    if (!mounted) return;
    if (access.status != CustomerSessionStatus.authorized ||
        access.userId == null ||
        access.userId != vehicle['customer_id']) {
      _message(
        tr(
          context,
          'تعذر التحقق من ملكية السيارة. أعد تسجيل الدخول.',
          'Could not verify vehicle ownership. Sign in again.',
        ),
      );
      await _loadVehicles();
      return;
    }
    final confirmed = await showCustomerDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'حذف السيارة', 'Delete vehicle')),
        content: Text(
          tr(
            context,
            'هل أنت متأكد من حذف هذه السيارة؟',
            'Are you sure you want to delete this vehicle?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'حذف', 'Delete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final currentAccess = await SupabaseCustomerSessionGateway(
        supabase,
        beforeLocalSignOut: PushNotificationService.unregisterCurrentDevice,
      ).verify();
      if (currentAccess.status != CustomerSessionStatus.authorized ||
          currentAccess.userId != access.userId) {
        await _loadVehicles();
        return;
      }
      await supabase
          .from('vehicles')
          .delete()
          .eq('id', vehicle['id'])
          .eq('customer_id', _userId);

      await _loadVehicles();

      if (mounted) {
        _message(tr(context, 'تم حذف السيارة', 'Vehicle deleted'));
      }
    } catch (e) {
      if (mounted) {
        _message(tr(context, 'تعذر حذف السيارة', 'Could not delete vehicle'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authorized =
        _accessStatus == CustomerSessionStatus.authorized && _userId.isNotEmpty;
    return CustomerAdaptiveFrame(
      title: tr(context, 'سياراتي', 'My vehicles'),
      selected: 4,
      appBar: AppBar(
        title: Text(tr(context, 'سياراتي', 'My vehicles')),
        backgroundColor: navy,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: authorized
          ? FloatingActionButton.extended(
              onPressed: () => _showVehicleDialog(),
              backgroundColor: royalBlue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'إضافة سيارة', 'Add vehicle')),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !authorized
          ? _accessStatus == CustomerSessionStatus.unavailable
                ? Center(
                    child: FilledButton(
                      onPressed: _loadVehicles,
                      child: Text(tr(context, 'إعادة المحاولة', 'Retry')),
                    ),
                  )
                : _accessStatus == CustomerSessionStatus.notCustomer
                ? const CustomerAccessDeniedScreen()
                : Center(
                    child: FilledButton(
                      onPressed: () => pushAppRoute(
                        context,
                        name: '/login',
                        arguments: const {'returnRoute': '/vehicles'},
                        builder: (_) => const CustomerLoginScreen(
                          returnRouteAfterLogin: '/vehicles',
                        ),
                      ),
                      child: Text(tr(context, 'تسجيل الدخول', 'Sign in')),
                    ),
                  )
          : _vehicles.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.directions_car_outlined,
                      size: 65,
                      color: silver,
                    ),
                    const SizedBox(height: 15),
                    Text(
                      tr(
                        context,
                        'لم تضف أي سيارة حتى الآن',
                        'You have not added any vehicles yet',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        context,
                        'اضغط على إضافة سيارة للبدء',
                        'Tap Add vehicle to get started',
                      ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadVehicles,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                itemCount: _vehicles.length,
                itemBuilder: (context, index) {
                  final vehicle = _vehicles[index];

                  final details =
                      [
                            vehicle['year']?.toString(),
                            vehicle['color']?.toString(),
                          ]
                          .where((value) => value != null && value.isNotEmpty)
                          .join(' • ');

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFEAF0F8),
                        child: Icon(Icons.directions_car, color: royalBlue),
                      ),
                      title: Text(
                        '${vehicle['brand']} ${vehicle['model']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        [
                          vehicle['plate_number']?.toString() ?? '',
                          details,
                        ].where((value) => value.isNotEmpty).join('\n'),
                      ),
                      isThreeLine: details.isNotEmpty,
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _showVehicleDialog(vehicle: vehicle);
                          } else if (value == 'delete') {
                            _deleteVehicle(vehicle);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(tr(context, 'تعديل', 'Edit')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(tr(context, 'حذف', 'Delete')),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// Retained legacy component for existing checkout history; customer routes use the new visual system.
// ignore: unused_element
class _DashboardTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DashboardTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 17,
          vertical: 10,
        ),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFEAF0F8),
          child: Icon(icon, color: royalBlue),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

// دخول الموظفين
// دخول الموظفين
class StaffLoginScreen extends StatefulWidget {
  const StaffLoginScreen({super.key});

  @override
  State<StaffLoginScreen> createState() => _StaffLoginScreenState();
}

class _StaffLoginScreenState extends State<StaffLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    try {
      final response = await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      final user = response.user;

      if (user == null) {
        throw Exception('تعذر تسجيل الدخول.');
      }

      final profile = await supabase
          .from('staff_profiles')
          .select('user_id, full_name, role, permissions, is_active')
          .eq('user_id', user.id)
          .maybeSingle();

      if (!mounted) return;

      if (profile == null || profile['is_active'] != true) {
        await PushNotificationService.signOut();
        if (!mounted) return;
        _showMessage(
          tr(
            context,
            'هذا الحساب غير مصرح له بدخول الموظفين.',
            'This account is not authorized for staff access.',
          ),
        );
        return;
      }

      final role = profile['role']?.toString() ?? 'employee';
      final permissions = Map<String, dynamic>.from(
        profile['permissions'] as Map? ?? {},
      );
      final fullName = profile['full_name']?.toString() ?? '';

      pushAppRoute(
        context,
        name: '/staff-home',
        replace: true,
        builder: (_) => StaffDashboardScreen(
          role: role,
          permissions: permissions,
          fullName: fullName,
        ),
      );
    } on AuthException catch (e) {
      if (mounted) {
        _showMessage(
          authFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.message,
            statusCode: e.statusCode,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showMessage(
          authFailureMessage(
            languageCode: Localizations.localeOf(context).languageCode,
            message: e.toString(),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'دخول الموظفين', 'Staff Login'))),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    brandLogo(),
                    const SizedBox(height: 25),
                    Text(
                      tr(context, 'بوابة الموظفين', 'Staff Portal'),
                      style: const TextStyle(
                        color: navy,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 25),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: tr(
                          context,
                          'البريد الإلكتروني',
                          'Email address',
                        ),
                        prefixIcon: const Icon(Icons.email_outlined),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return tr(
                            context,
                            'أدخل البريد الإلكتروني',
                            'Enter your email',
                          );
                        }
                        if (!value.contains('@')) {
                          return tr(
                            context,
                            'البريد الإلكتروني غير صحيح',
                            'Enter a valid email',
                          );
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: tr(context, 'كلمة المرور', 'Password'),
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return tr(
                            context,
                            'أدخل كلمة المرور',
                            'Enter your password',
                          );
                        }
                        return null;
                      },
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('staff-forgot-password'),
                        onPressed: () => pushAppRoute(
                          context,
                          name: '/forgot-password',
                          builder: (_) => const ForgotPasswordScreen(),
                        ),
                        child: Text(
                          tr(context, 'نسيت كلمة المرور؟', 'Forgot password?'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 25),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _login,
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(tr(context, 'تسجيل الدخول', 'Sign In')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BusinessDocumentsScreen extends StatefulWidget {
  const BusinessDocumentsScreen({super.key});

  @override
  State<BusinessDocumentsScreen> createState() =>
      _BusinessDocumentsScreenState();
}

class _BusinessDocumentsScreenState extends State<BusinessDocumentsScreen> {
  static const _categories = [
    'Commercial license',
    'Tax / VAT',
    'Lease',
    'Insurance',
    'Municipal permit',
    'Contract',
    'Other',
  ];
  List<Map<String, dynamic>> _documents = [];
  List<String> _expiryAlerts = [];
  List<Map<String, dynamic>> _deliveryAlerts = [];
  bool _loading = true;
  bool _uploading = false;
  String _documentSearch = "";

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('business_documents')
          .select(
            'document_id, category, title, original_filename, mime_type, storage_path, document_number, issuing_authority, issued_at, expires_at, ai_status, extracted_data, approved_at',
          )
          .order('expires_at');
      await _syncExpiryAlerts(List<Map<String, dynamic>>.from(rows));
      if (mounted) {
        setState(() {
          _documents = List<Map<String, dynamic>>.from(rows);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر تحميل المستندات. تحقق من صلاحية المالك وإعداد قاعدة البيانات.',
            'Could not load documents. Check owner access and database setup.',
          ),
        );
      }
    }
  }

  Future<void> _syncExpiryAlerts(List<Map<String, dynamic>> documents) async {
    // The scheduled server function owns durable alerts and Push delivery.
    // The screen only renders a local reminder; it must never mark a Push alert sent.
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final messages = <String>[];
    for (final doc in documents) {
      final expiry = DateTime.tryParse(doc['expires_at']?.toString() ?? '');
      if (expiry == null) continue;
      final expiryDate = DateTime(expiry.year, expiry.month, expiry.day);
      final days = expiryDate.difference(todayDate).inDays;
      final title = doc['title'].toString();
      if (days < 0) {
        messages.add(
          isArabic
              ? 'المستند "$title" منتهي ويحتاج تجديداً.'
              : '"$title" has expired and needs renewal.',
        );
      } else if ([0, 7, 15, 30].contains(days)) {
        messages.add(
          days == 0
              ? (isArabic
                    ? 'المستند "$title" ينتهي اليوم.'
                    : '"$title" expires today.')
              : (isArabic
                    ? 'المستند "$title" ينتهي خلال $days يوماً.'
                    : '"$title" expires in $days days.'),
        );
      }
    }
    List<Map<String, dynamic>> delivery = [];
    try {
      delivery = List<Map<String, dynamic>>.from(
        await supabase
            .from('business_document_alerts')
            .select(
              'alert_id, document_id, alert_date, days_before_expiry, delivery_status, sent_at, last_error',
            )
            .order('alert_date', ascending: false)
            .limit(50),
      );
    } catch (_) {}
    if (mounted) {
      setState(() {
        _expiryAlerts = messages;
        _deliveryAlerts = delivery;
      });
    }
  }

  String _expiryLabel(dynamic raw) {
    if (raw == null) {
      return tr(context, 'لا يوجد تاريخ انتهاء', 'No expiry date');
    }
    final expiry = DateTime.tryParse(raw.toString());
    if (expiry == null) return raw.toString();
    final days = documentDaysRemaining(raw.toString(), DateTime.now())!;
    if (days < 0) {
      return tr(context, 'منتهي منذ ${-days} يوم', 'Expired ${-days} days ago');
    }
    if (days <= 30) {
      return tr(context, 'ينتهي خلال $days يوم', 'Expires in $days days');
    }
    return tr(
      context,
      'ينتهي في ${raw.toString()}',
      'Expires ${raw.toString()}',
    );
  }

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _mime(String extension) => switch (extension.toLowerCase()) {
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => '',
  };

  Future<void> _upload() async {
    final tooLargeMessage = tr(
      context,
      'اختر PDF أو صورة حتى 20 ميجابايت.',
      'Choose a PDF or image up to 20 MB.',
    );
    final addTitle = tr(context, 'إضافة مستند', 'Add document');
    final categoryLabel = tr(context, 'التصنيف', 'Category');
    final titleLabel = tr(context, 'اسم المستند', 'Document title');
    final privacyNotice = tr(
      context,
      'سيُحفظ الملف في مساحة خاصة. عند اختيار تحليل AI لاحقاً، سيُرسل الملف إلى مزود الذكاء الاصطناعي بعد موافقتك.',
      'The file is stored privately. If you later choose AI analysis, it will be sent to the AI provider after your confirmation.',
    );
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (result.isEmpty || !mounted) return;
    final file = result.first;
    final mime = _mime(file.extension ?? '');
    final size = await file.length();
    if (!mounted) return;
    if (size == null || size == 0 || size > 20 * 1024 * 1024 || mime.isEmpty) {
      showMessage(context, tooLargeMessage);
      return;
    }
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final titleController = TextEditingController(
      text: file.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
    );
    String category = _categories.last;
    DateTime? issuedAt;
    DateTime? expiresAt;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(addTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: InputDecoration(labelText: categoryLabel),
                  items: _categories
                      .map(
                        (item) =>
                            DropdownMenuItem(value: item, child: Text(item)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setDialogState(() => category = value);
                  },
                ),
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(labelText: titleLabel),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: dialogContext,
                      initialDate: issuedAt ?? DateTime.now(),
                      firstDate: DateTime(1950),
                      lastDate: DateTime(2100),
                    );
                    if (date != null) setDialogState(() => issuedAt = date);
                  },
                  icon: const Icon(Icons.event_available),
                  label: Text(
                    issuedAt == null
                        ? tr(
                            context,
                            'تاريخ الإصدار (اختياري)',
                            'Issue date (optional)',
                          )
                        : '${tr(context, 'الإصدار', 'Issued')}: ${_dateOnly(issuedAt!)}',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: dialogContext,
                      initialDate:
                          expiresAt ??
                          DateTime.now().add(const Duration(days: 365)),
                      firstDate: DateTime(1950),
                      lastDate: DateTime(2100),
                    );
                    if (date != null) setDialogState(() => expiresAt = date);
                  },
                  icon: const Icon(Icons.event_busy),
                  label: Text(
                    expiresAt == null
                        ? tr(
                            context,
                            'تاريخ الانتهاء (اختياري)',
                            'Expiry date (optional)',
                          )
                        : '${tr(context, 'الانتهاء', 'Expires')}: ${_dateOnly(expiresAt!)}',
                  ),
                ),
                const SizedBox(height: 8),
                Text(privacyNotice, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, 'إلغاء', 'Cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(context, 'حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) {
      titleController.dispose();
      return;
    }
    final title = titleController.text.trim();
    titleController.dispose();
    if (title.isEmpty) {
      showMessage(
        context,
        tr(context, 'اكتب اسم المستند.', 'Enter a document title.'),
      );
      return;
    }
    if (issuedAt != null &&
        expiresAt != null &&
        expiresAt!.isBefore(issuedAt!)) {
      showMessage(
        context,
        tr(
          context,
          'تاريخ الانتهاء لا يمكن أن يسبق تاريخ الإصدار.',
          'The expiry date cannot be before the issue date.',
        ),
      );
      return;
    }
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    setState(() => _uploading = true);
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$userId/${DateTime.now().microsecondsSinceEpoch}_$safeName';
    try {
      final digest = sha256.convert(bytes).toString();
      final existing = await supabase
          .from('business_documents')
          .select('document_id')
          .eq('content_sha256', digest)
          .maybeSingle();
      if (existing != null) {
        if (mounted) {
          showMessage(
            context,
            tr(
              context,
              'هذا الملف محفوظ بالفعل.',
              'This file is already stored.',
            ),
          );
        }
        return;
      }
      await supabase.storage
          .from('business-documents')
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mime, upsert: false),
          );
      await supabase.from('business_documents').insert({
        'category': category,
        'title': title,
        'original_filename': file.name,
        'mime_type': mime,
        'storage_path': path,
        'content_sha256': digest,
        'issued_at': issuedAt == null ? null : _dateOnly(issuedAt!),
        'expires_at': expiresAt == null ? null : _dateOnly(expiresAt!),
        'created_by': userId,
      });
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تم حفظ المستند في المساحة الخاصة.',
            'Document saved to private storage.',
          ),
        );
        await _load();
      }
    } catch (_) {
      // Keep uncertain uploads: the metadata request may have committed before timing out.
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر رفع المستند. تحقق من إعداد مساحة التخزين.',
            'Could not upload the document. Check storage setup.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _analyze(Map<String, dynamic> doc) async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          tr(context, 'إرسال المستند إلى AI؟', 'Send document to AI?'),
        ),
        content: Text(
          tr(
            context,
            'سيتم إرسال نسخة من الملف إلى مزود الذكاء الاصطناعي لاستخراج البيانات. لن تُحفظ النتائج تلقائياً؛ ستراجعها وتوافق عليها بنفسك.',
            'A copy of this file will be sent to the AI provider for extraction. Results will not be saved automatically; you will review and approve them.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'أوافق وحلّل', 'Agree and analyze')),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    try {
      final result = await supabase.functions.invoke(
        'analyze-business-document',
        body: {'document_id': doc['document_id']},
      );
      if (!mounted) return;
      final payload = Map<String, dynamic>.from(result.data as Map);
      final extraction = Map<String, dynamic>.from(
        payload['extraction'] as Map,
      );
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            tr(context, 'راجع البيانات المستخرجة', 'Review extracted data'),
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: extraction.entries
                    .map(
                      (entry) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('${entry.key}: ${entry.value}'),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, 'تجاهل', 'Discard')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(context, 'اعتماد البيانات', 'Approve data')),
            ),
          ],
        ),
      );
      if (accepted == true) {
        await _edit(doc, extraction: extraction);
      }
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر التحليل. لم تتغير بيانات المستند.',
            'Analysis failed. Document data was not changed.',
          ),
        );
      }
    }
  }

  Future<void> _edit(
    Map<String, dynamic> doc, {
    Map<String, dynamic>? extraction,
  }) async {
    final source = {...doc, ...?extraction};
    final title = TextEditingController(text: doc['title']?.toString() ?? '');
    final number = TextEditingController(
      text: source['document_number']?.toString() ?? '',
    );
    final authority = TextEditingController(
      text: source['issuing_authority']?.toString() ?? '',
    );
    final issued = TextEditingController(
      text: source['issued_at']?.toString() ?? '',
    );
    final expires = TextEditingController(
      text: source['expires_at']?.toString() ?? '',
    );
    final rawCategory =
        extraction?['document_type']?.toString() ?? doc['category']?.toString();
    var category = _categories.contains(rawCategory)
        ? rawCategory!
        : _categories.last;
    String? error;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          title: Text(
            tr(
              context,
              'مراجعة وتعديل بيانات المستند',
              'Review and edit document details',
            ),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    decoration: InputDecoration(
                      labelText: tr(context, 'اسم المستند', 'Document title'),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    items: _categories
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) category = value;
                    },
                  ),
                  TextField(
                    controller: number,
                    decoration: InputDecoration(
                      labelText: tr(context, 'رقم المستند', 'Document number'),
                    ),
                  ),
                  TextField(
                    controller: authority,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'جهة الإصدار',
                        'Issuing authority',
                      ),
                    ),
                  ),
                  TextField(
                    controller: issued,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'الإصدار YYYY-MM-DD',
                        'Issued YYYY-MM-DD',
                      ),
                    ),
                  ),
                  TextField(
                    controller: expires,
                    decoration: InputDecoration(
                      labelText: tr(
                        context,
                        'الانتهاء YYYY-MM-DD',
                        'Expires YYYY-MM-DD',
                      ),
                    ),
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, 'إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final issue = issued.text.trim();
                final expiry = expires.text.trim();
                bool validDate(String value) {
                  if (value.isEmpty) return true;
                  final parsed = DateTime.tryParse(value);
                  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
                      parsed != null &&
                      _dateOnly(parsed) == value;
                }

                if (title.text.trim().isEmpty ||
                    !validDate(issue) ||
                    !validDate(expiry) ||
                    (issue.isNotEmpty &&
                        expiry.isNotEmpty &&
                        expiry.compareTo(issue) < 0)) {
                  updateDialog(
                    () => error = tr(
                      context,
                      'أدخل اسماً وتواريخ صحيحة؛ الانتهاء بعد الإصدار.',
                      'Enter a title and valid dates; expiry must follow issue.',
                    ),
                  );
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: Text(tr(context, 'اعتماد وحفظ', 'Approve and save')),
            ),
          ],
        ),
      ),
    );
    final updates = <String, dynamic>{
      'title': title.text.trim(),
      'category': category,
      'document_number': number.text.trim().isEmpty ? null : number.text.trim(),
      'issuing_authority': authority.text.trim().isEmpty
          ? null
          : authority.text.trim(),
      'issued_at': issued.text.trim().isEmpty ? null : issued.text.trim(),
      'expires_at': expires.text.trim().isEmpty ? null : expires.text.trim(),
    };
    for (final controller in [title, number, authority, issued, expires]) {
      controller.dispose();
    }
    if (accepted != true || !mounted) return;
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      if (extraction != null) {
        updates['extracted_data'] = extraction;
        updates['ai_status'] = 'processed';
      }
      updates.addAll({
        'approved_by': user.id,
        'approved_by_label': user.email,
        'approved_at': DateTime.now().toUtc().toIso8601String(),
      });
      await supabase
          .from('business_documents')
          .update(updates)
          .eq('document_id', doc['document_id']);
      // Remove obsolete unsent reminders only after the renewed dates have been saved.
      if (updates['expires_at'] != doc['expires_at']) {
        await supabase
            .from('business_document_alerts')
            .delete()
            .eq('document_id', doc['document_id'])
            .isFilter('sent_at', null);
      }
      await _load();
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر حفظ بيانات المستند. حدّث القائمة للتحقق.',
            'Could not save document details. Refresh to check the current data.',
          ),
        );
      }
    }
  }

  Future<void> _open(Map<String, dynamic> doc) async {
    try {
      final url = await supabase.storage
          .from('business-documents')
          .createSignedUrl(doc['storage_path'].toString(), 60);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(doc['title'].toString()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if ((doc['mime_type']?.toString() ?? '').startsWith('image/'))
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    url,
                    height: 260,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Text(
                      tr(
                        context,
                        'تعذر عرض الصورة.',
                        'Could not preview the image.',
                      ),
                    ),
                  ),
                )
              else
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf, color: navy),
                  title: Text(doc['original_filename']?.toString() ?? ''),
                  subtitle: Text(
                    tr(context, 'ملف PDF خاص', 'Private PDF file'),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(context, 'إغلاق', 'Close')),
            ),
            FilledButton.icon(
              onPressed: () async {
                final launched = await launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                );
                if (!launched && mounted) {
                  showMessage(
                    context,
                    tr(context, 'تعذر فتح الملف.', 'Could not open the file.'),
                  );
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: Text(tr(context, 'فتح / تنزيل', 'Open / download')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر إنشاء رابط عرض آمن.',
            'Could not create a secure viewing link.',
          ),
        );
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'حذف المستند؟', 'Delete document?')),
        content: Text(
          tr(
            context,
            'سيُحذف الملف وبياناته نهائياً.',
            'The file and its metadata will be permanently deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'إلغاء', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'حذف', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await supabase
          .from('business_documents')
          .delete()
          .eq('document_id', doc['document_id']);
      await supabase.storage.from('business-documents').remove([
        doc['storage_path'].toString(),
      ]);
      await _load();
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(context, 'تعذر حذف المستند.', 'Could not delete the document.'),
        );
      }
    }
  }

  Future<void> _replace(Map<String, dynamic> doc) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (file == null || !mounted) return;
    final mime = _mime(file.extension ?? '');
    final size = await file.length();
    if (!mounted) return;
    if (size == null || size == 0 || size > 20 * 1024 * 1024 || mime.isEmpty) {
      showMessage(
        context,
        tr(
          context,
          'اختر PDF أو صورة حتى 20 ميجابايت.',
          'Choose a PDF or image up to 20 MB.',
        ),
      );
      return;
    }
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final newPath =
        '$userId/${DateTime.now().microsecondsSinceEpoch}_$safeName';
    final oldPath = doc['storage_path'].toString();
    try {
      final digest = sha256.convert(bytes).toString();
      final existing = await supabase
          .from('business_documents')
          .select('document_id')
          .eq('content_sha256', digest)
          .maybeSingle();
      if (existing != null && existing['document_id'] != doc['document_id']) {
        if (mounted) {
          showMessage(
            context,
            tr(
              context,
              'هذا الملف محفوظ في مستند آخر.',
              'This file is already stored in another document.',
            ),
          );
        }
        return;
      }
      await supabase.storage
          .from('business-documents')
          .uploadBinary(
            newPath,
            bytes,
            fileOptions: FileOptions(contentType: mime, upsert: false),
          );
      await supabase
          .from('business_document_alerts')
          .delete()
          .eq('document_id', doc['document_id'])
          .isFilter('sent_at', null);
      await supabase
          .from('business_documents')
          .update({
            'original_filename': file.name,
            'mime_type': mime,
            'storage_path': newPath,
            'content_sha256': digest,
            'document_number': null,
            'issuing_authority': null,
            'issued_at': null,
            'expires_at': null,
            'ai_status': 'pending',
            'extracted_data': {},
            'approved_by': null,
            'approved_by_label': null,
            'approved_at': null,
          })
          .eq('document_id', doc['document_id']);
      try {
        await supabase.storage.from('business-documents').remove([oldPath]);
      } catch (_) {
        // Retain the current file and metadata when obsolete-file cleanup fails.
      }
      await _load();
    } catch (_) {
      // Retain both copies after an uncertain metadata update; do not risk deleting the active file.
      if (mounted) {
        showMessage(
          context,
          tr(context, 'تعذر استبدال الملف.', 'Could not replace the file.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr(context, 'مستندات المنشأة', 'Business documents')),
      actions: [
        IconButton(
          tooltip: tr(context, 'مساعد المستندات', 'Document assistant'),
          icon: const Icon(Icons.auto_awesome),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DocumentAssistantScreen(client: supabase),
            ),
          ),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _uploading ? null : _upload,
      icon: _uploading
          ? const CircularProgressIndicator()
          : const Icon(Icons.upload_file),
      label: Text(tr(context, 'رفع مستند', 'Upload document')),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
              children: [
                TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: tr(
                      context,
                      'بحث بالاسم أو التصنيف أو الرقم',
                      'Search title, category or number',
                    ),
                  ),
                  onChanged: (value) => setState(
                    () => _documentSearch = value.trim().toLowerCase(),
                  ),
                ),
                ..._expiryAlerts.map(
                  (message) => Card(
                    color: Colors.orange.shade50,
                    child: ListTile(
                      leading: const Icon(
                        Icons.notification_important,
                        color: Colors.deepOrange,
                      ),
                      title: Text(message),
                    ),
                  ),
                ),
                if (_deliveryAlerts.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                    child: Text(
                      tr(
                        context,
                        'سجل تنبيهات التجديد',
                        'Renewal alert history',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ..._deliveryAlerts.map((alert) {
                    final document = _documents.firstWhere(
                      (item) =>
                          item['document_id']?.toString() ==
                          alert['document_id']?.toString(),
                      orElse: () => <String, dynamic>{},
                    );
                    final days =
                        (alert['days_before_expiry'] as num?)?.toInt() ?? 0;
                    final status =
                        alert['delivery_status']?.toString() ?? 'queued';
                    final statusLabel = switch (status) {
                      'sent' => tr(context, 'أُرسل', 'Sent'),
                      'sending' => tr(context, 'قيد الإرسال', 'Sending'),
                      'failed' => tr(context, 'تعذّر الإرسال', 'Failed'),
                      _ => tr(context, 'مجدول', 'Scheduled'),
                    };
                    final description = days < 0
                        ? tr(
                            context,
                            'تذكير بعد انتهاء الصلاحية',
                            'After-expiry reminder',
                          )
                        : days == 0
                        ? tr(context, 'يوم الانتهاء', 'Expiry day')
                        : tr(
                            context,
                            'قبل الانتهاء بـ $days يوم',
                            '$days days before expiry',
                          );
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        status == 'sent'
                            ? Icons.check_circle_outline
                            : status == 'failed'
                            ? Icons.error_outline
                            : Icons.schedule,
                      ),
                      title: Text(
                        document['title']?.toString() ??
                            tr(context, 'مستند', 'Document'),
                      ),
                      subtitle: Text(
                        '$description · ${alert['alert_date']}${alert['last_error'] == null ? '' : '\n${alert['last_error']}'}',
                      ),
                      trailing: Text(statusLabel),
                    );
                  }),
                ],
                if (_documents.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: Center(
                      child: Text(
                        tr(
                          context,
                          'لا توجد مستندات بعد.',
                          'No documents yet.',
                        ),
                      ),
                    ),
                  ),
                ..._documents
                    .where(
                      (doc) =>
                          [
                            'title',
                            'category',
                            'document_number',
                            'original_filename',
                          ].any(
                            (key) => (doc[key]?.toString() ?? '')
                                .toLowerCase()
                                .contains(_documentSearch),
                          ),
                    )
                    .map((doc) {
                      final expiry = doc['expires_at'];
                      final days =
                          documentDaysRemaining(
                            expiry?.toString(),
                            DateTime.now(),
                          ) ??
                          999;
                      final color = days < 0
                          ? Colors.red
                          : days <= 30
                          ? Colors.deepOrange
                          : navy;
                      return Card(
                        child: ListTile(
                          isThreeLine: true,
                          leading: Icon(
                            days < 0
                                ? Icons.warning_amber
                                : Icons.description_outlined,
                            color: color,
                          ),
                          title: Text(doc['title'].toString()),
                          subtitle: Text(
                            '${doc['category']} · ${doc['issued_at'] == null ? '' : '${tr(context, 'الإصدار', 'Issued')} ${doc['issued_at']} · '}${_expiryLabel(expiry)}\n${doc['ai_status'] == 'needs_review' ? tr(context, 'نتائج AI بانتظار المراجعة', 'AI results need review') : doc['ai_status']}',
                          ),
                          onTap: () => _open(doc),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'edit') _edit(doc);
                              if (action == 'ai') _analyze(doc);
                              if (action == 'replace') _replace(doc);
                              if (action == 'delete') _delete(doc);
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(
                                  tr(
                                    context,
                                    'تعديل البيانات وتجديد الصلاحية',
                                    'Edit details and renew expiry',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'ai',
                                child: Text(
                                  tr(
                                    context,
                                    'تحليل بمساعدة AI',
                                    'Analyze with AI',
                                  ),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'replace',
                                child: Text(
                                  tr(context, 'استبدال الملف', 'Replace file'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(
                                  tr(context, 'حذف المستند', 'Delete document'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
              ],
            ),
          ),
  );
}

class StaffOperationsScreen extends StatefulWidget {
  final String role;
  final String fullName;
  final SupabaseClient? client;

  const StaffOperationsScreen({
    super.key,
    required this.role,
    required this.fullName,
    this.client,
  });

  @override
  State<StaffOperationsScreen> createState() => _StaffOperationsScreenState();
}

class _StaffOperationsScreenState extends State<StaffOperationsScreen> {
  SupabaseClient get _client => widget.client ?? supabase;

  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _staffDirectory = [];
  bool _loading = true;
  String? _error;
  final Set<String> _updating = {};

  bool get _canManageBookings =>
      widget.role == 'owner' || widget.role == 'manager';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final value = await _client.rpc('get_staff_operations');
      final data = Map<String, dynamic>.from(value as Map);
      _bookings = List<Map<String, dynamic>>.from(data['bookings'] as List);
      _orders = List<Map<String, dynamic>>.from(data['orders'] as List);
      _staffDirectory = List<Map<String, dynamic>>.from(
        data['staff_directory'] as List,
      );
    } catch (_) {
      _error = 'load_failed';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _assignBooking(Map<String, dynamic> booking) async {
    final selected = Set<String>.from(
      (booking['assigned_staff_ids'] as List? ?? []).map((id) => id.toString()),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          title: Text(tr(context, 'تكليف فريق العمل', 'Assign staff')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_staffDirectory.isEmpty)
                    Text(
                      tr(
                        context,
                        'لا توجد حسابات موظفين نشطة.',
                        'No active staff accounts.',
                      ),
                    ),
                  ..._staffDirectory.map((person) {
                    final id = person['user_id'].toString();
                    return CheckboxListTile(
                      value: selected.contains(id),
                      title: Text(person['full_name']?.toString() ?? ''),
                      subtitle: Text(
                        '${person['role']} · ${id.substring(id.length - 8)}',
                      ),
                      onChanged: (value) => updateDialog(() {
                        if (value == true) {
                          selected.add(id);
                        } else {
                          selected.remove(id);
                        }
                      }),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, 'إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(context, 'حفظ التكليف', 'Save assignment')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      final isOrder = booking.containsKey('order_id');
      final table = isOrder ? 'business_orders' : 'bookings';
      final idField = isOrder ? 'order_id' : 'id';
      final rows = await _client
          .from(table)
          .update({'assigned_staff_ids': selected.toList()})
          .eq(idField, booking[idField])
          .eq('status', booking['status'])
          .select(idField);
      if (rows.isEmpty) throw StateError('Booking changed or no permission');
      await _load();
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(
            context,
            'تعذر حفظ التكليف. حدّث القائمة.',
            'Could not save assignment. Refresh the list.',
          ),
        );
      }
    }
  }

  Future<bool> _routeCanonicalServiceWork({
    String? orderId,
    String? bookingId,
    required String requestedStatus,
  }) async {
    final value = await _client.rpc(
      'get_service_work_context',
      params: {'p_order': orderId, 'p_booking': bookingId},
    );
    final work = Map<String, dynamic>.from(value as Map);
    final route = serviceWorkRoute(
      work,
      booking: bookingId != null,
      requestedStatus: requestedStatus,
    );
    if (route == ServiceWorkRoute.legacy) return false;
    if (!mounted) return true;
    if (route == ServiceWorkRoute.review) {
      showMessage(
        context,
        tr(
          context,
          'تحتاج الخدمة إلى مراجعة الإدارة قبل بدء العمل.',
          'Management must review this service before work starts.',
        ),
      );
      return true;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => bookingId != null
            ? ServiceWorkScreen.forBooking(client: _client, booking: bookingId)
            : ServiceWorkScreen.forOrder(client: _client, order: orderId!),
      ),
    );
    return true;
  }

  Future<void> _updateBooking(
    Map<String, dynamic> booking,
    String status,
  ) async {
    final updateKey = 'booking-${booking['id']}';
    if (_updating.contains(updateKey)) return;
    setState(() => _updating.add(updateKey));
    try {
      if (status == 'cancelled' && booking['status'] == 'in_progress') {
        showMessage(
          context,
          tr(
            context,
            'إيقاف العمل الجاري يحتاج مسار الإدارة المخصص. لم تتغير الخدمة أو المدفوعات.',
            'Active work needs its management stop workflow. Service and payments remain unchanged.',
          ),
        );
        return;
      }
      if (status == 'in_progress' || status == 'completed') {
        if (await _routeCanonicalServiceWork(
          bookingId: booking['id'] as String,
          requestedStatus: status,
        )) {
          await _load();
          return;
        }
      }
      final updated = await _client
          .from('bookings')
          .update({'status': status})
          .eq('id', booking['id'])
          .eq('status', booking['status'])
          .select('id');
      if (updated.isEmpty) {
        throw StateError('Work item changed or permission denied');
      }
      await _load();
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(context, 'تعذر تحديث الحجز.', 'Could not update the booking.'),
        );
      }
    } finally {
      if (mounted) setState(() => _updating.remove(updateKey));
    }
  }

  Future<void> _updateOrder(Map<String, dynamic> order, String status) async {
    final updateKey = 'order-${order['order_id']}';
    if (_updating.contains(updateKey)) return;
    setState(() => _updating.add(updateKey));
    try {
      if (order['order_type'] == 'service' &&
          ['in_progress', 'quality_check'].contains(order['status']) &&
          status == 'cancelled') {
        showMessage(
          context,
          tr(
            context,
            'إيقاف خدمة بدأت أو رد دفعة يحتاج مسار الإدارة المخصص.',
            'Stopping active service or refunding a payment needs its management workflow.',
          ),
        );
        return;
      }
      if (order['order_type'] == 'service' &&
          [
            'in_progress',
            'quality_check',
            'completed',
            'delivered',
          ].contains(status)) {
        if (await _routeCanonicalServiceWork(
          orderId: order['order_id'] as String,
          requestedStatus: status,
        )) {
          await _load();
          return;
        }
      }
      final updated = await _client
          .from('business_orders')
          .update({'status': status})
          .eq('order_id', order['order_id'])
          .eq('status', order['status'])
          .select('order_id');
      if (updated.isEmpty) {
        throw StateError('Work item changed or permission denied');
      }
      await _load();
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          tr(context, 'تعذر تحديث المهمة.', 'Could not update the work item.'),
        );
      }
    } finally {
      if (mounted) setState(() => _updating.remove(updateKey));
    }
  }

  String _statusLabel(String status) {
    const labels = {
      'pending': ('قيد المراجعة', 'Pending'),
      'confirmed': ('مؤكد', 'Confirmed'),
      'in_progress': ('قيد التنفيذ', 'In progress'),
      'quality_check': ('مراجعة الجودة', 'Quality check'),
      'completed': ('مكتمل', 'Completed'),
      'cancelled': ('ملغي', 'Cancelled'),
      'received': ('جديد', 'Received'),
      'delivered': ('تم التسليم', 'Delivered'),
    };
    final label = labels[status];
    return label == null ? status : tr(context, label.$1, label.$2);
  }

  Widget _bookingCard(Map<String, dynamic> booking) {
    final status = booking['status']?.toString() ?? 'pending';
    final customer = booking['customers'] is Map
        ? Map<String, dynamic>.from(booking['customers'] as Map)
        : <String, dynamic>{};
    final detail = [
      booking['booking_date']?.toString(),
      booking['booking_time']?.toString(),
      booking['vehicle_type']?.toString(),
    ].where((part) => part != null && part.isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              booking['service_name']?.toString() ?? '',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 5),
            Text(detail),
            if (customer.isNotEmpty)
              Text(
                '${customer['full_name'] ?? '—'} · ${customer['phone'] ?? '—'}',
              ),
            if ((booking['notes']?.toString() ?? '').isNotEmpty)
              Text('${tr(context, 'ملاحظة', 'Note')}: ${booking['notes']}'),
            TextButton.icon(
              onPressed: () => _assignBooking(booking),
              icon: const Icon(Icons.group_add_outlined),
              label: Text(tr(context, 'تكليف الموظفين', 'Assign staff')),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey('${booking['id']}-$status'),
              initialValue: status,
              decoration: InputDecoration(
                labelText: tr(context, 'حالة الحجز', 'Booking status'),
                isDense: true,
              ),
              items: [status, ...?bookingTransitions[status]]
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(_statusLabel(value)),
                    ),
                  )
                  .toList(),
              onChanged: _updating.contains('booking-${booking['id']}')
                  ? null
                  : (value) {
                      if (value != null && value != status) {
                        _updateBooking(booking, value);
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> order) {
    final status = order['status']?.toString() ?? 'received';
    const next = {
      'received': 'in_progress',
      'in_progress': 'quality_check',
      'quality_check': 'completed',
    };
    final nextStatus = next[status];
    final vehicle = [
      order['vehicle_type']?.toString(),
      order['plate_number']?.toString(),
    ].where((part) => part != null && part.isNotEmpty).join(' · ');
    return Card(
      child: ListTile(
        onTap: order['order_type'] == 'service'
            ? () async {
                try {
                  await _routeCanonicalServiceWork(
                    orderId: order['order_id'] as String,
                    requestedStatus: status,
                  );
                  await _load();
                } catch (_) {
                  if (mounted) {
                    showMessage(
                      context,
                      tr(
                        context,
                        'تعذر فتح تفاصيل العمل. حدّث القائمة.',
                        'Could not open work details. Refresh the list.',
                      ),
                    );
                  }
                }
              }
            : null,
        leading: const Icon(Icons.build_circle_outlined, color: navy),
        title: Text(order['service_name']?.toString() ?? ''),
        subtitle: Text(
          [
            order['order_number']?.toString() ?? '',
            vehicle,
            _statusLabel(status),
            order['notes']?.toString() ?? '',
          ].where((part) => part.isNotEmpty).join(' · '),
        ),
        trailing: _canManageBookings
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => _assignBooking(order),
                    icon: const Icon(Icons.group_add_outlined),
                    tooltip: tr(context, 'تكليف الموظفين', 'Assign staff'),
                  ),
                  if (nextStatus != null)
                    IconButton(
                      onPressed:
                          _updating.contains('order-${order['order_id']}')
                          ? null
                          : () => _updateOrder(order, nextStatus),
                      icon: const Icon(Icons.arrow_forward),
                      tooltip: _statusLabel(nextStatus),
                    ),
                ],
              )
            : nextStatus == null
            ? null
            : IconButton(
                tooltip: _statusLabel(nextStatus),
                onPressed: _updating.contains('order-${order['order_id']}')
                    ? null
                    : () => _updateOrder(order, nextStatus),
                icon: const Icon(Icons.arrow_forward, color: navy),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _canManageBookings
              ? tr(context, 'إدارة الحجوزات', 'Booking management')
              : tr(context, 'مهامي اليوم', 'My work'),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'طابور الخدمات', 'Service queue'),
            icon: const Icon(Icons.format_list_numbered),
            onPressed: () async {
              try {
                final branch = await _client.rpc('default_branch_id');
                if (!context.mounted || branch is! String) return;
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ServiceWorkQueueScreen(client: _client, branch: branch),
                  ),
                );
                await _load();
              } catch (_) {
                if (context.mounted) {
                  showMessage(
                    context,
                    tr(
                      context,
                      'تعذر فتح طابور الخدمات. تحقق من الاتصال والصلاحيات.',
                      'Could not open service queue. Check connection and permissions.',
                    ),
                  );
                }
              }
            },
          ),
          IconButton(
            tooltip: tr(context, 'تحديث', 'Refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off, color: Colors.red),
                        title: Text(
                          _error == 'load_failed'
                              ? tr(
                                  context,
                                  'تعذر تحميل المهام. تحقق من اتصال الإنترنت وصلاحيات الحساب.',
                                  'Could not load work items. Check the connection and account permissions.',
                                )
                              : _error!,
                        ),
                        trailing: IconButton(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    ),
                  if (_canManageBookings) ...[
                    Text(
                      tr(context, 'حجوزات العملاء', 'Customer bookings'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: navy,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_bookings.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            tr(
                              context,
                              'لا توجد حجوزات حالياً.',
                              'There are no bookings right now.',
                            ),
                          ),
                        ),
                      ),
                    ..._bookings.map(_bookingCard),
                    const SizedBox(height: 16),
                    Text(
                      tr(
                        context,
                        'طلبات العمل والمتجر',
                        'Work and shop orders',
                      ),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    ..._orders.map(_orderCard),
                  ] else ...[
                    Text(
                      tr(context, 'حجوزاتي المعيّنة', 'Assigned bookings'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: navy,
                      ),
                    ),
                    if (_bookings.isEmpty && _orders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            tr(
                              context,
                              'لا توجد مهام معيّنة لك حالياً.',
                              'No work is assigned to you right now.',
                            ),
                          ),
                        ),
                      ),
                    ..._bookings.map((booking) {
                      final status =
                          booking['status']?.toString() ?? 'confirmed';
                      final nextStatus = status == 'confirmed'
                          ? 'in_progress'
                          : status == 'in_progress'
                          ? 'completed'
                          : null;
                      return Card(
                        child: ListTile(
                          leading: const Icon(
                            Icons.event_available,
                            color: navy,
                          ),
                          title: Text(
                            booking['service_name']?.toString() ?? '',
                          ),
                          subtitle: Text(
                            [
                              booking['booking_date']?.toString() ?? '',
                              booking['booking_time']?.toString() ?? '',
                              booking['vehicle_type']?.toString() ?? '',
                              _statusLabel(status),
                            ].where((part) => part.isNotEmpty).join(' · '),
                          ),
                          trailing: nextStatus == null
                              ? null
                              : IconButton(
                                  tooltip: _statusLabel(nextStatus),
                                  onPressed:
                                      _updating.contains(
                                        'booking-${booking['id']}',
                                      )
                                      ? null
                                      : () =>
                                            _updateBooking(booking, nextStatus),
                                  icon: const Icon(
                                    Icons.arrow_forward,
                                    color: navy,
                                  ),
                                ),
                        ),
                      );
                    }),
                    const SizedBox(height: 14),
                    Text(
                      tr(context, 'طلبات العمل', 'Work orders'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: navy,
                      ),
                    ),
                    ..._orders.map(_orderCard),
                  ],
                  if (_error == null && _bookings.isEmpty && _orders.isEmpty)
                    const SizedBox(height: 200),
                  if (isArabic) const SizedBox(height: 8),
                ],
              ),
            ),
    );
  }
}

// لوحة الموظفين والإدارة
class StaffDashboardScreen extends StatefulWidget {
  final String role;
  final Map<String, dynamic> permissions;
  final String fullName;

  const StaffDashboardScreen({
    super.key,
    required this.role,
    required this.permissions,
    required this.fullName,
  });

  @override
  State<StaffDashboardScreen> createState() => _StaffDashboardScreenState();
}

class _StaffDashboardScreenState extends State<StaffDashboardScreen> {
  late String _displayName = widget.fullName;
  String? _avatarUrl;

  void _openProfile(BuildContext context) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StaffProfileEditorScreen(
          client: supabase,
          onSaved: (profile) {
            if (!mounted) return;
            setState(() {
              _displayName = profile.fullName;
              _avatarUrl = profile.avatarUrl;
            });
          },
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    await PushNotificationService.signOut();
    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          locale: _sabihaCurrentLocale,
          onLanguageChanged: _changeSabihaLanguage,
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    final permissions = widget.permissions;
    final fullName = _displayName;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => InvoiceLinkCoordinator.markNavigationReady(appNavigatorKey),
    );
    void open(Widget screen) =>
        Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    final owner = role == 'owner',
        management = role == 'owner' || role == 'manager';
    return AdminConsole(
      client: supabase,
      notificationAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: Localizations.localeOf(context).languageCode == 'ar'
                ? 'ملفي الشخصي'
                : 'My profile',
            color: Colors.white,
            onPressed: () => _openProfile(context),
            icon: _avatarUrl == null
                ? const Icon(Icons.manage_accounts_outlined)
                : CircleAvatar(
                    radius: 14,
                    foregroundImage: NetworkImage(_avatarUrl!),
                    child: const Icon(Icons.person_outline, size: 17),
                  ),
          ),
          if (owner)
            AppInboxButton(
              client: supabase,
              color: Colors.white,
              onOpen: () => openOwnerInbox(context),
            ),
          IconButton(
            tooltip: Localizations.localeOf(context).languageCode == 'ar'
                ? 'إشعارات الإدارة'
                : 'Admin notifications',
            color: Colors.white,
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: () => open(
              AdminNotificationCenterScreen(client: supabase, role: role),
            ),
          ),
        ],
      ),
      fullName: fullName,
      profileAvatarUrl: _avatarUrl,
      onLogout: () => _logout(context),
      onLanguageChanged: (language) => _changeSabihaLanguage(language),
      actions: [
        AdminAction(
          'schedules',
          'إدارة الحجوزات والمهام',
          'Manage bookings & assigned work',
          Icons.calendar_month,
          () => open(StaffOperationsScreen(role: role, fullName: fullName)),
        ),
        AdminAction(
          'schedules',
          'فحص واستلام سيارات VIP',
          'Vehicle / VIP intake inspections',
          Icons.car_crash_outlined,
          () => open(InspectionHubScreen(client: supabase, role: role)),
        ),
        AdminAction(
          'crm',
          'الشكاوى',
          'Complaints',
          Icons.support_agent,
          () => open(ComplaintsScreen(client: supabase, role: role)),
        ),
        AdminAction(
          'crm',
          'التوصيل والاستلام',
          'Delivery & collection',
          Icons.local_shipping_outlined,
          () => open(FulfillmentOrdersScreen(client: supabase, role: role)),
        ),
        if (management || permissions['cashier'] == true) ...[
          AdminAction(
            'settings',
            'طباعة هذا الجهاز',
            'Printing on this device',
            Icons.print_outlined,
            () => open(
              DevicePrinterSettingsScreen(
                gateway: SupabaseDevicePrinterGateway(supabase),
              ),
            ),
          ),
          AdminAction(
            'cashier',
            'نقطة البيع متعددة البنود',
            'Multi-line point of sale',
            Icons.shopping_cart_checkout,
            () => open(CashierPointOfSaleEntry(client: supabase)),
          ),
          AdminAction(
            'cashier',
            'الكاشير والفواتير والطباعة',
            'Invoices & printing',
            Icons.receipt_long,
            () => open(InvoiceDocumentsScreen(client: supabase, role: role)),
          ),
          AdminAction(
            'cashier',
            'ورديات الكاشير',
            'Cashier shifts',
            Icons.point_of_sale,
            () => open(CashierShiftsScreen(client: supabase, role: role)),
          ),
        ],
        if (owner || permissions['financial_reports'] == true)
          AdminAction(
            'finance',
            'لوحة المالية والتشغيل',
            'Finance & operations dashboard',
            Icons.account_balance_wallet_outlined,
            () => open(
              OwnerFinanceDashboardScreen(
                gateway: SupabaseOwnerFinanceGateway(supabase),
              ),
            ),
          ),
        if (owner) ...[
          AdminAction(
            'reports',
            'تقفيل يوم العمل',
            'Business day close',
            Icons.lock_clock_outlined,
            () => open(
              OwnerDailyClosureScreen(
                gateway: SupabaseOwnerDailyClosureGateway(supabase),
                role: role,
              ),
            ),
          ),
          AdminAction(
            'products',
            'الكتالوج الموحد والأسعار',
            'Unified catalogue and prices',
            Icons.inventory_2_outlined,
            () => open(
              OwnerCatalogEditor(gateway: OwnerCatalogGateway(supabase)),
            ),
          ),
          AdminAction(
            'settings',
            'سياسة عمولات الخدمات',
            'Service commission policy',
            Icons.groups_outlined,
            () => open(
              OwnerServiceCommissionScreen(
                gateway: ServiceCommissionGateway(supabase),
              ),
            ),
          ),
          AdminAction(
            'settings',
            'إعدادات الضرائب والفواتير',
            'Tax & Invoice Settings',
            Icons.account_balance_outlined,
            () => open(OwnerTaxInvoiceSettingsEntry(client: supabase)),
          ),
          AdminAction(
            'crm',
            'الشركات والأساطيل',
            'Companies & fleets',
            Icons.business_outlined,
            () => open(
              CompaniesFleetsCatalogueScreen(
                client: supabase,
                contractBuilder: (context, partyId) =>
                    FleetContractDraftsScreen(
                      client: supabase,
                      partyId: partyId,
                    ),
              ),
            ),
          ),
          AdminAction(
            'crm',
            'مكافآت زيارات الاستقبال',
            'Reception visit rewards',
            Icons.card_giftcard_outlined,
            () => open(OwnerRewardIssuerScreen(client: supabase)),
          ),
          AdminAction(
            'settings',
            'حالة النظام',
            'System health',
            Icons.monitor_heart_outlined,
            () => open(OwnerSystemHealthScreen(client: supabase)),
          ),
          AdminAction(
            'crm',
            'طلبات استرجاع الزيارات السابقة',
            'Previous visits recovery requests',
            Icons.history_outlined,
            () => open(
              OwnerVisitRecoveryScreen(
                client: supabase,
                onCanonicalReview: (context, claimId) async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          OwnerOfflineClaimReviewsScreen(client: supabase),
                    ),
                  );
                },
              ),
            ),
          ),
          AdminAction(
            'crm',
            'مركز الإشعارات',
            'Notification center',
            Icons.notifications_outlined,
            () => open(
              AppInboxScreen(
                client: supabase,
                onOpenRecovery: (_) async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => OwnerVisitRecoveryScreen(
                        client: supabase,
                        onCanonicalReview: (context, claimId) async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => OwnerOfflineClaimReviewsScreen(
                                client: supabase,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          AdminAction(
            'crm',
            'إدارة إشعارات العملاء',
            'Customer Notifications',
            Icons.campaign_outlined,
            () => open(OwnerNotificationsScreen(client: supabase)),
          ),
          AdminAction(
            'security',
            'مراجعة ربط سجلات العملاء',
            'Review customer record links',
            Icons.verified_user_outlined,
            () => open(OwnerOfflineClaimReviewsScreen(client: supabase)),
          ),
          AdminAction(
            'promotions',
            'سياسة زيارات الولاء',
            'Service-visit loyalty policy',
            Icons.loyalty_outlined,
            () => open(LoyaltyPolicyScreen(client: supabase)),
          ),
          AdminAction(
            'intelligence',
            'تحليل الأعمال بالأدلة',
            'Business insights with evidence',
            Icons.insights_outlined,
            () => open(OwnerBusinessInsightsScreen(client: supabase)),
          ),
          AdminAction(
            'employees',
            'التوظيف والمتقدمون',
            'Recruitment & applicants',
            Icons.person_search_outlined,
            () => open(RecruitmentScreen(client: supabase, owner: true)),
          ),
          AdminAction(
            'settings',
            'سياسة فحص الجودة',
            'Quality checklist policy',
            Icons.fact_check_outlined,
            () async {
              final actor = supabase.auth.currentUser?.id;
              try {
                final branch = await supabase.rpc('default_branch_id');
                if (!context.mounted ||
                    branch is! String ||
                    actor == null ||
                    supabase.auth.currentUser?.id != actor) {
                  return;
                }
                open(
                  ServiceQualityPolicyScreen(
                    branch: branch,
                    gateway: SupabaseServiceQualityGateway(supabase),
                  ),
                );
              } catch (_) {
                if (context.mounted) {
                  showMessage(
                    context,
                    tr(
                      context,
                      'تعذر تحميل إعدادات الجودة.',
                      'Could not load quality settings.',
                    ),
                  );
                }
              }
            },
          ),
          AdminAction(
            'settings',
            'الإعدادات المالية',
            'Financial settings',
            Icons.payments_outlined,
            () => open(FinancialSettingsScreen(client: supabase)),
          ),
          AdminAction(
            'intelligence',
            'التحليل الذكي للمدفوعات',
            'AI Payment Analytics',
            Icons.analytics_outlined,
            () => open(AiPaymentAnalyticsScreen(client: supabase)),
          ),
          AdminAction(
            'promotions',
            'الخدمات والأسعار والعروض',
            'Services, prices & offers',
            Icons.local_offer_outlined,
            () => open(OfferManagementScreen(client: supabase)),
          ),
          AdminAction(
            'promotions',
            'كوبونات الخصم',
            'Discount coupons',
            Icons.confirmation_number_outlined,
            () => open(OwnerCouponsScreen(client: supabase)),
          ),
          AdminAction(
            'establishment',
            'إدارة الفروع والسعة والأسعار',
            'Manage branches, capacity & pricing',
            Icons.store,
            () => open(BranchSettingsScreen(client: supabase)),
          ),
          AdminAction(
            'settings',
            'التوصيل وواتساب',
            'Delivery & WhatsApp',
            Icons.settings_phone,
            () => open(ContactDeliverySettingsScreen(client: supabase)),
          ),
          AdminAction(
            'settings',
            'ملفات الطابعات',
            'Printer profiles',
            Icons.print,
            () => open(PrinterSettingsScreen(client: supabase)),
          ),
          AdminAction(
            'settings',
            'مستندات المنشأة',
            'Business documents',
            Icons.folder_special,
            () => open(const BusinessDocumentsScreen()),
          ),
          AdminAction(
            'employees',
            'تقييمات الموظفين وصورهم',
            'Employee reviews & photos',
            Icons.star_outline,
            () => open(EmployeeReviewsScreen(client: supabase, owner: true)),
          ),
          AdminAction(
            'crm',
            'مراجعة تقييمات الخدمات',
            'Moderate service reviews',
            Icons.rate_review,
            () => open(ServiceReviewAdminScreen(client: supabase)),
          ),
        ],
        AdminAction(
          'settings',
          'قائمة العمليات السابقة',
          'Existing operations menu',
          Icons.menu,
          () => open(Builder(builder: legacyDashboard)),
        ),
        AdminAction(
          'employees',
          'تعديل الملف الشخصي',
          'Edit profile',
          Icons.manage_accounts_outlined,
          () => _openProfile(context),
        ),
        AdminAction(
          'employees',
          'اقتراح صورة لدليل الموظفين',
          'Suggest a public staff directory photo',
          Icons.add_a_photo,
          () => proposeEmployeePhoto(context, supabase),
        ),
        AdminAction(
          'employees',
          'الحضور والرواتب والإجازات',
          'Attendance, payroll & leave',
          Icons.badge_outlined,
          () => open(HrPayrollScreen(client: supabase, owner: owner)),
        ),
      ],
    );
  }

  Widget legacyDashboard(BuildContext context) {
    final role = widget.role;
    final permissions = widget.permissions;
    final fullName = _displayName;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => InvoiceLinkCoordinator.markNavigationReady(appNavigatorKey),
    );
    final isOwner = role == 'owner';
    final isManager = role == 'manager';

    final roleName = isOwner
        ? tr(context, 'الإدارة', 'Owner')
        : isManager
        ? tr(context, 'مدير', 'Manager')
        : tr(context, 'موظف', 'Employee');

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isOwner
              ? tr(context, 'لوحة الإدارة', 'Management Dashboard')
              : tr(context, 'لوحة الموظفين', 'Staff Dashboard'),
        ),
        actions: [
          IconButton(
            onPressed: () => _logout(context),
            tooltip: tr(context, 'تسجيل الخروج', 'Log out'),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          brandLogo(),
          const SizedBox(height: 24),
          Text(
            tr(
              context,
              'مرحباً ${fullName.isEmpty ? roleName : fullName}',
              'Welcome ${fullName.isEmpty ? roleName : fullName}',
            ),
            style: const TextStyle(
              color: navy,
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Center(
            child: Chip(
              avatar: Icon(
                isOwner ? Icons.admin_panel_settings : Icons.badge,
                color: navy,
              ),
              label: Text(roleName),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user, color: navy),
              title: Text(
                tr(context, 'تم تسجيل الدخول بنجاح', 'Successfully signed in'),
              ),
              subtitle: Text(
                isOwner && permissions['all'] == true
                    ? tr(
                        context,
                        'لديك صلاحيات الإدارة الكاملة.',
                        'You have full management permissions.',
                      )
                    : tr(
                        context,
                        'سيتم عرض الأقسام حسب صلاحيات حسابك.',
                        'Sections will be available according to your permissions.',
                      ),
              ),
            ),
          ),
          if (isOwner || isManager || permissions['cashier'] == true)
            Card(
              child: ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text(
                  'الفواتير والمسح والطباعة / Invoices & Printing',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        InvoiceDocumentsScreen(client: supabase, role: role),
                  ),
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.car_crash_outlined),
              title: const Text('فحص استلام وتسليم السيارات'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      InspectionHubScreen(client: supabase, role: role),
                ),
              ),
            ),
          ),
          if (isOwner || isManager || permissions['cashier'] == true)
            Card(
              child: ListTile(
                leading: const Icon(Icons.point_of_sale),
                title: const Text('ورديات الكاشير والمدفوعات'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        CashierShiftsScreen(client: supabase, role: role),
                  ),
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('إدارة الشكاوى'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ComplaintsScreen(client: supabase, role: role),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: Text(tr(context, 'تعديل الملف الشخصي', 'Edit profile')),
              onTap: () => _openProfile(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: const Text('إدارة التوصيل والاستلام'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      FulfillmentOrdersScreen(client: supabase, role: role),
                ),
              ),
            ),
          ),
          if (isOwner) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.rate_review),
                title: const Text('مراجعة تقييمات الخدمات / Service Reviews'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ServiceReviewAdminScreen(client: supabase),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.print),
                title: Text(tr(context, 'ملفات الطابعات', 'Printer profiles')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PrinterSettingsScreen(client: supabase),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('تقييمات الموظفين وصورهم'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        EmployeeReviewsScreen(client: supabase, owner: true),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.store_outlined),
                title: const Text('إعدادات المركز والفروع'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BranchSettingsScreen(client: supabase),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.settings_phone_outlined),
                title: const Text('إعدادات التوصيل وواتساب'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ContactDeliverySettingsScreen(client: supabase),
                  ),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.analytics_outlined, color: navy),
                title: Text(
                  tr(
                    context,
                    'تقارير المبيعات والتحصيل',
                    'Sales and collection reports',
                  ),
                ),
                subtitle: Text(
                  tr(
                    context,
                    'الفرع والتوقيت وتصدير PDF وExcel',
                    'Branch, time window, PDF and Excel export',
                  ),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AdminConsole(
                      client: supabase,
                      initialSection: 'reports',
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_special_outlined, color: navy),
                title: Text(
                  tr(context, 'مستندات المنشأة', 'Business documents'),
                ),
                subtitle: Text(
                  tr(
                    context,
                    'الرخص والضرائب والعقود وتنبيهات الانتهاء',
                    'Licenses, tax records, contracts and expiry alerts',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BusinessDocumentsScreen(),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            tr(context, 'الأقسام', 'Sections'),
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: navy,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: Icon(
                isOwner || isManager
                    ? Icons.calendar_month
                    : Icons.build_outlined,
              ),
              title: Text(
                isOwner || isManager
                    ? tr(context, 'إدارة الحجوزات', 'Booking management')
                    : tr(context, 'مهامي اليوم', 'My work'),
              ),
              subtitle: Text(
                isOwner || isManager
                    ? tr(
                        context,
                        'عرض حجوزات العملاء وتحديث حالتها',
                        'View customer bookings and update their status',
                      )
                    : tr(
                        context,
                        'الحجوزات والطلبات المعيّنة لحسابك',
                        'Bookings and work orders assigned to your account',
                      ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      StaffOperationsScreen(role: role, fullName: fullName),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Public services use the same narrow, published-only contract as the website.
class PublicServicesScreen extends StatefulWidget {
  final Duration catalogRefreshInterval;
  const PublicServicesScreen({
    super.key,
    this.catalogRefreshInterval = const Duration(seconds: 30),
  });
  @override
  State<PublicServicesScreen> createState() => _PublicServicesScreenState();
}

class _PublicServicesScreenState extends State<PublicServicesScreen> {
  String _search = '';
  String _category = 'all';
  final Set<String> _compare = {};

  Map<String, dynamic>? data;
  String? branch;
  bool failed = false, reading = false;
  CatalogRefresh? catalogRefresh;
  @override
  void initState() {
    super.initState();
    load();
    catalogRefresh = CatalogRefresh(
      interval: widget.catalogRefreshInterval,
      refresh: load,
      allowed: () =>
          mounted && !reading && (ModalRoute.of(context)?.isCurrent ?? true),
    );
  }

  @override
  void dispose() {
    catalogRefresh?.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (reading) return;
    reading = true;
    try {
      final result = Map<String, dynamic>.from(
        await supabase.rpc('get_public_home'),
      );
      try {
        await enrichCatalogImages(
          supabase,
          List<Map<String, dynamic>>.from(result['catalog'] ?? [])
              .where((x) => x['item_type'] == 'service')
              .toList(),
        );
      } catch (_) {
        /* Approved photo fallback. */
      }
      final branches = List<Map<String, dynamic>>.from(result['branches']);
      if (mounted) {
        setState(() {
          data = result;
          branch ??= branches.isEmpty
              ? null
              : (AppConfig.multiBranchEnabled
                    ? branches.first
                    : branches.firstWhere(
                        (b) => b['is_default'] == true,
                      ))['branch_id'];
          failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      reading = false;
    }
  }

  void _book(Map<String, dynamic> service) {
    BranchSelection.current = branch;
    final serviceId = service['item_id']?.toString();
    pushAppRoute(
      context,
      name: '/booking',
      arguments: {'serviceId': serviceId},
      builder: (_) => _customerPageForRoute('/booking', serviceId: serviceId),
    );
  }

  void _showComparison(List<Map<String, dynamic>> services) {
    final selected = services
        .where((s) => _compare.contains(s['item_id']))
        .toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: customerBlack,
      builder: (c) => Theme(
        data: customerTheme(c),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                tr(c, 'قارن الخدمات والأسعار', 'Compare services & prices'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                tr(
                  c,
                  'أسعار الفرع المحدد فقط، والتأكيد النهائي من الخادم عند الحجز.',
                  'Selected branch prices only. The server confirms the final booking price.',
                ),
                style: const TextStyle(color: customerIce),
              ),
              const SizedBox(height: 16),
              for (final service in selected)
                CustomerPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        customerCatalogText(c, service, 'name'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      CustomerVehicleClassPriceList(
                        service: service,
                        desktop: true,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${service['duration_minutes']} ${tr(c, 'دقيقة', 'min')}',
                        style: const TextStyle(color: customerIce),
                      ),
                      if (customerCatalogText(
                        c,
                        service,
                        'description',
                      ).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            customerCatalogText(c, service, 'description'),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      const SizedBox(height: 10),
                      GoldButton(
                        label: tr(c, 'احجز هذه الخدمة', 'Book this service'),
                        icon: Icons.event_available_outlined,
                        onPressed: () {
                          Navigator.pop(c);
                          _book(service);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopWeb = kIsWeb && MediaQuery.sizeOf(context).width >= 900;
    final branches = List<Map<String, dynamic>>.from(data?['branches'] ?? []);
    final services =
        List<Map<String, dynamic>>.from(data?['catalog'] ?? [])
            .where(
              (x) =>
                  x['branch_id'] == branch &&
                  x['item_type'] == 'service' &&
                  isCurrentService(x),
            )
            .toList()
          ..sort(
            (a, b) =>
                customerServiceOrder(a).compareTo(customerServiceOrder(b)),
          );
    bool matches(Map<String, dynamic> s) {
      final text =
          '${s['name']} ${s['name_en'] ?? ''} ${s['description'] ?? ''} ${s['description_en'] ?? ''}'
              .toLowerCase();
      if (!text.contains(_search.toLowerCase().trim())) return false;
      return switch (_category) {
        'wash' => RegExp('wash|غسيل').hasMatch(text),
        'polish' => RegExp('polish|تلميع').hasMatch(text),
        'protect' => RegExp('protect|ceramic|حماية|سيراميك').hasMatch(text),
        'package' => RegExp('package|bundle|باقة|باقات').hasMatch(text),
        _ => true,
      };
    }

    final visible = services.where(matches).toList();
    final servicesBody = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (desktopWeb)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: 16,
              end: 16,
              top: 22,
              bottom: 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(context, 'خدماتنا وأسعارنا', 'Services & prices'),
                  style: const TextStyle(
                    color: navy,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  tr(
                    context,
                    'اختر العناية المناسبة لسيارتك وقارن التفاصيل',
                    'Find and compare the right care for your car',
                  ),
                  style: TextStyle(
                    color: desktopWeb ? const Color(0xFF526579) : customerIce,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        if (failed) ...[
          Text(
            tr(
              context,
              'تعذر تحميل الخدمات. حاول مجددًا.',
              'Unable to load services. Please retry.',
            ),
          ),
          FilledButton(
            onPressed: load,
            child: Text(tr(context, 'إعادة المحاولة', 'Retry')),
          ),
        ] else if (data == null)
          const LinearProgressIndicator(),
        if (AppConfig.multiBranchEnabled && branches.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: branch,
            decoration: InputDecoration(
              labelText: tr(context, 'الفرع', 'Branch'),
            ),
            items: branches
                .map(
                  (b) => DropdownMenuItem(
                    value: b['branch_id'] as String,
                    child: Text(
                      '${b[Localizations.localeOf(context).languageCode == 'ar' ? 'name_ar' : 'name_en']}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() {
              branch = value;
              _compare.clear();
            }),
          ),
        const SizedBox(height: 16),
        TextField(
          decoration: InputDecoration(
            hintText: tr(context, 'ابحث عن خدمة…', 'Search services…'),
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _search = value),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final c in [
              ('all', 'الكل', 'All'),
              ('wash', 'غسيل', 'Wash'),
              ('polish', 'تلميع', 'Polish'),
              ('package', 'باقات', 'Packages'),
            ])
              ChoiceChip(
                showCheckmark: false,
                selectedColor: desktopWeb ? _publicRoyal : customerBlue,
                backgroundColor: desktopWeb
                    ? const Color(0xFFF7F9FC)
                    : customerNavy,
                side: BorderSide(
                  color: desktopWeb ? const Color(0xFFC5CBD5) : customerBlue,
                ),
                label: Text(
                  tr(context, c.$2, c.$3),
                  style: TextStyle(
                    color: desktopWeb && _category != c.$1
                        ? navy
                        : Colors.white,
                  ),
                ),
                selected: _category == c.$1,
                onSelected: (_) => setState(() => _category = c.$1),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (_compare.length == 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              tr(
                context,
                'اختر خدمة أخرى للمقارنة',
                'Select another service to compare',
              ),
              style: const TextStyle(color: customerGold),
            ),
          ),
        if (_compare.length >= 2) ...[
          GoldButton(
            label: tr(
              context,
              'قارن الخدمات (${_compare.length})',
              'Compare services (${_compare.length})',
            ),
            icon: Icons.compare_arrows,
            onPressed: () => _showComparison(services),
          ),
          const SizedBox(height: 16),
        ],
        if (data != null && visible.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              tr(
                context,
                'لا توجد خدمات منشورة مطابقة لهذا الفرع.',
                'No matching published services for this branch.',
              ),
              style: TextStyle(color: desktopWeb ? navy : null),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1050
                ? 3
                : constraints.maxWidth >= 650
                ? 2
                : 1;
            final spacing = columns == 1 ? 0.0 : 16.0;
            final tileWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final service in visible)
                  SizedBox(
                    width: tileWidth,
                    child: CustomerServiceTile(
                      service: service,
                      onBook: () => _book(service),
                      compareSelected: _compare.contains(service['item_id']),
                      onCompare: (selected) {
                        if (selected && _compare.length >= 3) {
                          showMessage(
                            context,
                            tr(
                              context,
                              'اختر حتى 3 خدمات للمقارنة.',
                              'Choose up to 3 services.',
                            ),
                          );
                          return;
                        }
                        setState(() {
                          if (selected) {
                            _compare.add(service['item_id']);
                          } else {
                            _compare.remove(service['item_id']);
                          }
                        });
                      },
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        Center(
          child: TextButton.icon(
            key: const ValueKey('public-staff-footer'),
            onPressed: () => pushAppRoute(
              context,
              name: '/staff-login',
              builder: (_) => const StaffLoginScreen(),
            ),
            icon: const Icon(Icons.badge_outlined),
            label: Text(tr(context, 'دخول الموظفين', 'Staff sign in')),
            style: TextButton.styleFrom(
              foregroundColor: desktopWeb ? navy : customerIce,
            ),
          ),
        ),
      ],
    );
    if (kIsWeb) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 900) {
            return Theme(
              data: _publicDesktopTheme(context),
              child: Scaffold(
                backgroundColor: Colors.white,
                appBar: _publicDesktopHeader(context),
                body: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1280),
                      child: DefaultTextStyle(
                        style: const TextStyle(color: navy, fontSize: 16),
                        child: servicesBody,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return CustomerShell(
            title: tr(context, 'خدماتنا وأسعارنا', 'Services & prices'),
            subtitle: tr(
              context,
              'اختر العناية المناسبة لسيارتك وقارن التفاصيل',
              'Find and compare the right care for your car',
            ),
            selected: 1,
            onNavigate: (i) => navigateCustomer(context, i),
            icon: Icons.local_car_wash_outlined,
            menuExtras: customerMenuExtras(context),
            body: servicesBody,
          );
        },
      );
    }
    return CustomerShell(
      title: tr(context, 'خدماتنا وأسعارنا', 'Services & prices'),
      subtitle: tr(
        context,
        'اختر العناية المناسبة لسيارتك وقارن التفاصيل',
        'Find and compare the right care for your car',
      ),
      selected: 1,
      onNavigate: (i) => navigateCustomer(context, i),
      icon: Icons.local_car_wash_outlined,
      menuExtras: customerMenuExtras(context),
      body: servicesBody,
    );
  }
}
