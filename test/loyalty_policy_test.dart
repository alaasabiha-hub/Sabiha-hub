import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/loyalty_policy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakePolicy extends LoyaltyPolicyGateway {
  final saves = <Map<String, dynamic>>[];
  final offerSaves = <Map<String, dynamic>>[];
  bool noOffers = false;
  bool noServices = false;
  @override
  Future<void> saveOffer(Map<String, dynamic> inputs) async {
    offerSaves.add(Map.from(inputs));
  }

  @override
  Future<Map<String, dynamic>> read(String? branch) async => {
    'branch_id': 'b1',
    'current': null,
    'history': [],
    'branches': [
      {'id': 'b1', 'name_ar': 'فرع الاختبار', 'name_en': 'QA branch'},
    ],
    'offers': noOffers && offerSaves.isEmpty
        ? []
        : [
            {
              'id': 'o1',
              'name': 'Actual visit reward',
              'visits_required': 3,
              'branch_id': 'b1',
            },
          ],
    'services': noServices
        ? []
        : [
            {
              'id': 's1',
              'name': 'Actual service',
              'is_active': true,
              'is_public': true,
            },
          ],
  };
  @override
  Future<void> save(Map<String, dynamic> inputs) async {
    saves.add(Map.from(inputs));
  }
}

SupabaseClient client() => SupabaseClient(
  'http://localhost:54321',
  'test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);
void main() {
  testWidgets(
    'owner creates an actual draft without seed or default visit count',
    (tester) async {
      final fake = FakePolicy()..noOffers = true;
      await tester.pumpWidget(
        MaterialApp(
          home: LoyaltyPolicyScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create actual visit reward offer'));
      await tester.tap(find.text('Create actual visit reward offer'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, isEmpty);
      expect(tester.widget<TextField>(fields.at(2)).controller!.text, isEmpty);
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Publish this actual offer'),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.text('Save actual offer'));
      await tester.pumpAndSettle();
      expect(fake.offerSaves, isEmpty);
      await tester.enterText(fields.at(0), 'Owner supplied actual name');
      await tester.enterText(fields.at(2), '7');
      await tester.tap(find.text('Actual reward service'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actual service').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save actual offer'));
      await tester.pumpAndSettle();
      expect(fake.offerSaves.single['p_name'], 'Owner supplied actual name');
      expect(fake.offerSaves.single['p_visits'], 7);
      expect(fake.offerSaves.single['p_publish'], false);
      expect(fake.offerSaves.single['p_branch'], 'b1');
      expect(fake.offerSaves.single['p_reward_service'], 's1');
      expect(fake.saves, isEmpty);
    },
  );

  testWidgets(
    'missing actual branch service explains the empty list and opens catalog',
    (tester) async {
      final fake = FakePolicy()..noServices = true;
      await tester.pumpWidget(
        MaterialApp(
          home: LoyaltyPolicyScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create actual visit reward offer'));
      await tester.tap(find.text('Create actual visit reward offer'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('loyalty-reward-service-empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('loyalty-manage-services-from-offer')),
        findsOneWidget,
      );
      await tester.tap(find.text('Save actual offer'));
      await tester.pumpAndSettle();
      expect(fake.offerSaves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'absent configuration is inactive and cannot save invented service selection',
    (tester) async {
      final fake = FakePolicy();
      await tester.pumpWidget(
        MaterialApp(
          home: LoyaltyPolicyScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unit: service visits'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(fake.saves, isEmpty);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save new policy version'),
      );
      expect(button.onPressed, isNull);
      expect(
        find.textContaining(
          'Automatic earning and redemption are not connected yet.',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'saving sends explicit actual offer/service IDs and enabled state',
    (tester) async {
      final fake = FakePolicy();
      await tester.pumpWidget(
        MaterialApp(
          home: LoyaltyPolicyScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actual visit reward offer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actual visit reward · 3 visits').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Actual service'));
      await tester.tap(find.text('Actual service'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      final save = find.text('Save new policy version');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fake.saves.single['p_services'], ['s1']);
      expect(fake.saves.single['p_offer'], 'o1');
      expect(fake.saves.single['p_enabled'], true);
      expect(fake.saves.single['p_request'], isNotEmpty);
    },
  );
  testWidgets(
    'Arabic narrow policy labels have RTL layout without money conversion',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: LoyaltyPolicyScreen(client: client(), gateway: FakePolicy()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('الوحدة: زيارات خدمات'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('الوحدة: زيارات خدمات'))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
