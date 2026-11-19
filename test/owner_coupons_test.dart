import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_coupons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeCoupons extends OwnerCouponGateway {
  bool session = true;
  final saved = <Map<String, dynamic>>[];
  @override
  bool get current => session;
  @override
  Future<String> defaultBranch() async => 'qa-branch';
  @override
  Future<List<Map<String, dynamic>>> services(String branch) async => [
    {'item_id': 'service-a', 'name': 'Actual wash', 'item_type': 'service'},
  ];
  @override
  Future<List<Map<String, dynamic>>> coupons(String branch) async => [];
  @override
  Future<void> save({
    String? couponId,
    required Map<String, dynamic> values,
  }) async {
    if (!session) throw StateError('Session changed');
    saved.add(Map.of(values));
  }
}

SupabaseClient client() => SupabaseClient(
  'http://localhost:54321',
  'test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('owner coupon creation validates and localizes $lang', (
      tester,
    ) async {
      final fake = FakeCoupons();
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: OwnerCouponsScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(lang == 'ar' ? 'إنشاء كوبون' : 'Create coupon'),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'wash10');
      await tester.enterText(fields.at(1), 'Wash offer');
      await tester.enterText(fields.at(3), '10');
      await tester.enterText(fields.at(5), '100');
      await tester.enterText(fields.at(7), '1');
      await tester.tap(find.text(lang == 'ar' ? 'حفظ' : 'Save'));
      await tester.pumpAndSettle();
      expect(fake.saved, hasLength(1));
      expect(fake.saved.single['code'], 'WASH10');
      expect(fake.saved.single['discount_type'], 'percentage');
      expect(fake.saved.single['discount_value'], 10);
      expect(fake.saved.single['minimum_subtotal'], 100);
      expect(fake.saved.single['per_customer_limit'], 1);
      expect(fake.saved.single['branch_id'], 'qa-branch');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('percentage is capped at 100 and invalid coupon is not saved', (
    tester,
  ) async {
    final fake = FakeCoupons();
    await tester.pumpWidget(
      MaterialApp(
        home: OwnerCouponsScreen(client: client(), gateway: fake),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create coupon'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'TOOMUCH');
    await tester.enterText(fields.at(1), 'Invalid offer');
    await tester.enterText(fields.at(3), '120');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Check the code, value and usage limits.'),
      findsOneWidget,
    );
    expect(fake.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
