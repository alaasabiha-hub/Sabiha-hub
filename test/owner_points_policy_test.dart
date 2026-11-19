import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_points_policy.dart';

class OwnerGateway implements OwnerPointsGateway {
  bool live = true, loseAck = false;
  int version = 1;
  final events = StreamController<void>.broadcast(sync: true);
  final saves = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? wait;
  @override
  bool get current => live;
  @override
  Stream<void> get changes => events.stream;
  Map<String, dynamic> rules = {
    'unit': 'reward_points_v1',
    'point_value_basis': 'gross_payable',
    'point_value_egp': 1,
    'minimum_points': 10,
    'maximum_points': 100,
    'minimum_invoice_egp': 100,
    'maximum_discount_egp': 50,
    'maximum_discount_percent': 30,
    'allow_walk_in': true,
    'allow_booking': true,
    'allow_coupon': false,
    'allow_offer': false,
    'allow_manual_discount': false,
    'eligible_item_ids': ['service', 'product'],
    'earning_rates': [
      {'item_id': 'service', 'points_per_completed_unit': 10},
    ],
    'cancellation': 'restore_points',
    'refunded_contribution': 'offset_future_points',
  };
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_owner_mixed_points_operations') {
      return {
        'activation_supported': false,
        'verbal_policy': {'version': 0, 'allowed': false},
        'reviews': [],
        'has_more': false,
        'redemption_runtime_enabled': false,
      };
    }
    if (name == 'get_owner_mixed_points_policy') {
      return {
        'version': version,
        'current': {'rules': rules},
        'history': [],
        'catalog': [
          {
            'item_id': 'service',
            'item_type': 'service',
            'name': 'خدمة اختبار',
            'name_en': 'QA service',
          },
          {
            'item_id': 'product',
            'item_type': 'product',
            'name': 'منتج اختبار',
            'name_en': 'QA product',
          },
        ],
        'earning_enabled': false,
        'redemption_enabled': false,
        'legacy_balance_conversion_supported': false,
      };
    }
    saves.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(params))));
    if (wait != null) return wait!.future;
    if (loseAck) {
      loseAck = false;
      throw TimeoutException('Uncertain policy save');
    }
    rules = Map<String, dynamic>.from(params['p_rules']);
    version++;
    return {
      'version': version,
      'future_rules_saved': true,
      'earning_enabled': false,
      'redemption_enabled': false,
      'legacy_balances_imported': false,
    };
  }
}

Future<void> mount(
  WidgetTester tester,
  OwnerGateway g,
  String lang,
  double width,
) async {
  await tester.binding.setSurfaceSize(Size(width, 1200));
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: OwnerPointsPolicyPanel(gateway: g, branch: 'qa-branch'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> near(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1024.0, 1440.0]) {
      testWidgets(
        'Explicit owner future terms $lang $width preserve layout and RTL/LTR',
        (tester) async {
          final g = OwnerGateway();
          await mount(tester, g, lang, width);
          expect(
            find.text(lang == 'ar' ? 'نسخة الشروط: 1' : 'Terms version: 1'),
            findsOneWidget,
          );
          expect(
            Directionality.of(
              tester.element(find.byType(OwnerPointsPolicyPanel)),
            ),
            lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          );
          expect(
            find.textContaining(lang == 'ar' ? 'لا يفعّل' : 'enables neither'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          final button = find.widgetWithText(
            FilledButton,
            lang == 'ar' ? 'حفظ الشروط المستقبلية' : 'Save future terms',
          );
          await near(tester, button);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await g.events.close();
          await tester.binding.setSurfaceSize(null);
        },
      );
    }
  }
  testWidgets(
    'Lost save response freezes input and retries the exact owner policy request',
    (tester) async {
      final g = OwnerGateway()..loseAck = true;
      await mount(tester, g, 'ar', 390);
      final reason = find.byKey(const ValueKey('points_reason'));
      await near(tester, reason);
      await tester.enterText(reason, 'QA future points explicit rules');
      final save = find.widgetWithText(FilledButton, 'حفظ الشروط المستقبلية');
      await near(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(g.saves.length, 1);
      expect(tester.widget<TextField>(reason).enabled, false);
      final retry = find.widgetWithText(FilledButton, 'إعادة محاولة نفس الحفظ');
      await near(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(g.saves.length, 2);
      expect(g.saves.first, g.saves.last);
      expect(g.saves.first['p_rules']['unit'], 'reward_points_v1');
      expect(g.saves.first.containsKey('enabled'), false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await g.events.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'Changing the owner account clears terms and prevents further saves',
    (tester) async {
      final g = OwnerGateway();
      await mount(tester, g, 'en', 390);
      g.live = false;
      g.events.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Sign in again to manage terms.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('points_point_value_egp')),
        findsNothing,
      );
      expect(g.saves, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await g.events.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
  for (final entry in [('ar', 'gross_payable'), ('en', 'pre_tax_base')]) {
    testWidgets(
      'Existing terms require explicit basis before saving ${entry.$1}',
      (tester) async {
        final g = OwnerGateway()..rules.remove('point_value_basis');
        await mount(tester, g, entry.$1, 390);
        final reason = find.byKey(const ValueKey('points_reason'));
        await near(tester, reason);
        await tester.enterText(
          reason,
          'QA owner explicitly chooses point basis',
        );
        final save = find.widgetWithText(
          FilledButton,
          entry.$1 == 'ar' ? 'حفظ الشروط المستقبلية' : 'Save future terms',
        );
        await near(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(g.saves, isEmpty);
        final basis = find.byKey(const ValueKey('points_value_basis'));
        await near(tester, basis);
        await tester.tap(basis);
        await tester.pumpAndSettle();
        final option = find
            .text(
              entry.$1 == 'ar'
                  ? 'خفض المبلغ النهائي الشامل'
                  : 'Discount the price before tax',
            )
            .last;
        await tester.tap(option);
        await tester.pumpAndSettle();
        await near(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(g.saves.single['p_rules']['point_value_basis'], entry.$2);
        expect(g.saves.single['p_rules']['unit'], 'reward_points_v1');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await g.events.close();
        await tester.binding.setSurfaceSize(null);
      },
    );
  }
}
