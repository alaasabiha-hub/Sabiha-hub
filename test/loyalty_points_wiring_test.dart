import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/loyalty_policy.dart';
import 'package:sabiha_hub/owner_points_policy.dart';

import 'loyalty_policy_test.dart' as legacy;
import 'owner_points_policy_test.dart' as points;

class Reader extends points.OwnerGateway {
  final branches = <Object?>[];
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params) {
    if (name == 'get_owner_mixed_points_policy') {
      branches.add(params['p_branch']);
    }
    return super.call(name, params);
  }
}

class WiredPolicy extends legacy.FakePolicy {
  final reader = Reader();
  @override
  OwnerPointsGateway get points => reader;
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets(
      'Existing owner loyalty route includes branch-scoped point terms $lang',
      (tester) async {
        final api = WiredPolicy(), client = legacy.client();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(lang),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: LoyaltyPolicyScreen(client: client, gateway: api),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(OwnerPointsPolicyPanel),
          400,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 25,
        );
        await tester.pumpAndSettle();
        debugPrint('OWNER_POINTS_PARENT_BOUNDARY_READY');
        expect(api.reader.branches, ['b1']);
        expect(api.reader.saves, isEmpty);
        expect(
          find.text(
            lang == 'ar'
                ? 'قواعد نقاط الولاء المستقبلية'
                : 'Future loyalty point terms',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await api.reader.events.close();
        // This unused SDK fixture spawns an isolate in fakeAsync; the test worker owns teardown.
      },
    );
  }
}
