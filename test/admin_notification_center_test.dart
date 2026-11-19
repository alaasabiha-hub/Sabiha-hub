import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabiha_hub/admin_notification_center.dart';

class _Gateway implements AdminNotificationGateway {
  @override
  final String actorId = 'qa-staff';
  @override
  bool hasCurrentSession = true;
  final calls = <String>[];
  bool enabled = true;
  bool read = false;

  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) async {
    calls.add(name);
    switch (name) {
      case 'list_admin_notifications':
        return {
          'items': read
              ? []
              : [
                  {
                    'event_id': 'event-1',
                    'category': 'bookings',
                    'template_code': 'booking_created',
                    'title_ar': 'حجز جديد',
                    'title_en': 'New booking',
                    'body_ar': 'يوجد حجز جديد يحتاج مراجعة.',
                    'body_en': 'A new booking needs review.',
                    'created_at': '2026-11-18T00:00:00Z',
                    'read': read,
                  },
                ],
          'unread_count': read ? 0 : 1,
          'push_enabled': false,
        };
      case 'get_admin_notification_settings':
        return {
          'settings': [
            {
              'category': 'bookings',
              'enabled': enabled,
              'recipient_roles': ['owner'],
              'version': 1,
            },
          ],
        };
      case 'mark_admin_notification_read':
        read = true;
        return {
          'event_id': parameters['p_event'],
          'read': true,
          'read_at': '2026-11-18T00:01:00Z',
        };
      case 'save_admin_notification_setting':
        enabled = parameters['p_enabled'] as bool;
        return {
          'category': parameters['p_category'],
          'enabled': enabled,
          'recipient_roles': parameters['p_roles'],
          'version': (parameters['p_expected_version'] as int) + 1,
        };
      default:
        throw StateError('Unexpected RPC $name');
    }
  }
}

void main() {
  late SupabaseClient client;
  setUp(
    () => client = SupabaseClient('https://qa.example.supabase.co', 'anon'),
  );
  tearDown(() => client.dispose());

  testWidgets('renders Arabic admin notice and records its read state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AdminNotificationCenterScreen(
          client: client,
          role: 'employee',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مركز إشعارات الإدارة'), findsOneWidget);
    expect(find.text('حجز جديد'), findsOneWidget);
    expect(find.text('غير مقروءة: 1'), findsOneWidget);
    await tester.tap(find.text('مقروء'));
    await tester.pumpAndSettle();
    expect(gateway.calls, contains('mark_admin_notification_read'));
    expect(find.text('غير مقروءة: 0'), findsOneWidget);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owner can disable a category through the versioned settings RPC',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _Gateway();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: AdminNotificationCenterScreen(
            client: client,
            role: 'owner',
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notification visibility settings'), findsOneWidget);
      expect(find.text('Bookings'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('save_admin_notification_setting'));
      expect(gateway.enabled, isFalse);
    },
  );

  testWidgets('English notification list remains usable on desktop and phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AdminNotificationCenterScreen(
          client: client,
          role: 'cashier',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin notifications'), findsOneWidget);
    expect(find.text('New booking'), findsOneWidget);
    expect(find.text('Unread: 1'), findsOneWidget);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('non-owner cannot access owner settings controls', (
    tester,
  ) async {
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AdminNotificationCenterScreen(
          client: client,
          role: 'manager',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notification visibility settings'), findsNothing);
    expect(gateway.calls, isNot(contains('get_admin_notification_settings')));
  });
}
