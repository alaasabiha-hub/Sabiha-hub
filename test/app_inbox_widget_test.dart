import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_inbox.dart';

import 'app_inbox_test.dart' show Gateway;
import 'app_inbox_live_content_test.dart' show Transport;
import 'visit_recovery_request_test.dart' as auth;

void main() {
  for (final config in [
    ('ar', const Size(390, 844)),
    ('en', const Size(1440, 900)),
  ]) {
    testWidgets('inbox ${config.$1} fits ${config.$2.width}', (tester) async {
      tester.view.physicalSize = config.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Live content is session-bound; use actual typed test Auth and an
      // inert transport rather than an unauthenticated SDK/socket fixture.
      final client = await auth.client(tester);
      final gateway = Gateway();
      gateway.handle = (name, p) async => name == 'mark_my_app_inbox_read'
          ? {
              'event_id': p['p_event'],
              'read': true,
              'read_at': '2026-11-15T00:00:00Z',
            }
          : {
              'items': [
                {
                  'event_id': 'event-a',
                  'source_kind': 'visit_recovery',
                  'case_reference': 'case-a',
                  'title_ar': 'بانتظار مطابقة المعلومات',
                  'title_en': 'Awaiting information matching',
                  'body_ar':
                      'طلب استرجاع زياراتك السابقة في انتظار مطابقة معلوماتك',
                  'body_en': 'Your previous visits recovery request is awaiting information matching.',
                  'created_at': '2026-11-15T00:00:00Z',
                  'read': false,
                },
              ],
              'unread_count': 1,
              'next_cursor': null,
            };
      final flow = AppInboxController(
        gateway: gateway,
        actorId: () => client.auth.currentUser?.id,
      );
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(config.$1),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: AppInboxScreen(
            client: client,
            controller: flow,
            liveTransport: Transport(),
            onOpenRecovery: (id) async {
              opened = id;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 151));
      await tester.pumpAndSettle();
      expect(
        find.text(config.$1 == 'ar' ? 'الإشعارات' : 'Notifications'),
        findsOneWidget,
      );
      expect(
        find.text(
          config.$1 == 'ar'
              ? 'طلب استرجاع زياراتك السابقة في انتظار مطابقة معلوماتك'
              : 'Your previous visits recovery request is awaiting information matching.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.text(config.$1 == 'ar' ? 'متابعة الطلب' : 'View request'),
      );
      await tester.pump();
      expect(opened, 'case-a');
      await tester.tap(
        find.text(config.$1 == 'ar' ? 'تحديد كمقروء' : 'Mark as read'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(config.$1 == 'ar' ? 'غير المقروءة: 0' : 'Unread: 0'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      flow.dispose();
    });
  }
}
