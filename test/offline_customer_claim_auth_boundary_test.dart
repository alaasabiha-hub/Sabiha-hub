import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';

import 'offline_customer_claim_test.dart'
    show FakeClaimGateway, MemoryClaimStore, receiptId, claimId, proof;

class ClaimAuth extends GoTrueClient {
  ClaimAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  String token = 'initial';
  User? user = User(
    id: 'actor',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession => user == null
      ? null
      : Session(accessToken: token, tokenType: 'bearer', user: user!);
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class ClaimClient extends SupabaseClient {
  ClaimClient(this.fake)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final ClaimAuth fake;
  @override
  GoTrueClient get auth => fake;
}

class PendingGateway implements OfflineClaimGateway {
  final delegate = FakeClaimGateway();
  Completer<dynamic>? pending;
  String? pendingName;
  Map<String, dynamic>? sent;
  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> p) {
    if (name == pendingName && pending != null) {
      sent = Map.of(p);
      return pending!.future;
    }
    return delegate.rpc(name, p);
  }
}

void main() {
  late ClaimAuth auth;
  late ClaimClient client;
  late User user;
  setUpAll(() {
    auth = ClaimAuth();
    user = auth.user!;
    client = ClaimClient(auth);
  });
  setUp(() {
    auth.user = user;
    auth.token = 'initial';
  });
  tearDownAll(() async {
    await client.dispose();
    await auth.events.close();
    auth.dispose();
  });
  Future<void> press(WidgetTester t, String key) async {
    t.testTextInput.hide();
    final target = find.byKey(ValueKey(key));
    await t.ensureVisible(target);
    await t.pumpAndSettle();
    await t.tap(target);
    await t.pump();
  }

  testWidgets(
    'customer matching initial replay preserved then signout clears secret and rejects late claim receipt without clearing durable UUID',
    (t) async {
      final api = PendingGateway()
        ..pendingName = 'request_offline_customer_claim'
        ..pending = Completer<dynamic>();
      final store = MemoryClaimStore();
      await t.pumpWidget(
        MaterialApp(
          home: CustomerOfflineClaimScreen(
            client: client,
            gateway: api,
            store: store,
          ),
        ),
      );
      await t.pumpAndSettle();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pump();
      await t.enterText(
        find.byKey(const ValueKey('receipt_reference')),
        receiptId,
      );
      await t.enterText(find.byKey(const ValueKey('receipt_secret')), proof);
      await press(t, 'claim_consent');
      await press(t, 'submit_claim');
      final nonce = store.value;
      expect(nonce, isNotNull);
      expect(api.sent?['p_secret'], proof);
      auth.user = null;
      auth.events.add(const AuthState(AuthChangeEvent.signedOut, null));
      await t.pumpAndSettle();
      expect(find.textContaining('Session changed.'), findsOneWidget);
      expect(store.value, nonce);
      expect(store.clears, 0);
      final secret = t.widget<TextFormField>(
        find.byKey(const ValueKey('receipt_secret')),
      );
      expect(secret.controller!.text, isEmpty);
      expect(secret.enabled, false);
      api.pending!.complete({
        'request_id': nonce,
        'status': 'pending_owner_review',
        'private_marker': 'LATE_CUSTOMER',
      });
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('claim_status')), findsNothing);
      expect(find.textContaining('LATE_CUSTOMER'), findsNothing);
      expect(store.value, nonce);
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner matching initial replay preserved then fresh token clears cached reviews reason and ignores late refresh',
    (t) async {
      final api = PendingGateway();
      final store = MemoryClaimStore();
      await t.pumpWidget(
        MaterialApp(
          home: OwnerOfflineClaimReviewsScreen(
            client: client,
            gateway: api,
            store: store,
          ),
        ),
      );
      await t.pumpAndSettle();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pump();
      expect(find.text('Actual reception customer'), findsOneWidget);
      await press(t, 'select_$claimId');
      await t.ensureVisible(find.byKey(const ValueKey('owner_review_reason')));
      await t.enterText(
        find.byKey(const ValueKey('owner_review_reason')),
        'PRIVATE_OWNER_REASON',
      );
      api.pendingName = 'list_offline_customer_claim_reviews';
      api.pending = Completer<dynamic>();
      await press(t, 'refresh_reviews');
      auth.token = 'new-session-token';
      auth.events.add(
        AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
      );
      await t.pumpAndSettle();
      expect(find.text('Actual reception customer'), findsNothing);
      expect(find.text('PRIVATE_OWNER_REASON'), findsNothing);
      expect(find.textContaining('Session changed.'), findsOneWidget);
      api.pending!.complete([
        {'name': 'LATE_OWNER_PRIVATE', 'claim_id': claimId},
      ]);
      await t.pumpAndSettle();
      expect(find.text('LATE_OWNER_PRIVATE'), findsNothing);
      expect(
        api.delegate.calls.where(
          (c) => c['name'] == 'decide_offline_customer_claim',
        ),
        isEmpty,
      );
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox());
    },
  );
}
