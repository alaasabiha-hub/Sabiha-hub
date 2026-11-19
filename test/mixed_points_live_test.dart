import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sabiha_hub/mixed_points_live.dart';
import 'package:sabiha_hub/mixed_points_earnings.dart';

import 'mixed_points_earnings_test.dart' as fixture;

class FakePointHints implements MixedPointsHintTransport {
  VoidCallback? hint, reconnect;
  int connects = 0, closed = 0;
  @override
  Future<void> connect({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  }) async {
    connects++;
    hint = onHint;
    reconnect = onReconnect;
  }

  @override
  Future<void> reauthenticate() async {}
  @override
  Future<void> close() async {
    closed++;
    hint = null;
    reconnect = null;
  }
}

void main() {
  test('Only generic installed protocol hints are accepted; amounts are not authority', () {
    expect(isMixedPointsHint({'kind': 'mixed_points_changed'}), true);
    expect(
      isMixedPointsHint({
        'payload': {
          'kind': 'mixed_points_changed',
          'id': '00000000-0000-4000-8000-000000000001',
        },
      }),
      true,
    );
    expect(
      isMixedPointsHint({'kind': 'mixed_points_changed', 'points': 999}),
      false,
    );
    expect(
      isMixedPointsHint({'kind': 'mixed_points_changed', 'id': 'customer-id'}),
      false,
    );
    expect(isMixedPointsHint({'kind': 'inbox_changed'}), false);
  });
  testWidgets(
    'Burst hints re-read authorized balance once plus one catch-up, never message numbers',
    (t) async {
      final hints = FakePointHints();
      int reads = 0;
      Completer<http.Response>? pending;
      final c = await fixture.client(t, (_) async {
        reads++;
        if (pending != null) return pending.future;
        return fixture.response(fixture.points());
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MixedPointsEarningsPanel(
              client: c,
              hintTransport: hints,
              fallbackInterval: Duration.zero,
            ),
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      expect(reads, 1);
      pending = Completer<http.Response>();
      hints.hint!();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      for (var i = 0; i < 20; i++) {
        hints.hint!();
      }
      expect(reads, 2);
      final value = fixture.points();
      (value['buckets'] as List).first['net_earned_points'] = '77';
      final waiting = pending;
      pending = null;
      waiting.complete(fixture.response(value));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pumpAndSettle();
      expect(reads, 3);
      // Catch-up is authoritative too, so the final response replaces the earlier77.
      expect(find.text('100 recorded points'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      expect(hints.closed, 1);
      await t.runAsync(() => c.dispose());
    },
  );
  testWidgets(
    'Reconnect refresh and failure recovery use RPC, background hints wait for resume',
    (t) async {
      final hints = FakePointHints();
      int reads = 0;
      bool failure = false;
      final c = await fixture.client(t, (_) async {
        reads++;
        return failure
            ? fixture.response({'message': 'denied', 'code': '42501'}, 403)
            : fixture.response(fixture.points());
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MixedPointsEarningsPanel(
              client: c,
              hintTransport: hints,
              fallbackInterval: Duration.zero,
            ),
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      failure = true;
      hints.reconnect!();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      expect(find.text('100 recorded points'), findsNothing);
      failure = false;
      hints.hint!();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      expect(find.text('100 recorded points'), findsOneWidget);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final before = reads;
      hints.hint!();
      await t.pump();
      expect(reads, before);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      expect(reads, before + 1);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => c.dispose());
    },
  );
}
