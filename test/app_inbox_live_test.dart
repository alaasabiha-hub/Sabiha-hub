import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/app_inbox_live.dart';

class Transport implements AppInboxLiveTransport {
  int reads = 0, subscriptions = 0, unsubscriptions = 0, reauthentications = 0;
  @override
  Future<void> reauthenticate() async {
    reauthentications++;
  }

  VoidCallback? hint, reconnect;
  Future<int> Function()? handler;
  @override
  Future<int> readUnread() {
    reads++;
    return handler?.call() ?? Future.value(3);
  }

  @override
  Future<void> subscribe({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  }) async {
    subscriptions++;
    hint = onHint;
    reconnect = onReconnect;
  }

  @override
  Future<void> unsubscribe() async {
    unsubscriptions++;
  }
}

class LiveAuth extends GoTrueClient {
  LiveAuth()
    : super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  final events = StreamController<AuthState>.broadcast();
  String token = 'initial';
  final user = User(
    id: 'actor',
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

class LiveClient extends SupabaseClient {
  LiveClient(this.fake)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final LiveAuth fake;
  @override
  GoTrueClient get auth => fake;
}

void main() {
  test('SDK broadcast envelope and managed metadata are hints only', () {
    expect(
      isAppInboxChangedHint({
        'event': 'inbox_changed',
        'payload': {
          'kind': 'inbox_changed',
          'id': 'managed-random-id',
          'unread_count': 999,
        },
      }),
      true,
    );
    expect(isAppInboxChangedHint({'kind': 'inbox_changed'}), true);
    expect(
      isAppInboxChangedHint({
        'event': 'inbox_changed',
        'payload': {'kind': 'other', 'unread_count': 999},
      }),
      false,
    );
    expect(isAppInboxChangedHint({'unread_count': 999}), false);
  });
  late LiveAuth auth;
  late LiveClient client;
  setUpAll(() {
    auth = LiveAuth();
    client = LiveClient(auth);
  });
  tearDownAll(() async {
    await client.dispose();
    await auth.events.close();
    auth.dispose();
  });
  testWidgets(
    'hints during read coalesce to one trailing authorized refresh with no dropped last hint',
    (t) async {
      final x = Transport();
      var pending = Completer<int>();
      x.handler = () => pending.future;
      final c = AppInboxLiveController(transport: x);
      c.visibility(visible: true, foreground: true);
      await t.pump();
      expect(x.reads, 1);
      for (var n = 0; n < 12; n++) {
        x.hint!();
      }
      expect(x.reads, 1);
      pending.complete(2);
      await t.pump();
      expect(c.unread, 2);
      pending = Completer<int>();
      await t.pump(const Duration(milliseconds: 150));
      expect(x.reads, 2);
      x.hint!();
      pending.complete(5);
      await t.pump();
      x.handler = () async => 7;
      await t.pump(const Duration(milliseconds: 150));
      await t.pump();
      expect(x.reads, 3);
      expect(c.unread, 7);
      expect(c.known, true);
      c.dispose();
    },
  );
  testWidgets(
    'visibility and foreground stop reads and fallback; resume refreshes dirty state',
    (t) async {
      final x = Transport();
      final c = AppInboxLiveController(transport: x);
      c.visibility(visible: true, foreground: true);
      await t.pump();
      expect(x.reads, 1);
      c.visibility(visible: false, foreground: true);
      x.hint!();
      await t.pump(const Duration(seconds: 45));
      expect(x.reads, 1);
      c.visibility(visible: true, foreground: false);
      await t.pump(const Duration(seconds: 25));
      expect(x.reads, 1);
      c.visibility(visible: true, foreground: true);
      await t.pump();
      expect(x.reads, 2);
      await t.pump(const Duration(seconds: 20));
      await t.pump(const Duration(milliseconds: 150));
      await t.pump();
      expect(x.reads, 3);
      c.dispose();
    },
  );
  testWidgets(
    'reconnect requests new facts and failed fresh read clears count instead of optimistic fallback',
    (t) async {
      final x = Transport();
      final c = AppInboxLiveController(transport: x);
      c.visibility(visible: true, foreground: true);
      await t.pump();
      expect(c.unread, 3);
      x.handler = () async => throw StateError('PRIVATE');
      x.reconnect!();
      await t.pump(const Duration(milliseconds: 150));
      await t.pump();
      expect(c.unread, 0);
      expect(c.known, false);
      expect(c.failed, true);
      expect(x.reads, 2);
      c.dispose();
    },
  );
  testWidgets(
    'invalidation unsubscribes zeros and rejects late old actor result',
    (t) async {
      final x = Transport();
      final pending = Completer<int>();
      x.handler = () => pending.future;
      final c = AppInboxLiveController(transport: x);
      c.visibility(visible: true, foreground: true);
      await t.pump();
      c.invalidate();
      pending.complete(99);
      await t.pump();
      expect(c.unread, 0);
      expect(c.known, false);
      expect(c.invalid, true);
      expect(x.unsubscriptions, greaterThan(0));
      await t.pump(const Duration(seconds: 25));
      expect(x.reads, 1);
      c.dispose();
    },
  );
  for (final locale in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets('localized count accessible without event body ${locale.$1}', (
      t,
    ) async {
      t.view.physicalSize = Size(locale.$2, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final x = Transport();
      await t.pumpWidget(
        MaterialApp(
          locale: Locale(locale.$1),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppInboxButton(
                  client: client,
                  transport: x,
                  onOpen: () async {},
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(
        find.byTooltip(
          locale.$1 == 'ar' ? 'التنبيهات · 3 غير مقروءة' : 'Inbox · 3 unread',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'same initial auth replay preserved signout clears and prevents re-adoption',
    (t) async {
      final x = Transport();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppInboxButton(
                  client: client,
                  transport: x,
                  onOpen: () async {},
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pump();
      expect(find.text('3'), findsOneWidget);
      auth.token = 'changed';
      auth.events.add(const AuthState(AuthChangeEvent.signedOut, null));
      await t.pumpAndSettle();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pumpAndSettle();
      expect(x.reauthentications, 0);
      expect(x.reads, 1);
      expect(find.text('3'), findsNothing);
      expect(
        t
            .widget<IconButton>(
              find.byKey(const ValueKey('app_inbox_live_button')),
            )
            .onPressed,
        isNull,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'same bound actor token refresh zeroes old count reauthorizes and resubscribes with fresh RPC',
    (t) async {
      final x = Transport();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppInboxButton(
                  client: client,
                  transport: x,
                  onOpen: () async {},
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      auth.events.add(AuthState(AuthChangeEvent.signedIn, auth.currentSession));
      await t.pumpAndSettle();
      final pending = Completer<int>();
      x.handler = () => pending.future;
      auth.token = 'fresh-same-actor';
      auth.events.add(
        AuthState(AuthChangeEvent.tokenRefreshed, auth.currentSession),
      );
      await t.pump();
      await t.pump();
      expect(find.text('3'), findsNothing);
      expect(x.reauthentications, 1);
      expect(x.subscriptions, 2);
      expect(x.reads, 2);
      pending.complete(8);
      await t.pumpAndSettle();
      expect(find.text('8'), findsOneWidget);
      expect(
        t
            .widget<IconButton>(
              find.byKey(const ValueKey('app_inbox_live_button')),
            )
            .onPressed,
        isNotNull,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'covered route pauses polling and returning from inbox refreshes actual count',
    (t) async {
      final x = Transport();
      late BuildContext home;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              home = context;
              return Scaffold(
                appBar: AppBar(
                  actions: [
                    AppInboxButton(
                      client: client,
                      transport: x,
                      onOpen: () async {
                        await Navigator.of(home).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const Scaffold(body: Text('Inbox open')),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(x.reads, 1);
      await t.tap(find.byKey(const ValueKey('app_inbox_live_button')));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 30));
      expect(x.reads, 1);
      x.handler = () async => 0;
      Navigator.of(home).pop();
      await t.pumpAndSettle();
      expect(x.reads, 2);
      expect(find.byKey(const ValueKey('app_inbox_unread')), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
}
