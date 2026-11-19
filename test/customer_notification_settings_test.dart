import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_notification_settings.dart';

class FakeNotificationGateway implements CustomerNotificationSettingsGateway {
  CustomerPushPermission currentPermission;
  CustomerNotificationPreferences stored;
  int settingsOpened = 0;
  int syncCalls = 0;
  int requests = 0;
  final List<CustomerNotificationPreferences> saves = [];

  FakeNotificationGateway({
    this.currentPermission = CustomerPushPermission.notDetermined,
    this.stored = const CustomerNotificationPreferences.defaults(),
  });

  @override
  Future<CustomerPushPermission> permission() async => currentPermission;

  @override
  Future<CustomerPushPermission> requestPermission() async {
    requests++;
    currentPermission = CustomerPushPermission.authorized;
    return currentPermission;
  }

  @override
  Future<void> openSystemSettings() async => settingsOpened++;

  @override
  Future<void> synchronizePermission(CustomerPushPermission permission) async {
    syncCalls++;
  }

  @override
  Future<CustomerNotificationPreferences> loadPreferences() async => stored;

  @override
  Future<void> savePreferences(
    CustomerNotificationPreferences preferences,
  ) async {
    saves.add(preferences);
    stored = preferences.copyWith(saved: true);
  }
}

Widget settingsHarness(FakeNotificationGateway gateway, String locale) =>
    MaterialApp(
      locale: Locale(locale),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: ListView(
          children: [CustomerNotificationSettingsPanel(gateway: gateway)],
        ),
      ),
    );

void main() {
  testWidgets('permission request defaults operational only, not marketing', (
    tester,
  ) async {
    final gateway = FakeNotificationGateway();
    await tester.pumpWidget(settingsHarness(gateway, 'ar'));
    await tester.pumpAndSettle();

    expect(find.text('إعدادات الإشعارات'), findsOneWidget);
    await tester.tap(find.text('طلب إذن إشعارات الهاتف'));
    await tester.pumpAndSettle();

    expect(gateway.requests, 1);
    expect(gateway.saves, hasLength(1));
    expect(gateway.saves.single.operationalPush, isTrue);
    expect(gateway.saves.single.marketingPush, isFalse);
  });

  testWidgets(
    'denied permission links to phone settings, never claims override',
    (tester) async {
      final gateway = FakeNotificationGateway(
        currentPermission: CustomerPushPermission.denied,
      );
      await tester.pumpWidget(settingsHarness(gateway, 'en'));
      await tester.pumpAndSettle();

      expect(find.text('Phone permission: Denied'), findsOneWidget);
      await tester.tap(find.text('Open app notification settings'));
      await tester.pumpAndSettle();
      expect(gateway.settingsOpened, 1);
      expect(gateway.requests, 0);
    },
  );

  testWidgets('marketing push remains opt-in and requires system consent', (
    tester,
  ) async {
    final gateway = FakeNotificationGateway(
      currentPermission: CustomerPushPermission.authorized,
    );
    await tester.pumpWidget(settingsHarness(gateway, 'en'));
    await tester.pumpAndSettle();

    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switches.first.value, isTrue);
    expect(switches.last.value, isFalse);
    await tester.tap(find.text('Marketing push notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save notification settings'));
    await tester.pumpAndSettle();

    expect(gateway.saves.single.marketingPush, isTrue);
  });
}
