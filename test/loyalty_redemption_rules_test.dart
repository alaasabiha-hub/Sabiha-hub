import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/loyalty_redemption_rules.dart';

class FakeRules extends RedemptionRulesGateway {
  bool denied = false, noReward = false, stale = false, timeoutOnce = false;
  int reads = 0;
  final saves = <Map<String, dynamic>>[];
  Map<String, dynamic>? current;
  Map<String, dynamic> context() => {
    'policy_version_id': 'policy-actual',
    'branch_id': 'branch-actual',
    'offer_id': 'offer-actual',
    'policy_version_no': 8,
    'threshold_visits': 6,
    'reward_service': noReward
        ? null
        : {
            'id': 'service-actual',
            'name': 'Actual reward service',
            'is_active': true,
            'is_public': true,
          },
    'offer': {
      'name': 'Actual visit offer',
      'starts_at': null,
      'ends_at': null,
      'current_is_active': true,
      'current_is_public': true,
    },
    'current': current,
    'history': [],
    'rules_saved': current != null,
    'terms_valid': current != null,
    'redemption_enabled': false,
    'blockers': [
      if (current == null) 'redemption_rules_not_saved',
      'booking_redemption_not_implemented',
    ],
    'supported_rules': {
      'pooling': ['policy_version', 'offer_branch'],
      'expiry': ['no_expiry', 'snapshot_offer_end'],
      'cancellation': ['restore_visits', 'forfeit_visits'],
      'refunded_contribution': [
        'offset_future_visits',
        'freeze_for_owner_review',
      ],
    },
  };
  @override
  Future<Map<String, dynamic>> read(String policyVersion) async {
    reads++;
    if (denied) {
      throw const PostgrestException(message: 'Denied', code: '42501');
    }
    return context();
  }

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> inputs) async {
    saves.add(inputs);
    if (stale) {
      stale = false;
      throw const PostgrestException(message: 'Changed', code: '40001');
    }
    if (timeoutOnce) {
      timeoutOnce = false;
      throw TimeoutException('Uncertain response');
    }
    current = {
      'rules_version_id': inputs['p_request'],
      'version_no': 1,
      'rules': inputs['p_rules'],
      'created_at': '2026-11-14T12:00:00Z',
    };
    return context();
  }
}

class ActivationRules extends FakeRules {
  ActivationRules() {
    current = {
      'rules_version_id': 'actual-rules',
      'version_no': 3,
      'created_at': '2026-11-14T10:00:00Z',
      'rules': {
        'pooling': 'policy_version',
        'expiry': 'no_expiry',
        'cancellation': 'restore_visits',
        'refunded_contribution': 'offset_future_visits',
      },
    };
  }
  bool ready = true, active = false;
  final activations = <String>[];
  @override
  bool get activationAvailable => true;
  @override
  Map<String, dynamic> context() => {
    ...super.context(),
    'configuration_valid': true,
    'terms_valid': true,
    'current_rules_activated': active,
    'redemption_enabled': active,
    'blockers': ready ? <String>[] : ['booking_redemption_not_implemented'],
    'backend_readiness': {
      for (final key in [
        'quote_implemented',
        'booking_implemented',
        'allocation_implemented',
        'consumption_implemented',
        'release_implemented',
        'refund_resolution_implemented',
        'earning_rules_binding_implemented',
        'readers_integrated',
      ])
        key: ready,
    },
  };
  @override
  Future<void> activate(String request, String rules) async {
    activations.add(rules);
    active = true;
  }
}

void main() {
  Future<void> open(
    WidgetTester t,
    FakeRules api, {
    String locale = 'en',
    double width = 1440,
  }) async {
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: OwnerRedemptionRulesPanel(
                  gateway: api,
                  policyVersion: 'policy-actual',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> select(WidgetTester t, String field, String text) async {
    final finder = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          (w.key as ValueKey?)?.value.toString().endsWith('-$field') == true,
    );
    await t.ensureVisible(finder);
    await t.tap(finder);
    await t.pumpAndSettle();
    await t.tap(find.text(text).last);
    await t.pumpAndSettle();
  }

  Future<void> chooseAll(WidgetTester t, bool ar) async {
    await select(
      t,
      'pooling',
      ar ? 'نفس إصدار السياسة فقط' : 'Same policy version only',
    );
    await select(t, 'expiry', ar ? 'دون انتهاء صلاحية' : 'No expiry');
    await select(
      t,
      'cancellation',
      ar ? 'إعادة الزيارات إلى الرصيد' : 'Restore visits to the balance',
    );
    await select(
      t,
      'refunded_contribution',
      ar
          ? 'احترام المكافأة وخصم الأثر من الزيارات المستقبلية'
          : 'Honor reward; offset future visits',
    );
  }

  Future<void> save(WidgetTester t, bool ar) async {
    final finder = find.text(
      ar ? 'حفظ إصدار شروط مستقبلي' : 'Save future terms version',
    );
    await t.ensureVisible(finder);
    await t.tap(finder);
    await t.pumpAndSettle();
  }

  for (final sample in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'Explicit future rules ${sample.$1} ${sample.$2} never enable redemption',
      (t) async {
        final api = FakeRules();
        if (sample.$1 == 'en') {
          api.current = {
            'rules_version_id': 'previous-rules-version',
            'version_no': 2,
            'created_at': '2026-11-14T12:00:00Z',
            'rules': {
              'pooling': 'offer_branch',
              'expiry': 'no_expiry',
              'cancellation': 'forfeit_visits',
              'refunded_contribution': 'freeze_for_owner_review',
            },
          };
        }
        await open(t, api, locale: sample.$1, width: sample.$2);
        final fields = t
            .widgetList<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .toList();
        expect(fields, hasLength(4));
        expect(fields.every((f) => f.initialValue == null), isTrue);
        expect(find.textContaining('Actual reward service'), findsOneWidget);
        final button = t.widget<FilledButton>(find.byType(FilledButton));
        expect(button.onPressed, isNull);
        expect(find.byType(SwitchListTile), findsNothing);
        await chooseAll(t, sample.$1 == 'ar');
        await save(t, sample.$1 == 'ar');
        expect(api.saves, hasLength(1));
        expect(api.saves.single['p_policy_version'], 'policy-actual');
        expect(
          api.saves.single['p_expected_rules_version'],
          sample.$1 == 'ar' ? null : 'previous-rules-version',
        );
        expect(api.saves.single['p_rules'], {
          'pooling': 'policy_version',
          'expiry': 'no_expiry',
          'cancellation': 'restore_visits',
          'refunded_contribution': 'offset_future_visits',
        });
        expect(
          api.saves.single.keys,
          unorderedEquals([
            'p_request',
            'p_policy_version',
            'p_expected_rules_version',
            'p_rules',
          ]),
        );
        expect(
          '${api.saves.single['p_request']}',
          matches(RegExp(r'^[0-9a-f-]{36}$')),
        );
        expect(
          find.textContaining(
            sample.$1 == 'ar'
                ? 'الاستبدال الفعلي معطل'
                : 'Actual redemption is disabled',
          ),
          findsOneWidget,
        );
        expect(api.context()['redemption_enabled'], isFalse);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('Owner denial never exposes choices', (t) async {
    final api = FakeRules()..denied = true;
    await open(t, api);
    expect(find.text('These rules require owner access.'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });
  testWidgets('Missing actual reward service cannot save future rules', (
    t,
  ) async {
    final api = FakeRules()..noReward = true;
    await open(t, api);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(
      find.textContaining(
        'A new version requires an actual active published reward service',
      ),
      findsOneWidget,
    );
  });
  testWidgets(
    'Stale rule version reloads and requires explicit choices again',
    (t) async {
      final api = FakeRules()..stale = true;
      await open(t, api);
      await chooseAll(t, false);
      await save(t, false);
      expect(api.reads, 2);
      expect(find.textContaining('Context reloaded'), findsOneWidget);
      expect(
        t
            .widgetList<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .every((f) => f.initialValue == null),
        isTrue,
      );
    },
  );
  testWidgets(
    'Uncertain save retries retain the same UUID and exact explicit rules',
    (t) async {
      final api = FakeRules()..timeoutOnce = true;
      await open(t, api);
      await chooseAll(t, false);
      await save(t, false);
      await save(t, false);
      expect(api.saves, hasLength(2));
      expect(api.saves[0], api.saves[1]);
    },
  );
  testWidgets(
    'Owner activation requires actual readiness and explicit confirmation',
    (t) async {
      final api = ActivationRules();
      await open(t, api);
      final start = find.text(
        'Review and activate redemption for this version',
      );
      await t.ensureVisible(start);
      await t.tap(start);
      await t.pumpAndSettle();
      expect(api.activations, isEmpty);
      await t.tap(find.text('Activate this version'));
      await t.pumpAndSettle();
      expect(api.activations, ['actual-rules']);
      expect(
        find.textContaining(
          'This version is activated for explicit reward booking',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'Missing backend readiness has no activation control and grouped explanation',
    (t) async {
      final api = ActivationRules()..ready = false;
      await open(t, api);
      expect(
        find.text('Review and activate redemption for this version'),
        findsNothing,
      );
      expect(
        find.textContaining('The actual flow is not complete'),
        findsOneWidget,
      );
    },
  );
}
