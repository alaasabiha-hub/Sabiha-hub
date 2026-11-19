import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cashier_checkout_test.dart' as base;

class VisitsCheckoutGateway extends base.CheckoutGateway {
  VisitsCheckoutGateway({this.approved = true});
  final bool approved;
  bool released = false;
  final visitIssues = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_mixed_points_context') return {'enabled': false};
    if (name == 'get_cashier_mixed_visits_context') {
      return {
        'enabled': true,
        'redemption_enabled': true,
        'state': 'ready',
        'draft_version': 1,
        'binding_version': 2,
        if (!released)
          'hold': {
            'group_id': 'held-visits',
            'fingerprint': 'exact-visits',
            'balance_reserved': true,
            'reservation_live': true,
            'required_visits': 3,
            'payment_confirmed': false,
            'quote': {
              'visit_reward': {'payable_reduction': 120},
              'total': 0,
            },
            'verbal_notice_ar': 'موافقة شفهية',
            'verbal_notice_en': 'Verbal approval',
          },
        if (!released && approved)
          'approval': {'group_id': 'held-visits', 'consent_id': 'verbal-visit'},
        'options': [],
        'documents': [],
      };
    }
    if (name == 'issue_cashier_visit_invoice') {
      visitIssues.add(Map.from(params));
      return super.call('issue_cashier_mixed_invoice', params);
    }
    if (name == 'release_cashier_mixed_visits') {
      released = true;
      return {'released': true};
    }
    final result = await super.call(name, params);
    if (name == 'get_cashier_checkout_state' && result['invoice'] is Map) {
      result['invoice'] = {
        ...Map<String, dynamic>.from(result['invoice'] as Map),
        'total': 0,
        'payable': 0,
        'net_collected': 0,
        'payment_status': 'covered_by_reward',
        'payment_method': 'reward_coverage',
        'collection_required': false,
        'cash_confirmed': false,
      };
      result['refundable_lines'] = [];
    }
    return result;
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets(
      'Recovered visits route zero checkout without cash $language',
      (t) async {
        final g = VisitsCheckoutGateway();
        await base.mount(
          t,
          g,
          language,
          language == 'ar' ? 390 : 1440,
          services: true,
        );
        await base.press(t, 'checkout_issue');
        expect(g.visitIssues.single['p_group'], 'held-visits');
        expect(g.visitIssues.single['p_consent'], 'verbal-visit');
        expect(g.visitIssues.single.containsKey('p_reservation'), false);
        expect(g.paid, false);
        expect(find.byKey(const ValueKey('checkout_cash')), findsNothing);
        expect(find.byKey(const ValueKey('checkout_terminal')), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Unapproved visit selection blocks ordinary issue until explicit release',
    (t) async {
      final g = VisitsCheckoutGateway(approved: false);
      await base.mount(t, g, 'en', 390, services: true);
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('checkout_issue')))
            .onPressed,
        isNull,
      );
      final release = find.text('Cancel redemption before invoice issuance');
      await t.ensureVisible(release);
      await t.tap(release);
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('checkout_issue')))
            .onPressed,
        isNotNull,
      );
      expect(g.visitIssues, isEmpty);
      expect(g.paid, false);
      expect(t.takeException(), isNull);
    },
  );
}
