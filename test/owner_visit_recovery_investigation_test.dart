import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_visit_recovery.dart';
import 'package:sabiha_hub/owner_visit_recovery_investigation.dart';

import 'owner_visit_recovery_test.dart' as owner;
import 'visit_recovery_request_test.dart' as auth;

const caseId = '11111111-1111-4111-8111-111111111110';
const profileA = '22222222-2222-4222-8222-222222222222';
const profileB = '33333333-3333-4333-8333-333333333333';
Map<String, dynamic> candidate([String id = profileA]) => {
  'profile_reference': id,
  'name': 'Actual reception record',
  'created_at': '2026-11-15T00:00:00Z',
  'branch': {
    'branch_id': 'branch',
    'name_ar': 'فرع الاستقبال الفعلي',
    'name_en': 'Actual reception branch',
  },
  'contacts': [
    {'phone': '+201000000000', 'verification': 'observed_unverified'},
  ],
  'cars': [
    {
      'car_reference': 'car',
      'plate_number': 'ABC123',
      'brand': 'Actual brand',
      'model': 'Model',
      'year': 2024,
      'color': 'Blue',
    },
  ],
  'contacts_truncated': false,
  'cars_truncated': false,
  'real_receipt_available': true,
  'receipt_ever_linked': false,
  'active_profile_link': false,
  'active_requester_link': false,
  'independent_proof_required': true,
  'candidate_is_identity_proof': false,
  'proposal_enabled': false,
  'linking_enabled': false,
};
Map<String, dynamic> result(
  Map<String, dynamic> p, {
  List<Map<String, dynamic>>? rows,
}) => {
  'query_id': p['p_query'],
  'case_id': p['p_case'] ?? caseId,
  'checked_at': '2026-11-15T00:00:00Z',
  'searched_at': '2026-11-15T00:00:00Z',
  'criterion_kind': p['p_plate'] == null ? 'registered_phone' : 'exact_plate',
  'limit': 10,
  'has_more': true,
  'candidates': rows ?? [candidate()],
  'candidate_count': rows?.length ?? 1,
  'candidate_is_identity_proof': false,
  'proposal_enabled': false,
  'linking_enabled': false,
};
Map<String, dynamic> detail(Map<String, dynamic> p) => {
  'request_id': p['p_request'],
  'query_id': p['p_query'],
  'case_id': caseId,
  'checked_at': '2026-11-15T00:00:00Z',
  'candidate': candidate(p['p_profile'] as String),
  'candidate_is_identity_proof': false,
  'proposal_enabled': false,
  'linking_enabled': false,
};

void main() {
  test('audited exact case search and explicit selected detail retry stable nonces without linking APIs', () async {
    final api = owner.Gateway();
    var searches = 0, details = 0;
    api.handler = (name, p) async {
      if (name == 'search_visit_recovery_candidates') {
        if (++searches == 1) throw StateError('Lost read response');
        return result(p);
      }
      expect(name, 'get_visit_recovery_candidate');
      if (++details == 1) throw StateError('Lost detail response');
      return detail(p);
    };
    final c = VisitRecoveryInvestigationController(
      gateway: api,
      actorId: () => 'owner',
      caseId: caseId,
    );
    addTearDown(c.dispose);
    c.configure('short', '');
    await c.search();
    expect(api.calls, isEmpty);
    c.configure('Actual independent review purpose', '');
    await c.search();
    expect(c.error, isNotNull);
    await c.search();
    expect(api.calls[0].$2, api.calls[1].$2);
    expect(api.calls[1].$2, {
      'p_query': c.queryId,
      'p_case': caseId,
      'p_purpose': 'Actual independent review purpose',
      'p_plate': null,
      'p_limit': 10,
    });
    expect(c.detail, isNull);
    await c.select('not-a-returned-candidate');
    expect(api.calls, hasLength(2));
    await c.select(profileA);
    await c.select(profileA);
    expect(api.calls[2].$2, api.calls[3].$2);
    expect(c.detail!['profile_reference'], profileA);
    expect(api.calls.map((call) => call.$1).toSet(), {
      'search_visit_recovery_candidates',
      'get_visit_recovery_candidate',
    });
  });

  test('case and criteria changes clear private results and late selection/query responses; Auth invalidates', () async {
    final api = owner.Gateway();
    final pending = Completer<dynamic>();
    api.handler = (_, p) async => await pending.future;
    final c = VisitRecoveryInvestigationController(
      gateway: api,
      actorId: () => 'owner',
      caseId: caseId,
    );
    addTearDown(c.dispose);
    c.configure('Actual case investigation', 'ABC123');
    final searching = c.search();
    final old = Map<String, dynamic>.from(api.calls.single.$2);
    c.configure('Changed exact investigation purpose', 'OTHER456');
    pending.complete(result(old));
    await searching;
    expect(c.result, isNull);
    expect(c.queryId, isNull);
    api.handler = (name, p) async =>
        result(p, rows: [candidate(), candidate(profileB)]);
    await c.search();
    final selected = Completer<dynamic>();
    api.handler = (_, p) async => await selected.future;
    final selecting = c.select(profileA);
    final oldDetail = Map<String, dynamic>.from(api.calls.last.$2);
    c.changeCase('other-case');
    expect(c.candidates, isEmpty);
    expect(c.detail, isNull);
    selected.complete(detail(oldDetail));
    await selecting;
    expect(c.detail, isNull);
    expect(c.purpose, isEmpty);
    c.invalidate();
    c.configure('Should remain unauthorized', '');
    await c.search();
    expect(c.invalid, true);
    expect(c.result, isNull);
    expect(api.calls, hasLength(3));
  });

  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'owner investigation ${config.$1} ${config.$2} explicit selection, disclosure and query clearing fit',
      (t) async {
        final client = await auth.client(t), api = owner.Gateway();
        api.handler = (name, p) async =>
            name == 'search_visit_recovery_candidates' ? result(p) : detail(p);
        t.view.physicalSize = Size(config.$2, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(config.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: VisitRecoveryInvestigationScreen(
              client: client,
              caseId: caseId,
              gateway: api,
            ),
          ),
        );
        expect(api.calls, isEmpty);
        expect(
          t
              .widget<FilledButton>(
                find.byKey(const ValueKey('investigation-search')),
              )
              .onPressed,
          isNull,
        );
        await t.enterText(
          find.byKey(const ValueKey('investigation-purpose')),
          'Explicit case review purpose',
        );
        await t.enterText(
          find.byKey(const ValueKey('investigation-plate')),
          'ABC123',
        );
        await t.ensureVisible(
          find.byKey(const ValueKey('investigation-search')),
        );
        await t.tap(find.byKey(const ValueKey('investigation-search')));
        await t.pumpAndSettle();
        expect(api.calls.single.$2['p_plate'], 'ABC123');
        expect(
          find.byKey(const ValueKey('investigation-detail')),
          findsNothing,
        );
        final pick = find.byKey(
          const ValueKey('investigation-select-$profileA'),
        );
        await t.ensureVisible(pick);
        await t.tap(pick);
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('investigation-detail')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            config.$1 == 'ar' ? 'الملكية غير مثبتة' : 'ownership unverified',
          ),
          findsOneWidget,
        );
        await t.scrollUntilVisible(
          find.byKey(const ValueKey('investigation-no-link-note')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.byKey(const ValueKey('investigation-no-link-note')),
          findsOneWidget,
        );
        expect(
          api.calls.where(
            (call) => call.$1.contains('approve') || call.$1.contains('attach'),
          ),
          isEmpty,
        );
        await t.scrollUntilVisible(
          find.byKey(const ValueKey('investigation-plate')),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await t.enterText(
          find.byKey(const ValueKey('investigation-plate')),
          'CHANGED',
        );
        await t.pump();
        expect(
          find.byKey(const ValueKey('investigation-detail')),
          findsNothing,
        );
        expect(find.text('Actual reception record'), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Auth change clears investigation purpose and rejects late private response',
    (t) async {
      final client = await auth.client(t), api = owner.Gateway();
      final pending = Completer<dynamic>();
      api.handler = (_, p) async => await pending.future;
      await t.pumpWidget(
        MaterialApp(
          home: VisitRecoveryInvestigationScreen(
            client: client,
            caseId: caseId,
            gateway: api,
          ),
        ),
      );
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      );
      await t.pump();
      await t.enterText(
        find.byKey(const ValueKey('investigation-purpose')),
        'Explicit audit purpose',
      );
      await t.pump();
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('investigation-search')),
            )
            .onPressed,
        isNotNull,
      );
      await t.ensureVisible(find.byKey(const ValueKey('investigation-search')));
      await t.tap(find.byKey(const ValueKey('investigation-search')));
      await t.pump();
      final original = Map<String, dynamic>.from(api.calls.single.$2);
      client.testAuth.user = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await t.pump();
      pending.complete(result(original));
      await t.pumpAndSettle();
      expect(find.text('Actual reception record'), findsNothing);
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('investigation-purpose')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('investigation-search')),
            )
            .onPressed,
        isNull,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'only active unmapped current case offers investigation and passes exact case to route',
    (t) async {
      final client = await auth.client(t), api = owner.Gateway();
      api.handler = (name, p) async {
        expect(name, 'list_visit_recovery_requests');
        return {
          'items': [
            {...owner.item(), 'case_id': caseId},
            {...owner.item(mapped: true), 'case_id': 'mapped'},
            {...owner.item(), 'case_id': 'terminal', 'status': 'rejected'},
            {...owner.item(), 'case_id': 'stale', 'identity_current': false},
          ],
          'next_cursor': null,
        };
      };
      await t.pumpWidget(
        MaterialApp(
          home: OwnerVisitRecoveryScreen(
            client: client,
            gateway: api,
            store: owner.Store(),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('investigation-open-$caseId')),
        findsOneWidget,
      );
      for (final id in ['mapped', 'terminal', 'stale']) {
        expect(find.byKey(ValueKey('investigation-open-$id')), findsNothing);
      }
      final button = find.byKey(const ValueKey('investigation-open-$caseId'));
      await t.ensureVisible(button);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(
        t
            .widget<VisitRecoveryInvestigationScreen>(
              find.byType(VisitRecoveryInvestigationScreen),
            )
            .caseId,
        caseId,
      );
      expect(
        api.calls.every((call) => call.$1 == 'list_visit_recovery_requests'),
        true,
      );
      expect(t.takeException(), isNull);
    },
  );
}
