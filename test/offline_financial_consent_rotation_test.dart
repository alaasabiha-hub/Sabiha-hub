import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/offline_reward_financial_consent.dart';

import 'offline_reward_financial_consent_test.dart' as old;
import 'visit_recovery_request_test.dart' as auth;

const prior = OfflineFinancialReference(
  old.consentRequest,
  old.financialProposal,
  old.withdrawal,
);

class RotationStore extends old.Store implements OfflineFinancialRotationStore {
  final entries = <String, OfflineFinancialReference>{};
  bool failCompare = false;
  @override
  Future<void> rotate(
    OfflineFinancialReference expected,
    OfflineFinancialReference replacement,
  ) async {
    trace.add('rotate');
    if (failCompare || value?.ids.join('/') != expected.ids.join('/')) {
      throw StateError('CAS changed');
    }
    entries[expected.request] = expected;
    entries[replacement.request] = replacement;
    value = replacement;
  }

  @override
  Future<List<OfflineFinancialReference>> history() async =>
      entries.values.toList();
}

class RotationGateway extends old.Gateway {
  RotationGateway(super.store);
  String priorState = 'revoked';
  bool sameProposal = false;
  Completer<Map<String, dynamic>>? latest;
  final accepted = <String, Map<String, dynamic>>{};
  Map<String, dynamic> freshProposal() {
    final data = old.proposalView();
    data['proposal_id'] = sameProposal
        ? old.financialProposal
        : old.nextProposal;
    data['fingerprint'] = List.filled(64, 'b').join();
    ((data['terms'] as Map)['service'] as Map).addAll(<String, String>{
      'name_ar': 'خدمة جديدة فعلية',
      'name_en': 'New actual service',
    });
    (data['consent'] as Map).addAll(<String, String>{
      'notice_ar': 'إشعار الخادم المالي الجديد لهذا المقترح فقط.',
      'notice_en': 'New exact server financial notice for this proposal only.',
    });
    return data;
  }

  @override
  Future<Map<String, dynamic>> proposal(String? id) async {
    calls.add({'name': 'proposal', 'id': id});
    if (latest != null) return await latest!.future;
    return freshProposal();
  }

  @override
  Future<Map<String, dynamic>> receipt(String request) async {
    calls.add({'name': 'receipt', 'request': request});
    if (request == prior.request) {
      if (priorState == 'revoked' || priorState == 'absent') {
        return {
          'request_id': request,
          'state': priorState,
          'definitive_failure': priorState == 'revoked',
          'issuer_enabled': false,
        };
      }
      final view = old.proposalView(
        state: priorState == 'issued' ? 'issued' : 'inactive',
      );
      return {
        'request_id': request,
        'state': priorState,
        'proposal_id': prior.proposal,
        'fingerprint': old.fingerprint,
        'consent': {
          'accepted': true,
          'version': 'offline-reward-financial-v1',
          'language': 'en',
          'text': (old.proposalView()['consent'] as Map)['notice_en'],
        },
        'proposal': view,
        'reward_issued': priorState == 'issued',
        'issuer_enabled': false,
        'redemption_enabled': false,
      };
    }
    return accepted[request] ??
        {
          'request_id': request,
          'state': 'absent',
          'definitive_failure': false,
          'issuer_enabled': false,
        };
  }

  @override
  Future<Map<String, dynamic>> accept(
    String request,
    String proposal,
    String fingerprint,
    Map<String, dynamic> consent,
  ) async {
    expect(store.value!.request, request);
    expect(store.value!.proposal, old.nextProposal);
    store.trace.add('accept');
    calls.add({
      'name': 'accept',
      'request': request,
      'proposal': proposal,
      'fingerprint': fingerprint,
      'consent': Map.of(consent),
    });
    if (loseAccept) throw TimeoutException('Unknown accept');
    final view = freshProposal();
    final result = {
      'request_id': request,
      'state': 'consent_recorded',
      'proposal_id': proposal,
      'fingerprint': fingerprint,
      'consent': Map<String, dynamic>.from(consent),
      'proposal': view,
      'reward_issued': false,
      'issuer_enabled': false,
      'redemption_enabled': false,
    };
    accepted[request] = result;
    return result;
  }
}

OfflineFinancialConsentController make(
  RotationGateway api,
  RotationStore store,
) => OfflineFinancialConsentController(gateway: api, store: store);

void main() {
  test('fresh revoked proof precedes different proposal preview; explicit new scope consent archives old tuple before new mutation', () async {
    final store = RotationStore()..value = prior;
    final gateway = RotationGateway(store), c = make(gateway, store);
    addTearDown(c.dispose);
    await c.refresh();
    expect(c.canPreviewReplacement, true);
    final originalCalls = gateway.calls.length;
    await c.previewReplacement();
    expect(gateway.calls.skip(originalCalls).map((call) => call['name']), [
      'receipt',
      'proposal',
    ]);
    expect(c.phase, 'replacement_preview');
    expect(store.value!.ids, prior.ids);
    expect(store.entries, isEmpty);
    final scope = c.consentScope;
    await c.consent('en', accepted: false, scope: scope);
    expect(store.trace, isEmpty);
    await c.consent('en', accepted: true, scope: scope);
    expect(c.phase, 'consent_recorded');
    expect(store.value!.proposal, old.nextProposal);
    expect(store.value!.request, isNot(prior.request));
    expect(store.trace, ['rotate', 'save', 'accept']);
    expect(store.entries[prior.request]!.ids, prior.ids);
    final sent = gateway.calls.singleWhere((call) => call['name'] == 'accept');
    expect(
      (sent['consent'] as Map)['text'],
      'New exact server financial notice for this proposal only.',
    );
  });

  test('unknown, inactive, issued and stale latest same proposal never rotate or fetch another consent automatically', () async {
    for (final state in ['absent', 'inactive', 'issued']) {
      final store = RotationStore()..value = prior;
      final gateway = RotationGateway(store)..priorState = state,
          c = make(gateway, store);
      await c.refresh();
      await c.previewReplacement();
      expect(c.canPreviewReplacement, false);
      expect(store.trace, isEmpty);
      expect(store.value!.ids, prior.ids);
      expect(
        gateway.calls.where((call) => call['name'] == 'proposal'),
        isEmpty,
      );
      c.dispose();
    }
    final store = RotationStore()..value = prior;
    final gateway = RotationGateway(store)..sameProposal = true,
        c = make(gateway, store);
    addTearDown(c.dispose);
    await c.refresh();
    await c.previewReplacement();
    expect(c.phase, 'revoked');
    expect(c.canConsent, false);
    expect(store.entries, isEmpty);
    // A server status that changed after the initial read is rechecked before preview.
    gateway.sameProposal = false;
    gateway.priorState = 'absent';
    await c.previewReplacement();
    expect(c.phase, 'withdrawal_pending');
    expect(c.canConsent, false);
    expect(store.value!.ids, prior.ids);
  });

  test('CAS failure retains exact new attempt; restart absent remains blocked without new proposal or accept', () async {
    final store = RotationStore()..value = prior;
    final gateway = RotationGateway(store), c = make(gateway, store);
    addTearDown(c.dispose);
    await c.refresh();
    await c.previewReplacement();
    store.failCompare = true;
    await c.consent('en', accepted: true, scope: c.consentScope);
    final attempt = c.reference!;
    expect(c.phase, 'uncertain');
    expect(store.value!.ids, prior.ids);
    expect(gateway.calls.where((call) => call['name'] == 'accept'), isEmpty);
    store.failCompare = false;
    gateway.loseAccept = true;
    await c.retry();
    expect(c.reference!.ids, attempt.ids);
    expect(store.value!.ids, attempt.ids);
    final restarted = make(gateway, store);
    addTearDown(restarted.dispose);
    await restarted.refresh();
    final before = gateway.calls.length;
    await restarted.previewReplacement();
    await restarted.consent('en', accepted: true, scope: null);
    expect(restarted.phase, 'uncertain');
    expect(restarted.canPreviewReplacement, false);
    expect(gateway.calls, hasLength(before));
    expect(store.entries[prior.request]!.ids, prior.ids);
  });

  test('logout/late preview clears candidate and never rotates old receipt or accepts', () async {
    final store = RotationStore()..value = prior;
    final gateway = RotationGateway(store)
          ..latest = Completer<Map<String, dynamic>>(),
        c = make(gateway, store);
    addTearDown(c.dispose);
    await c.refresh();
    final preview = c.previewReplacement();
    await Future<void>.delayed(Duration.zero);
    gateway.actor = null;
    c.invalidate();
    gateway.latest!.complete(gateway.freshProposal());
    await preview;
    expect(c.view, isNull);
    expect(c.canConsent, false);
    expect(store.value!.ids, prior.ids);
    expect(store.entries, isEmpty);
  });

  test('shared store CAS retains UUID-only history, rejects changed reference and logout before queued write', () async {
    SharedPreferences.setMockInitialValues({});
    final client = auth.TestClient(auth.TestAuth());
    try {
      final store = SharedOfflineFinancialStore(client);
      await store.save(prior);
      const next = OfflineFinancialReference(
        '66666666-6666-4666-8666-666666666666',
        old.nextProposal,
      );
      await store.rotate(prior, next);
      expect((await store.read())!.ids, next.ids);
      expect((await store.history()).map((ref) => ref.request).toSet(), {
        prior.request,
        next.request,
      });
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        final ids = jsonDecode(prefs.getString(key)!);
        expect(ids, isA<List>());
        expect(
          (ids as List).every(
            (id) => id is String && RegExp(r'^[0-9a-f-]{36}$').hasMatch(id),
          ),
          true,
        );
      }
      await expectLater(
        store.rotate(
          prior,
          const OfflineFinancialReference(
            '77777777-7777-4777-8777-777777777777',
            '88888888-8888-4888-8888-888888888888',
          ),
        ),
        throwsStateError,
      );
      // Same-target retry is idempotent and cannot discard existing history.
      await store.rotate(prior, next);
      expect((await store.history()), hasLength(2));
      final pending = store.rotate(
        next,
        const OfflineFinancialReference(
          '99999999-9999-4999-8999-999999999999',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      );
      client.testAuth.user = null;
      await expectLater(pending, throwsStateError);
      expect(
        jsonDecode(
          prefs.getString(
            'offline_reward_financial_consent_uuid/${auth.actorId}',
          )!,
        ),
        next.ids,
      );
    } finally {
      await client.dispose();
      await client.testAuth.events.close();
      client.testAuth.dispose();
    }
  });

  testWidgets(
    'explicit new AR390 preview is unchecked and preserves old UUID receipt until new financial consent is selected',
    (t) async {
      final client = await auth.client(t),
          store = RotationStore()..value = prior;
      final api = RotationGateway(store);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await old.showPanel(t, client, api, store, language: 'ar', width: 390);
      await old.press(t, 'offline-financial-preview-new');
      expect(find.text('الخدمة: خدمة جديدة فعلية'), findsOneWidget);
      expect(
        t
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('offline-financial-checkbox')),
            )
            .value,
        false,
      );
      expect(
        t
            .widget<FilledButton>(
              find.byKey(const ValueKey('offline-financial-record')),
            )
            .onPressed,
        isNull,
      );
      expect(store.value!.ids, prior.ids);
      expect(store.entries, isEmpty);
      await old.press(t, 'offline-financial-checkbox');
      await old.press(t, 'offline-financial-record');
      expect(store.value!.proposal, old.nextProposal);
      expect(store.entries[prior.request]!.ids, prior.ids);
      expect(find.textContaining('سُجلت الموافقة المالية'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
