import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';
import 'package:sabiha_hub/visit_recovery_evidence.dart';

const actor = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const caseId = '33333333-3333-4333-8333-333333333333';
const claimId = '44444444-4444-4444-8444-444444444444';
const nextClaim = '55555555-5555-4555-8555-555555555555';
Map<String, dynamic> snapshot([String status = 'awaiting_matching']) => {
  'state': 'available',
  'case': {'case_id': caseId, 'status': status, 'identity_current': true},
  'link_current': false,
  'record_access_requires_fresh_history_scope': true,
};

class ClaimStore implements OfflineClaimStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String requestId) async {
    value = requestId;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class Store implements VisitRecoveryAttachmentStore {
  Store(this.events);
  final List<String> events;
  final refs = <VisitRecoveryAttachmentReference>[];
  bool failSave = false;
  int saves = 0, clears = 0;
  @override
  Future<List<VisitRecoveryAttachmentReference>> read() async => List.of(refs);
  @override
  Future<VisitRecoveryAttachmentReference> save(
    VisitRecoveryAttachmentReference ref,
  ) async {
    events.add('persist');
    saves++;
    if (failSave) throw StateError('Synthetic storage failure');
    if (refs.isEmpty) refs.add(ref);
    return refs.single;
  }

  @override
  Future<void> clear(VisitRecoveryAttachmentReference ref) async {
    expect(refs.single.requestId, ref.requestId);
    refs.clear();
    clears++;
  }
}

class Gateway implements VisitRecoveryEvidenceGateway {
  Gateway(this.store);
  final Store store;
  final events = <String>[];
  final sent = <VisitRecoveryAttachmentReference>[];
  String? user = actor;
  String status = 'awaiting_matching', proofStatus = 'pending_owner_review';
  bool loseAttach = false, identity = true, foreignClaim = false;
  Completer<Map<String, dynamic>>? pendingAttach;
  @override
  String? get currentActor => user;
  @override
  Future<Map<String, dynamic>> currentCase(String? id) async {
    events.add('case:${id ?? "latest"}');
    final result = snapshot(status);
    (result['case'] as Map)['identity_current'] = identity;
    return result;
  }

  @override
  Future<Map<String, dynamic>> ownClaim(String id) async {
    events.add('claim:$id');
    return {'request_id': foreignClaim ? nextClaim : id, 'status': proofStatus};
  }

  @override
  Future<Map<String, dynamic>> attach(
    VisitRecoveryAttachmentReference ref,
  ) async {
    events.add('attach');
    store.events.add('attach');
    expect(store.refs.single.requestId, ref.requestId);
    sent.add(ref);
    if (pendingAttach != null) return pendingAttach!.future;
    if (loseAttach) throw TimeoutException('Synthetic lost response');
    return snapshot(status);
  }
}

class TestAuth extends GoTrueClient {
  TestAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast(sync: true);
  User? user = User(
    id: actor,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession => user == null
      ? null
      : Session(accessToken: 'mock-session', tokenType: 'bearer', user: user!);
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class TestClient extends SupabaseClient {
  TestClient(this.testAuth, {http.Client? transport})
    : super(
        'http://127.0.0.1:54321',
        'fake-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient:
            transport ??
            MockClient((_) async => throw StateError('Unexpected network')),
      );
  final TestAuth testAuth;
  @override
  GoTrueClient get auth => testAuth;
}

VisitRecoveryEvidenceController controller(
  Gateway gateway,
  Store store,
  ClaimStore claims,
) => VisitRecoveryEvidenceController(
  gateway: gateway,
  store: store,
  claimStore: claims,
);
void main() {
  test('attachment validates exact own case and claim, persists before mutation, and keeps pending conservative', () async {
    final trace = <String>[];
    final store = Store(trace), claims = ClaimStore()..value = claimId;
    final g = Gateway(store);
    final c = controller(g, store, claims);
    addTearDown(c.dispose);
    await c.refresh();
    expect(g.sent, isEmpty);
    await c.afterProof(caseId);
    expect(g.events.sublist(g.events.length - 2), [
      'case:$caseId',
      'claim:$claimId',
    ]);
    expect(g.sent, isEmpty);
    await c.send();
    expect(trace, ['persist', 'attach']);
    expect(c.reference!.valid, true);
    expect(g.sent.single.caseId, caseId);
    expect(g.sent.single.claimId, claimId);
    expect(c.caseStatus, 'awaiting_matching');
    expect(c.reference, isNotNull);
    expect(store.clears, 0);
    expect(c.uncertain, false);
  });
  test('attachment lost response restart retries original scoped identity despite a changed claim store', () async {
    final store = Store([]), claims = ClaimStore()..value = claimId;
    final g = Gateway(store)..loseAttach = true;
    final first = controller(g, store, claims);
    await first.refresh();
    await first.send();
    final original = store.refs.single;
    expect(first.uncertain, true);
    first.dispose();
    claims.value = nextClaim;
    g.loseAttach = false;
    g.events.clear();
    final resumed = controller(g, store, claims);
    addTearDown(resumed.dispose);
    await resumed.refresh();
    expect(g.events, ['case:$caseId', 'claim:$claimId']);
    expect(resumed.uncertain, true);
    await resumed.send();
    expect(g.sent.last.requestId, original.requestId);
    expect(g.sent.last.claimId, claimId);
    expect(store.refs.single.requestId, original.requestId);
    g.status = 'linked';
    await resumed.refresh();
    expect(resumed.caseStatus, 'linked');
    expect(store.refs, isEmpty);
    expect(store.clears, 1);
    expect(resumed.canAttach, false);
  });
  test('attachment write failure, foreign claim and stale case identity cannot mutate', () async {
    for (final mode in ['storage', 'claim', 'identity']) {
      final store = Store([])..failSave = mode == 'storage';
      final claims = ClaimStore()..value = claimId;
      final g = Gateway(store)
        ..foreignClaim = mode == 'claim'
        ..identity = mode != 'identity';
      final c = controller(g, store, claims);
      await c.refresh();
      await c.send();
      expect(g.sent, isEmpty);
      c.dispose();
    }
  });
  test(
    'attachment stale auth reply is discarded and original local UUID retained',
    () async {
      final store = Store([]), claims = ClaimStore()..value = claimId;
      final g = Gateway(store)..pendingAttach = Completer();
      final c = controller(g, store, claims);
      addTearDown(c.dispose);
      await c.refresh();
      final pending = c.send();
      await Future<void>.delayed(Duration.zero);
      expect(store.refs.length, 1);
      g.user = other;
      c.invalidate();
      g.pendingAttach!.complete(snapshot('linked'));
      await pending;
      expect(c.view, isNull);
      expect(c.canAttach, false);
      expect(store.refs.length, 1);
      expect(store.clears, 0);
    },
  );
  test(
    'attachment UUID is stable by actor/case/claim and never proof authority',
    () {
      final first = visitRecoveryAttachmentReference(actor, caseId, claimId);
      expect(first.valid, true);
      expect(
        first.requestId,
        visitRecoveryAttachmentReference(
          actor.toUpperCase(),
          caseId,
          claimId,
        ).requestId,
      );
      expect(
        first.requestId,
        isNot(
          visitRecoveryAttachmentReference(other, caseId, claimId).requestId,
        ),
      );
      expect(
        first.requestId,
        isNot(
          visitRecoveryAttachmentReference(actor, caseId, nextClaim).requestId,
        ),
      );
    },
  );
  test(
    'shared attachment store retains UUIDs only and actor scoping',
    () async {
      SharedPreferences.setMockInitialValues({});
      final auth = TestAuth();
      final client = TestClient(auth);
      addTearDown(() async {
        await client.dispose();
        await auth.events.close();
        auth.dispose();
      });
      final store = SharedVisitRecoveryAttachmentStore(client);
      final ref = visitRecoveryAttachmentReference(actor, caseId, claimId);
      await store.save(ref);
      expect(
        (await SharedVisitRecoveryAttachmentStore(
          client,
        ).read()).single.requestId,
        ref.requestId,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().single,
        'visit_recovery_attachment_uuid/$actor/$caseId/$claimId',
      );
      expect(prefs.getString(prefs.getKeys().single), ref.requestId);
      auth.user = null;
      expect(store.read(), throwsStateError);
      expect(prefs.getKeys().length, 1);
    },
  );
  for (final language in ['ar', 'en']) {
    testWidgets(
      'evidence wrapper $language manual route and explicit send only, layout',
      (t) async {
        t.view.physicalSize = Size(language == 'ar' ? 390 : 1440, 1400);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final auth = TestAuth();
        final client = (await t.runAsync(() async => TestClient(auth)))!;
        final store = Store([]), claims = ClaimStore();
        final g = Gateway(store);
        addTearDown(() async {
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
          await t.runAsync(() async {
            await client.dispose();
            await auth.events.close();
            auth.dispose();
          });
        });
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: VisitRecoveryEvidenceScreen(
              proposalBuilder: (_, _) => const SizedBox.shrink(),
              client: client,
              gateway: g,
              attachmentStore: store,
              claimStore: claims,
              requestPanelBuilder: (_) => const Text('Request panel fixture'),
              proofBuilder: (context, actualStore) {
                expect(identical(actualStore, claims), true);
                return Scaffold(
                  body: TextButton(
                    key: const ValueKey('test-manual-proof'),
                    onPressed: () async {
                      await actualStore.write(claimId);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Manual receipt fixture'),
                  ),
                );
              },
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(g.sent, isEmpty);
        await t.ensureVisible(
          find.byKey(const ValueKey('recovery-open-proof')),
        );
        await t.tap(find.byKey(const ValueKey('recovery-open-proof')));
        await t.pumpAndSettle();
        expect(g.sent, isEmpty);
        await t.tap(find.byKey(const ValueKey('test-manual-proof')));
        await t.pumpAndSettle();
        expect(g.events, contains('case:$caseId'));
        expect(g.events, contains('claim:$claimId'));
        expect(g.sent, isEmpty);
        await t.ensureVisible(
          find.byKey(const ValueKey('recovery-attach-proof')),
        );
        await t.tap(find.byKey(const ValueKey('recovery-attach-proof')));
        await t.pumpAndSettle();
        expect(g.sent.length, 1);
        expect(
          find.text(
            language == 'ar'
                ? 'لا يزال الطلب في انتظار مطابقة المعلومات أو مراجعة المالك. إرسال الإثبات لا يؤكد ربط أي سجل.'
                : 'Still awaiting information matching or owner review. Sending proof does not confirm any record link.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining(caseId), findsNothing);
        expect(find.textContaining(claimId), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  test(
    'real gateway sends exact own IDs through existing guarded RPC only',
    () async {
      final paths = <String>[];
      final auth = TestAuth();
      final client = TestClient(
        auth,
        transport: MockClient((r) async {
          paths.add(r.url.path);
          expect(r.url.path, '/rest/v1/rpc/attach_my_visit_recovery_claim');
          final body = jsonDecode(r.body);
          expect(body, {
            'p_request': visitRecoveryAttachmentReference(
              actor,
              caseId,
              claimId,
            ).requestId,
            'p_case': caseId,
            'p_claim': claimId,
          });
          return http.Response(
            jsonEncode(snapshot()),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
      );
      try {
        final result = await SupabaseVisitRecoveryEvidenceGateway(client)
            .attach(visitRecoveryAttachmentReference(actor, caseId, claimId));
        expect(result['state'], 'available');
        expect(paths.length, 1);
      } finally {
        await client.dispose();
        await auth.events.close();
        auth.dispose();
      }
    },
  );
}
