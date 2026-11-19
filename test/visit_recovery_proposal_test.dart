import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/visit_recovery_proposal.dart';

const testActor = '11111111-1111-4111-8111-111111111111';
const caseId = '22222222-2222-4222-8222-222222222222';
const proposal = '33333333-3333-4333-8333-333333333333';

class Store implements RecoveryProposalStore {
  RecoveryProposalReference? ref;
  bool failSave = false;
  final trace = <String>[];
  @override
  Future<RecoveryProposalReference?> read() async => ref;
  @override
  Future<RecoveryProposalReference> save(
    RecoveryProposalReference value,
  ) async {
    trace.add('persist');
    if (failSave) throw StateError('Storage unavailable');
    ref ??= value;
    return ref!;
  }

  @override
  Future<void> clear(RecoveryProposalReference value) async {
    expect(ref!.request, value.request);
    trace.add('clear');
    ref = null;
  }
}

class Gateway implements RecoveryProposalGateway {
  Gateway(this.store);
  final Store store;
  String? user = testActor;
  int accepts = 0, results = 0, closes = 0;
  bool timeout = false, wrongResult = false, missingTerms = false;
  String outcome = 'accepted';
  Completer<Map<String, dynamic>>? pending;
  @override
  String? get actor => user;
  @override
  Future<Map<String, dynamic>> current(String id) async => {
    'case_id': id,
    'state': 'open',
    'proposal': {'proposal_id': proposal, 'expires_at': '2026-11-16T00:00:00Z'},
    'approval_required': true,
    'link_created': false,
    'consent_version': 'visit-recovery-proposal-v1',
    'canonical_consent_version': 'offline-claim-v1',
    'notice_ar': missingTerms ? '' : 'موافقة المراجعة',
    'notice_en': 'Review consent',
    'canonical_notice_ar': 'تحقق مستقل',
    'canonical_notice_en': 'Independent verification',
    'unexpected_old_contact': 'must-not-cache',
  };
  Map<String, dynamic> receipt(RecoveryProposalReference ref) => {
    'request_id': ref.request,
    'case_id': wrongResult ? proposal : ref.caseId,
    'proposal_id': ref.proposal,
    'state': outcome,
    'approval_required': true,
    'link_created': false,
  };
  @override
  Future<Map<String, dynamic>> accept(
    RecoveryProposalReference ref,
    Map<String, dynamic> consent,
    Map<String, dynamic> claimConsent,
  ) async {
    store.trace.add('accept');
    accepts++;
    expect(store.ref!.request, ref.request);
    expect(consent, {
      'accepted': true,
      'version': 'visit-recovery-proposal-v1',
      'text': 'موافقة المراجعة',
      'language': 'ar',
    });
    expect(claimConsent, {
      'accepted': true,
      'version': 'offline-claim-v1',
      'text': 'تحقق مستقل',
      'language': 'ar',
    });
    if (pending != null) return pending!.future;
    if (timeout) throw TimeoutException('Lost response');
    return receipt(ref);
  }

  @override
  Future<Map<String, dynamic>> result(String request) async {
    results++;
    return outcome == 'absent'
        ? {
            'request_id': request,
            'state': 'absent',
            'definitive_failure': false,
          }
        : receipt(store.ref!);
  }

  @override
  Future<Map<String, dynamic>> close(String request) async {
    closes++;
    outcome = 'closed';
    return {'request_id': request, 'state': 'closed'};
  }
}

RecoveryProposalController make(Gateway g, Store s) =>
    RecoveryProposalController(caseId: caseId, gateway: g, store: s);
void main() {
  test('both explicit frozen consents required; persists tuple before actual accept and waits for owner', () async {
    final s = Store();
    final gateway = Gateway(s), c = make(gateway, s);
    addTearDown(c.dispose);
    await c.refresh();
    expect(c.view.toString(), isNot(contains('must-not-cache')));
    await c.accept(language: 'ar', accepted: true, claimAccepted: false);
    expect(gateway.accepts, 0);
    await c.accept(language: 'ar', accepted: true, claimAccepted: true);
    expect(s.trace, ['persist', 'accept']);
    expect(c.phase, 'accepted');
    expect(c.reference, isNotNull);
    expect(c.view, isNull);
    await c.acknowledge();
    expect(s.trace, contains('clear'));
    expect(c.reference, isNull);
  });
  test('lost response restart gets exact original result without second acceptance', () async {
    final s = Store();
    final gateway = Gateway(s)..timeout = true, c = make(gateway, s);
    addTearDown(c.dispose);
    await c.refresh();
    await c.accept(language: 'ar', accepted: true, claimAccepted: true);
    final original = s.ref!.request;
    expect(c.phase, 'uncertain');
    gateway.outcome = 'absent';
    final restarted = make(gateway, s);
    addTearDown(restarted.dispose);
    await restarted.refresh();
    expect(restarted.reference!.request, original);
    expect(restarted.phase, 'uncertain');
    expect(restarted.canAccept, false);
    await restarted.close();
    expect(restarted.phase, 'closed');
    expect(s.ref, isNotNull);
    await restarted.acknowledge();
    expect(s.ref, isNull);
    expect(gateway.accepts, 1);
  });
  test(
    'failed durable save never dispatches accept or rotates in-memory nonce',
    () async {
      final s = Store()..failSave = true;
      final g = Gateway(s), c = make(g, s);
      addTearDown(c.dispose);
      await c.refresh();
      await c.accept(language: 'ar', accepted: true, claimAccepted: true);
      final original = c.reference!.request;
      s.failSave = false;
      await c.close();
      expect(s.ref!.request, original);
      expect(c.phase, 'closed');
    },
  );
  test(
    'wrong receipt binding cannot clear UUID or announce acceptance',
    () async {
      final s = Store();
      final gateway = Gateway(s)..wrongResult = true, c = make(gateway, s);
      addTearDown(c.dispose);
      await c.refresh();
      await c.accept(language: 'ar', accepted: true, claimAccepted: true);
      expect(c.phase, 'uncertain');
      expect(c.error, 'unconfirmed');
      expect(s.ref, isNotNull);
      await c.acknowledge();
      expect(s.ref, isNotNull);
    },
  );
  test(
    'Auth invalidation drops late acceptance reply and private cached terms',
    () async {
      final s = Store();
      final gateway = Gateway(s)..pending = Completer(), c = make(gateway, s);
      addTearDown(c.dispose);
      await c.refresh();
      final work = c.accept(
        language: 'ar',
        accepted: true,
        claimAccepted: true,
      );
      await Future<void>.delayed(Duration.zero);
      c.invalidate();
      gateway.pending!.complete(gateway.receipt(s.ref!));
      await work;
      expect(c.phase, 'invalid');
      expect(c.view, isNull);
      expect(c.reference, isNull);
      expect(s.ref, isNotNull);
    },
  );
  test(
    'missing canonical notice disables consent and does not expose stale terms',
    () async {
      final s = Store();
      final gateway = Gateway(s)..missingTerms = true, c = make(gateway, s);
      addTearDown(c.dispose);
      await c.refresh();
      expect(c.canAccept, false);
      expect(c.view, isNull);
      expect(c.error, 'unconfirmed');
    },
  );
}
