import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/app_inbox.dart';
import 'package:sabiha_hub/app_inbox_live.dart';

import 'app_inbox_test.dart' as inbox;
import 'visit_recovery_request_test.dart' as auth;

class Transport implements AppInboxLiveTransport {
  VoidCallback? hint, reconnect;
  int subscriptions = 0, unsubscriptions = 0, renewals = 0;
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

  @override
  Future<void> reauthenticate() async {
    renewals++;
  }

  @override
  Future<int> readUnread() async =>
      throw StateError('Content must use its authorized list gateway');
}

Future<void> showInbox(
  WidgetTester t,
  auth.TestClient client,
  AppInboxController flow,
  Transport live, {
  GlobalKey<NavigatorState>? nav,
}) async {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await t.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      home: AppInboxScreen(
        client: client,
        controller: flow,
        liveTransport: live,
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 151));
  await t.pump();
  // Consume the exact initial replay before testing later fresh Auth events.
  client.testAuth.events.add(
    AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
  );
  await t.pump();
}

void main() {
  testWidgets(
    'live content hint received during read acknowledgement queues one trailing authorized fresh list',
    (t) async {
      final client = await auth.client(t),
          live = Transport(),
          api = inbox.Gateway();
      final read = Completer<dynamic>();
      var version = 'first';
      api.handle = (name, p) async {
        if (name == 'mark_my_app_inbox_read') return read.future;
        final page = inbox.page(id: version);
        (page['items'] as List).single['title_en'] = 'Actual server $version';
        return page;
      };
      final flow = AppInboxController(
        gateway: api,
        actorId: () => client.auth.currentUser?.id,
      );
      addTearDown(flow.dispose);
      await showInbox(t, client, flow, live);
      expect(find.text('Actual server first'), findsOneWidget);
      final operation = flow.markRead('first');
      await t.pump();
      version = 'second';
      live.hint!();
      live.hint!();
      await t.pump(const Duration(milliseconds: 200));
      expect(
        api.calls.where((c) => c['name'] == 'list_my_app_inbox'),
        hasLength(1),
      );
      read.complete({
        'event_id': 'first',
        'read': true,
        'read_at': '2026-11-15T00:00:00Z',
      });
      await operation;
      await t.pump(const Duration(milliseconds: 151));
      await t.pump();
      expect(
        api.calls.where((c) => c['name'] == 'list_my_app_inbox'),
        hasLength(2),
      );
      expect(find.text('Actual server second'), findsOneWidget);
      expect(find.text('Actual server first'), findsNothing);
      expect(live.subscriptions, 1);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'covered route ignores hints and signout clears content and rejects a late list response',
    (t) async {
      final client = await auth.client(t),
          live = Transport(),
          api = inbox.Gateway();
      final pending = Completer<dynamic>();
      var reads = 0;
      api.handle = (_, p) async {
        if (++reads == 1) return inbox.page();
        return await pending.future;
      };
      final flow = AppInboxController(
        gateway: api,
        actorId: () => client.auth.currentUser?.id,
      );
      addTearDown(flow.dispose);
      final nav = GlobalKey<NavigatorState>();
      await showInbox(t, client, flow, live, nav: nav);
      live.hint!();
      await t.pump(const Duration(milliseconds: 151));
      expect(
        flow.busy,
        true,
        reason:
            'reads=$reads subscriptions=${live.subscriptions} lifecycle=${t.binding.lifecycleState} current=${flow.current}',
      );
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await t.pumpAndSettle();
      final oldHint = live.hint!;
      oldHint();
      await t.pump(const Duration(seconds: 21));
      expect(reads, 2);
      expect(live.unsubscriptions, greaterThan(0));
      client.testAuth.user = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await t.pump();
      expect(flow.items, isEmpty);
      pending.complete(inbox.page(id: 'late-private'));
      await t.pump();
      nav.currentState!.pop();
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 200));
      expect(flow.items, isEmpty);
      expect(flow.current, false);
      expect(reads, 2);
      expect(find.text('Private message'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'same actor fresh session clears old epoch and preserves exact read nonce after reauthorization',
    (t) async {
      final client = await auth.client(t),
          live = Transport(),
          api = inbox.Gateway();
      final oldRead = Completer<dynamic>();
      var marks = 0;
      api.handle = (name, p) async {
        if (name == 'mark_my_app_inbox_read') {
          if (++marks == 1) return oldRead.future;
          return {
            'event_id': 'event-a',
            'read': true,
            'read_at': '2026-11-15T00:00:00Z',
          };
        }
        return inbox.page();
      };
      final flow = AppInboxController(
        gateway: api,
        actorId: () => client.auth.currentUser?.id,
      );
      addTearDown(flow.dispose);
      await showInbox(t, client, flow, live);
      final marking = flow.markRead('event-a');
      await t.pump();
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.tokenRefreshed, client.auth.currentSession),
      );
      await t.pump();
      expect(flow.items, isEmpty);
      expect(live.renewals, 1);
      oldRead.complete({
        'event_id': 'event-a',
        'read': true,
        'read_at': 'old-session',
      });
      await marking;
      await t.pump(const Duration(milliseconds: 151));
      await t.pump();
      expect(flow.items.single['read'], false);
      expect(live.subscriptions, 2);
      await flow.markRead('event-a');
      final sent = api.calls
          .where((c) => c['name'] == 'mark_my_app_inbox_read')
          .toList();
      expect(sent, hasLength(2));
      expect(sent[0]['p_request'], sent[1]['p_request']);
      expect(flow.items.single['read'], true);
      expect(t.takeException(), isNull);
    },
  );
}
