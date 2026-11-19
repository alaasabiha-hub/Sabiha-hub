import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/qa_device_push_test.dart';

class FakeQaPushGateway implements QaDevicePushGateway {
  final messages = StreamController<void>.broadcast();
  QaPushPermission permission = QaPushPermission.granted;
  String? token = 'qa-device-token-only';
  int permissionRequests = 0;
  int tokenRequests = 0;

  @override
  Stream<void> get foregroundMessages => messages.stream;

  @override
  Future<String?> getRegistrationToken() async {
    tokenRequests++;
    return token;
  }

  @override
  Future<QaPushPermission> requestPermission() async {
    permissionRequests++;
    return permission;
  }
}

void main() {
  test(
    'device-only tool is limited to configured native staging debug builds',
    () {
      bool allowed({
        bool debug = true,
        bool web = false,
        String environment = 'staging',
        bool configured = true,
      }) => canUseQaDevicePushTool(
        debugMode: debug,
        isWeb: web,
        appEnvironment: environment,
        firebaseConfigured: configured,
      );

      expect(allowed(), isTrue);
      expect(allowed(debug: false), isFalse);
      expect(allowed(web: true), isFalse);
      expect(allowed(environment: 'production'), isFalse);
      expect(allowed(configured: false), isFalse);
    },
  );

  for (final language in ['ar', 'en']) {
    testWidgets(
      'device-only test prepares and copies its own token ($language)',
      (tester) async {
        final gateway = FakeQaPushGateway();
        String? copied;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: QaDevicePushTestScreen(
              gateway: gateway,
              copyToken: (value) async => copied = value,
            ),
          ),
        );
        expect(
          find.text(
            language == 'ar'
                ? 'لا يحتاج هذا الاختبار إلى حساب عميل، ولا يحفظ الرمز في Supabase ولا يربطه بأي حساب. الرمز يخص تثبيت هذا التطبيق على هذا الجهاز فقط.'
                : 'This test needs no customer account. It does not save the token to Supabase or link it to an account. The token is for this app installation on this device only.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(gateway.permissionRequests, 1);
        expect(gateway.tokenRequests, 1);
        expect(find.text('qa-device-token-only'), findsOneWidget);
        await tester.tap(find.byType(OutlinedButton));
        await tester.pumpAndSettle();
        expect(copied, 'qa-device-token-only');
        gateway.messages.add(null);
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'ar'
                ? 'استقبل التطبيق 1 إشعارًا أثناء فتحه.'
                : 'The app received 1 notification(s) while open.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await gateway.messages.close();
      },
    );
  }

  testWidgets('denied notification permission never requests a token', (
    tester,
  ) async {
    final gateway = FakeQaPushGateway()..permission = QaPushPermission.denied;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: QaDevicePushTestScreen(gateway: gateway),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(gateway.tokenRequests, 0);
    expect(
      find.textContaining('Notifications are not allowed'),
      findsOneWidget,
    );
    expect(find.text('qa-device-token-only'), findsNothing);
    await gateway.messages.close();
  });
}
