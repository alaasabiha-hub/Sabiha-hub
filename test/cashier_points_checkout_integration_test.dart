import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cashier_checkout_test.dart' as base;

class PointsCheckoutGateway extends base.CheckoutGateway {
  PointsCheckoutGateway({this.approved = true});
  final bool approved;
  final pointIssues = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'get_cashier_mixed_points_context') {
      return {
        'enabled': true,
        'state': 'ready',
        'draft_version': 1,
        'binding_version': 2,
        'intent_id': 'intent',
        'hold': {
          'reservation_id': 'held',
          'fingerprint': 'exact',
          'quote': {
            'loyalty_points': 10,
            'loyalty_payable_reduction': 20,
            'total': 94,
          },
          'balance_reserved': true,
          'payment_confirmed': false,
          'verbal_notice_ar': 'موافقة شفهية',
          'verbal_notice_en': 'Verbal approval',
        },
        if (approved)
          'approval': {'reservation_id': 'held', 'consent_id': 'verbal'},
        'buckets': [],
        'documents': [],
      };
    }
    if (name == 'issue_cashier_points_invoice') {
      pointIssues.add(Map.from(params));
      return super.call('issue_cashier_mixed_invoice', params);
    }
    if (name == 'release_cashier_mixed_points') return {'released': true};
    return super.call(name, params);
  }
}

void main() {
  testWidgets(
    'Recovered verbal approval routes actual checkout to funded issuer, cash separate',
    (t) async {
      final g = PointsCheckoutGateway();
      await base.mount(t, g, 'ar', 390, services: true);
      expect(find.textContaining('سُجلت الموافقة'), findsOneWidget);
      await base.press(t, 'checkout_issue');
      expect(g.pointIssues.length, 1);
      expect(g.pointIssues.single['p_reservation'], 'held');
      expect(g.pointIssues.single['p_consent'], 'verbal');
      expect(g.pointIssues.single['p_start'], '2026-11-15T10:10:00Z');
      expect(
        g.pointIssues.single.containsKey('p_expected_binding_version'),
        false,
      );
      expect(g.paid, false);
      await base.press(t, 'checkout_cash');
      expect(g.paid, true);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'Recovered unapproved hold blocks ordinary checkout until explicitly released',
    (t) async {
      final g = PointsCheckoutGateway(approved: false);
      await base.mount(t, g, 'en', 1440, services: true);
      final issue = find.byKey(const ValueKey('checkout_issue'));
      expect(t.widget<FilledButton>(issue).onPressed, isNull);
      final release = find.text('Cancel redemption before invoice issuance');
      await t.ensureVisible(release);
      await t.tap(release);
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(issue).onPressed, isNotNull);
      expect(g.pointIssues, isEmpty);
      expect(g.paid, false);
      expect(t.takeException(), isNull);
    },
  );
}
