import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_recovery_proposal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'owner_visit_recovery_test.dart' as fixture;
import 'visit_recovery_request_test.dart' as auth;

const caseId = '22222222-2222-4222-8222-222222222222';
const query = '33333333-3333-4333-8333-333333333333';
const profile = '44444444-4444-4444-8444-444444444444';
const original = OwnerProposalReference(
  '55555555-5555-4555-8555-555555555555',
  caseId,
  query,
  profile,
);

class Store implements OwnerProposalStore {
  OwnerProposalReference? value;
  bool fail = false;
  final trace = <String>[];
  @override
  Future<OwnerProposalReference?> read() async => value;
  @override
  Future<void> save(OwnerProposalReference ref) async {
    trace.add('save');
    if (fail) throw StateError('Lost storage');
    if (value != null) expect(value!.values, ref.values);
    value = ref;
  }

  @override
  Future<void> clear(OwnerProposalReference ref) async {
    expect(value!.values, ref.values);
    trace.add('clear');
    value = null;
  }
}

Map<String, dynamic> snapshot(
  OwnerProposalReference ref, [
  String state = 'open',
]) => {
  'proposal_id': ref.proposal,
  'state': state,
  if (!['absent', 'closed'].contains(state)) ...{
    'case_id': ref.caseId,
    'query_id': ref.query,
    'profile_reference': ref.profile,
    'link_created': false,
    'evidence_type': 'in_person_original_service_documents',
    'private_reason': 'Actual checked private evidence',
    'expires_at': '2026-11-16T00:00:00Z',
  },
};
OwnerRecoveryProposalController controller(
  Store s,
  fixture.Gateway api, {
  String q = query,
}) => OwnerRecoveryProposalController(
  gateway: api,
  store: s,
  actorId: () => 'owner',
  caseId: caseId,
  query: q,
  profile: profile,
  plate: 'ABC123',
);

Future<void> press(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await t.tap(target);
  await t.pumpAndSettle();
}

void main() {
  test('explicit evidence/reason/attestation persist tuple before exact prepare; open never acknowledged away', () async {
    final store = Store(), api = fixture.Gateway();
    api.handler = (name, p) async {
      store.trace.add(name);
      expect(store.value!.proposal, p['p_proposal']);
      return snapshot(store.value!);
    };
    final c = controller(store, api);
    addTearDown(c.dispose);
    await c.refresh();
    await c.prepare(null, 'Actual independent evidence', true);
    await c.prepare('in_person_original_service_documents', 'short', true);
    await c.prepare(
      'in_person_original_service_documents',
      'Actual independent evidence',
      false,
    );
    expect(api.calls, isEmpty);
    await c.prepare(
      'in_person_original_service_documents',
      'Actual independent evidence',
      true,
    );
    expect(store.trace, ['save', 'prepare_visit_recovery_proposal']);
    expect(api.calls.single.$2, {
      'p_proposal': store.value!.proposal,
      'p_query': query,
      'p_profile': profile,
      'p_evidence_type': 'in_person_original_service_documents',
      'p_reason': 'Actual independent evidence',
      'p_attested': true,
      'p_plate': 'ABC123',
    });
    expect(c.phase, 'open');
    expect(c.canAcknowledge, false);
    await c.acknowledge();
    expect(store.value, isNotNull);
  });

  test('lost prepare retries exact payload only in memory; restart absent freezes until close fence then ack', () async {
    final store = Store(), api = fixture.Gateway();
    var prepares = 0;
    api.handler = (name, p) async {
      if (name == 'prepare_visit_recovery_proposal') {
        prepares++;
        throw TimeoutException('Lost response');
      }
      return snapshot(
        store.value!,
        name == 'close_visit_recovery_proposal' ? 'closed' : 'absent',
      );
    };
    final first = controller(store, api);
    addTearDown(first.dispose);
    await first.refresh();
    await first.prepare(
      'in_person_independent_continuity_witness',
      'Independent witness verified in person',
      true,
    );
    await first.retry();
    expect(api.calls[0].$2, api.calls[1].$2);
    expect(prepares, 2);
    final saved = store.value!;
    final restart = controller(store, api);
    addTearDown(restart.dispose);
    await restart.refresh();
    expect(restart.phase, 'uncertain');
    expect(restart.canRetry, false);
    expect(restart.canPrepare, false);
    await restart.prepare(
      'in_person_original_service_documents',
      'New criteria cannot replace unknown',
      true,
    );
    expect(prepares, 2);
    expect(store.value!.values, saved.values);
    await restart.close();
    expect(restart.phase, 'closed');
    expect(store.value, isNotNull);
    await restart.acknowledge();
    expect(store.value, isNull);
    expect(restart.phase, 'acknowledged');
  });

  test('different query recovers original opaque receipt; expired/unavailable require close and creation wins close stays accepted', () async {
    final store = Store()..value = original, api = fixture.Gateway();
    var state = 'open';
    api.handler = (name, p) async => snapshot(original, state);
    final c = controller(store, api, q: '66666666-6666-4666-8666-666666666666');
    addTearDown(c.dispose);
    await c.refresh();
    expect(c.contextMatches, false);
    expect(c.receipt!.containsKey('private_reason'), false);
    expect(c.canPrepare, false);
    expect(c.canRetry, false);
    state = 'expired';
    await c.refresh();
    expect(c.canAcknowledge, false);
    expect(c.canClose, true);
    state = 'unavailable';
    await c.refresh();
    expect(c.canAcknowledge, false);
    state = 'accepted';
    await c.close();
    expect(c.phase, 'accepted');
    expect(c.canAcknowledge, true);
    expect(
      api.calls.every((call) => call.$2['p_proposal'] == original.proposal),
      true,
    );
    await c.acknowledge();
    expect(store.value, isNull);
  });

  test('save failure prevents server mutation and invalidation rejects late private snapshot while retaining tuple', () async {
    final store = Store()..fail = true, api = fixture.Gateway();
    final pending = Completer<dynamic>();
    api.handler = (_, p) async => await pending.future;
    final c = controller(store, api);
    addTearDown(c.dispose);
    await c.refresh();
    await c.prepare(
      'in_person_original_service_documents',
      'Actual original evidence verified',
      true,
    );
    final id = c.reference!.proposal;
    expect(api.calls, isEmpty);
    expect(c.canRetry, true);
    store.fail = false;
    final retry = c.retry();
    await Future<void>.delayed(Duration.zero);
    expect(store.value!.proposal, id);
    c.invalidate();
    pending.complete(snapshot(store.value!));
    await retry;
    expect(c.receipt, isNull);
    expect(c.reference, isNull);
    expect(c.invalid, true);
    expect(store.value!.proposal, id);
  });

  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'owner proposal ${config.$1} ${config.$2} has no defaults and requires actual independent attestation',
      (t) async {
        final client = await auth.client(t),
            store = Store(),
            api = fixture.Gateway();
        api.handler = (name, p) async {
          expect(name, 'prepare_visit_recovery_proposal');
          return snapshot(store.value!);
        };
        t.view.physicalSize = Size(config.$2, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(config.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: OwnerRecoveryProposalScreen(
              client: client,
              caseId: caseId,
              query: query,
              profile: profile,
              plate: 'ABC123',
              gateway: api,
              store: store,
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          t
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('owner-proposal-attestation')),
              )
              .value,
          false,
        );
        expect(
          t
              .widget<TextField>(
                find.byKey(const ValueKey('owner-proposal-reason')),
              )
              .controller!
              .text,
          isEmpty,
        );
        final action = find.byKey(const ValueKey('owner-proposal-prepare'));
        expect(t.widget<FilledButton>(action).onPressed, isNull);
        expect(
          find.byKey(const ValueKey('owner-proposal-acknowledge')),
          findsNothing,
        );
        await t.enterText(
          find.byKey(const ValueKey('owner-proposal-reason')),
          'Actual independent evidence verified in person',
        );
        await t.pump();
        await press(
          t,
          find.byKey(const ValueKey('owner-proposal-attestation')),
        );
        expect(t.widget<FilledButton>(action).onPressed, isNull);
        final drop = find.byType(DropdownButtonFormField<String>);
        await press(t, drop);
        final label = config.$1 == 'ar'
            ? 'مستندات الخدمة الأصلية بحضور العميل'
            : 'Original service documents presented in person';
        await press(t, find.text(label).last);
        expect(t.widget<FilledButton>(action).onPressed, isNotNull);
        await press(t, action);
        expect(api.calls, hasLength(1));
        expect(store.value, isNotNull);
        expect(
          find.text(
            config.$1 == 'ar'
                ? 'اقتراح محفوظ بانتظار موافقة العميل'
                : 'Proposal saved; awaiting customer consent',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('owner-proposal-acknowledge')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('owner-proposal-close')),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
  test('new per-owner per-case storage contains only exact UUID tuples and refuses replacement', () async {
    SharedPreferences.setMockInitialValues({});
    final client = auth.TestClient(auth.TestAuth());
    try {
      final first = SharedOwnerProposalStore(client, caseId);
      await first.save(original);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        'owner_visit_recovery_proposal_uuid/${auth.actorId}/$caseId',
      });
      expect(
        prefs.getString(prefs.getKeys().single),
        contains(original.proposal),
      );
      expect(
        prefs.getString(prefs.getKeys().single),
        isNot(contains('evidence')),
      );
      const other = OwnerProposalReference(
        '66666666-6666-4666-8666-666666666666',
        '77777777-7777-4777-8777-777777777777',
        query,
        profile,
      );
      await expectLater(first.save(other), throwsStateError);
      final second = SharedOwnerProposalStore(client, other.caseId);
      await second.save(other);
      expect((await first.read())!.values, original.values);
      expect((await second.read())!.values, other.values);
      await first.clear(original);
      expect(await first.read(), isNull);
      expect((await second.read())!.values, other.values);
    } finally {
      await client.dispose();
      await client.testAuth.events.close();
      client.testAuth.dispose();
    }
  });

  test('bounded RPC timeout releases busy but exact nonce is retained until authoritative recovery', () async {
    final store = Store(), api = fixture.Gateway();
    final pending = Completer<dynamic>();
    api.handler = (name, p) async {
      if (name == 'prepare_visit_recovery_proposal') {
        return await pending.future;
      }
      return snapshot(store.value!);
    };
    final c = OwnerRecoveryProposalController(
      gateway: api,
      store: store,
      actorId: () => 'owner',
      caseId: caseId,
      query: query,
      profile: profile,
      plate: 'ABC123',
      rpcTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(c.dispose);
    await c.refresh();
    await c.prepare(
      'in_person_original_service_documents',
      'Actual proof verified before proposal',
      true,
    );
    expect(c.busy, false);
    expect(c.phase, 'uncertain');
    expect(c.error, 'unconfirmed');
    final saved = store.value!;
    pending.complete(snapshot(saved));
    await c.refresh();
    expect(c.phase, 'open');
    expect(store.value!.values, saved.values);
    expect(api.calls.map((call) => call.$1), [
      'prepare_visit_recovery_proposal',
      'get_visit_recovery_proposal',
    ]);
    expect(api.calls.last.$2, {'p_proposal': saved.proposal});
  });

  testWidgets(
    'owner Auth change clears private fields and ignores late proposal response without clearing durable nonce',
    (t) async {
      final client = await auth.client(t),
          store = Store(),
          api = fixture.Gateway();
      final pending = Completer<dynamic>();
      api.handler = (_, p) async => await pending.future;
      await t.pumpWidget(
        MaterialApp(
          home: OwnerRecoveryProposalScreen(
            client: client,
            caseId: caseId,
            query: query,
            profile: profile,
            plate: 'ABC123',
            gateway: api,
            store: store,
          ),
        ),
      );
      await t.pumpAndSettle();
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      );
      await t.pump();
      final dropdown = find.byType(DropdownButtonFormField<String>);
      await press(t, dropdown);
      await press(
        t,
        find.text('Original service documents presented in person').last,
      );
      await t.enterText(
        find.byKey(const ValueKey('owner-proposal-reason')),
        'Private original proof checked in person',
      );
      await t.pump();
      await press(t, find.byKey(const ValueKey('owner-proposal-attestation')));
      final submit = find.byKey(const ValueKey('owner-proposal-prepare'));
      await t.ensureVisible(submit);
      await t.tap(submit);
      await t.pump();
      expect(api.calls, hasLength(1));
      final saved = store.value!;
      client.testAuth.user = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await t.pump();
      pending.complete(snapshot(saved));
      await t.pumpAndSettle();
      expect(
        find.text('Recorded reason: Actual checked private evidence'),
        findsNothing,
      );
      expect(
        find.textContaining('Private original proof checked in person'),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('owner-proposal-prepare')),
        findsNothing,
      );
      expect(
        find.text(
          'Session or case scope changed. Reopen with the correct account.',
        ),
        findsOneWidget,
      );
      expect(store.value!.values, saved.values);
      expect(t.takeException(), isNull);
    },
  );
}
