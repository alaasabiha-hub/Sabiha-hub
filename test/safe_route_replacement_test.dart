import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/safe_route_replacement.dart';

void main() {
  testWidgets('replaces route at most once for a staged visit handoff', (
    tester,
  ) async {
    final replacement = SafeRouteReplacement();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                final navigator = Navigator.of(context);
                expect(
                  replacement.replaceOnce(
                    navigator,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const Scaffold(body: Text('walk-in-reception')),
                    ),
                  ),
                  isTrue,
                );
                expect(
                  replacement.replaceOnce(
                    navigator,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const Scaffold(body: Text('duplicate-reception')),
                    ),
                  ),
                  isFalse,
                );
              },
              child: const Text('receive'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('receive'));
    await tester.pumpAndSettle();

    expect(find.text('walk-in-reception'), findsOneWidget);
    expect(find.text('duplicate-reception'), findsNothing);
  });
}
