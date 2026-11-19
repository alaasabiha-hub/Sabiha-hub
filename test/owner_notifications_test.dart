import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/notification_campaign_media.dart';
import 'package:sabiha_hub/owner_notifications.dart';

class CampaignGateway implements OwnerCampaignGateway {
  @override
  String? get actorId => 'qa-owner';
  final inserted = <Map<String, dynamic>>[];
  final updated = <Map<String, dynamic>>[];
  final offers = <Map<String, dynamic>>[
    {
      'offer_id': '11111111-1111-4111-8111-111111111111',
      'name': 'QA offer',
      'offer_type': 'percentage_discount',
      'is_active': true,
      'is_public': true,
    },
  ];
  final branches = <Map<String, dynamic>>[
    {
      'branch_id': '22222222-2222-4222-8222-222222222222',
      'name_ar': 'فرع الاختبار',
      'name_en': 'QA branch',
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> listCampaigns() async => [];
  @override
  Future<List<Map<String, dynamic>>> listOffers() async => offers;
  @override
  Future<List<Map<String, dynamic>>> listBranches() async => branches;
  @override
  Future<List<Map<String, dynamic>>> listRuns(String campaignId) async => [];
  @override
  Future<String> uploadImage(NotificationCampaignImage image) async =>
      'https://qa.example/campaign-image.${image.extension}';
  @override
  Future<void> insertCampaign(Map<String, dynamic> row) async =>
      inserted.add(Map<String, dynamic>.from(row));
  @override
  Future<void> updateCampaign(
    String campaignId,
    Map<String, dynamic> row,
  ) async => updated.add({'campaign_id': campaignId, ...row});
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('Owner campaign authoring $language $width', (tester) async {
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = CampaignGateway();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: OwnerNotificationsScreen(gateway: gateway),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          Directionality.of(
            tester.element(find.byType(OwnerNotificationsScreen)),
          ),
          language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        );
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'عرض جديد');
        await tester.enterText(fields.at(1), 'تفاصيل العرض');
        await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('QA offer · percentage_discount').last);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('campaign-schedule')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const ValueKey('campaign-schedule')));
        await tester.pumpAndSettle();
        expect(gateway.inserted, hasLength(1));
        expect(gateway.inserted.single['status'], 'scheduled');
        expect(gateway.inserted.single['target_segment'], {'type': 'all'});
        expect(gateway.inserted.single['created_by'], isNotNull);
        expect(gateway.inserted.single['scheduled_at'], isNotNull);
        expect(
          gateway.inserted.single['offer_id'],
          '11111111-1111-4111-8111-111111111111',
        );
        expect(
          find.textContaining(
            language == 'ar'
                ? 'بوابات التوصيل الخارجية والداخلية مغلقة'
                : 'Send now queues the campaign',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Invalid campaign deep links are rejected before saving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = CampaignGateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerNotificationsScreen(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Offer');
    await tester.enterText(fields.at(1), 'Message');
    await tester.enterText(fields.at(5), '/admin');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('campaign-save-draft')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('campaign-save-draft')));
    await tester.pumpAndSettle();
    expect(gateway.inserted, isEmpty);
    expect(find.textContaining('must open offers or booking'), findsOneWidget);
  });

  testWidgets('An unpublished offer cannot be scheduled', (tester) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = CampaignGateway();
    gateway.offers.single['is_public'] = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerNotificationsScreen(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Offer');
    await tester.enterText(fields.at(1), 'Message');
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('QA offer').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('campaign-schedule')));
    await tester.pumpAndSettle();
    expect(gateway.inserted, isEmpty);
    expect(find.textContaining('inactive or unpublished'), findsOneWidget);
  });

  testWidgets('Branch campaign requires and saves an active branch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = CampaignGateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerNotificationsScreen(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'إشعار الفرع');
    await tester.enterText(fields.at(1), 'نص تجريبي');
    final dropdowns = find.byType(DropdownButtonFormField<String>);
    await tester.tap(dropdowns.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عملاء فرع محدد').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('campaign-branch-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('فرع الاختبار').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('campaign-save-draft')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('campaign-save-draft')));
    await tester.pumpAndSettle();
    expect(gateway.inserted.single['target_segment'], {
      'type': 'branch',
      'branch_id': '22222222-2222-4222-8222-222222222222',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('Send now queues one due campaign without calling a sender', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = CampaignGateway();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: OwnerNotificationsScreen(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Immediate QA campaign');
    await tester.enterText(fields.at(1), 'Queued only');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('campaign-send-now')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('campaign-send-now')));
    await tester.pumpAndSettle();
    expect(gateway.inserted, hasLength(1));
    expect(gateway.inserted.single['status'], 'scheduled');
    expect(
      DateTime.parse('${gateway.inserted.single['scheduled_at']}')
          .isBefore(DateTime.now().add(const Duration(seconds: 5))),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
