import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_visit_recovery.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';

class Auth extends GoTrueClient {
  Auth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  String token = 'initial';
  final user = User(
    id: 'owner',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-15T00:00:00Z',
  );
  @override
  User? get currentUser => user;
  @override
  Session? get currentSession =>
      Session(accessToken: token, tokenType: 'bearer', user: user);
  @override
  Stream<AuthState> get onAuthStateChange => events.stream;
}

class Client extends SupabaseClient {
  Client(this.fake)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final Auth fake;
  @override
  GoTrueClient get auth => fake;
}

class Store implements OfflineClaimStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> clear() async {}
}

class Gateway implements OfflineClaimGateway {
  Completer<dynamic>? pending;
  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> p) async =>
      pending == null
      ? {
          'items': [
            {
              'case_id': 'case',
              'requester_name': 'Private QA case',
              'status': 'awaiting_matching',
              'identity_current': true,
            },
          ],
          'next_cursor': null,
        }
      : pending!.future;
}

void main() {
  late Auth auth;
  late Client client;
  setUpAll(() {
    auth = Auth();
    client = Client(auth);
  });
  tearDownAll(() async {
    await auth.events.close();
    auth.dispose();
    await client.dispose();
  });
  testWidgets(
    'owner mount accepts same initial signedIn replay; later fresh token invalidates and rejects late list',
    (t) async {
      final g = Gateway()..pending = Completer<dynamic>();
      await t.pumpWidget(
        MaterialApp(
          home: OwnerVisitRecoveryScreen(
            client: client,
            gateway: g,
            store: Store(),
          ),
        ),
      );
      await t.pump();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pump();
      g.pending!.complete({
        'items': [
          {
            'case_id': 'case',
            'requester_name': 'Private QA case',
            'status': 'awaiting_matching',
            'identity_current': true,
          },
        ],
        'next_cursor': null,
      });
      await t.pumpAndSettle();
      expect(find.text('Private QA case'), findsOneWidget);
      g.pending = Completer<dynamic>();
      await t.tap(find.text('Refresh'));
      await t.pump();
      auth.token = 'fresh-token';
      auth.events.add(
        AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
      );
      await t.pump();
      expect(find.text('Private QA case'), findsNothing);
      g.pending!.complete({
        'items': [
          {'requester_name': 'Late private case'},
        ],
        'next_cursor': null,
      });
      await t.pumpAndSettle();
      expect(find.text('Late private case'), findsNothing);
      expect(find.textContaining('Session changed'), findsOneWidget);
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox());
    },
  );
}
