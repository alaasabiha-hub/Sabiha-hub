import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/sabiha_web_startup.dart';

Widget shell(Future<Widget> future, VoidCallback ready) => MaterialApp(
  home: SabihaWebStartup(
    destination: future,
    fallbackHome: const Text('Public home'),
    onReady: ready,
  ),
);
void main() {
  testWidgets('web startup waits in navy without notifying early', (t) async {
    final future = Completer<Widget>();
    var calls = 0;
    await t.pumpWidget(shell(future.future, () => calls++));
    expect(find.byKey(const ValueKey('web-startup-pending')), findsOneWidget);
    expect(
      t.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xff071a36),
    );
    expect(calls, 0);
    future.complete(const Text('Verified staff'));
    await t.pump();
  });
  testWidgets(
    'web startup renders verified destination immediately without native delay',
    (t) async {
      final future = Completer<Widget>();
      var calls = 0;
      await t.pumpWidget(shell(future.future, () => calls++));
      future.complete(const Text('Verified staff'));
      await t.pump();
      expect(find.text('Verified staff'), findsOneWidget);
      expect(find.text('Public home'), findsNothing);
      expect(calls, 1);
    },
  );
  testWidgets('web startup error returns public fallback', (t) async {
    final future = Completer<Widget>();
    var calls = 0;
    await t.pumpWidget(shell(future.future, () => calls++));
    future.completeError(StateError('Verification unavailable'));
    await t.pump();
    expect(find.text('Public home'), findsOneWidget);
    expect(calls, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets('web startup completion after disposal does not notify', (
    t,
  ) async {
    final future = Completer<Widget>();
    var calls = 0;
    await t.pumpWidget(shell(future.future, () => calls++));
    await t.pumpWidget(const SizedBox());
    future.complete(const Text('Verified staff'));
    await t.pump();
    expect(calls, 0);
    expect(t.takeException(), isNull);
  });
  testWidgets('web startup onReady fires once across rebuilds', (t) async {
    final future = Completer<Widget>();
    var calls = 0;
    await t.pumpWidget(shell(future.future, () => calls++));
    future.complete(const Text('Verified owner'));
    await t.pump();
    await t.pumpWidget(shell(future.future, () => calls++));
    await t.pump();
    expect(calls, 1);
    expect(find.text('Verified owner'), findsOneWidget);
  });
}
