import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/catalog_refresh.dart';

void main() {
  testWidgets('Published reader coalesces, pauses, resumes and disposes', (
    tester,
  ) async {
    var reads = 0;
    var allowed = true;
    Completer<void>? wait;
    final refresh = CatalogRefresh(
      interval: const Duration(seconds: 2),
      allowed: () => allowed,
      refresh: () async {
        reads++;
        if (wait != null) await wait!.future;
      },
    );
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    wait = Completer<void>();
    unawaited(refresh.request());
    unawaited(refresh.request());
    await tester.pump();
    expect(reads, 2);
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 2);
    wait!.complete();
    await tester.pump();
    wait = null;
    refresh.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 2);
    refresh.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, 3);
    allowed = false;
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 3);
    refresh.dispose();
    allowed = true;
    await refresh.request();
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 3);
  });
  testWidgets('A transient reader error does not stop later synchronization', (
    tester,
  ) async {
    var reads = 0;
    final refresh = CatalogRefresh(
      interval: const Duration(seconds: 2),
      allowed: () => true,
      refresh: () async {
        reads++;
        if (reads == 1) throw StateError('isolated offline');
      },
    );
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 2);
    refresh.dispose();
    expect(tester.takeException(), isNull);
  });
}
