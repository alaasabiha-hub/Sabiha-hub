import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_workspace_layout.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('POS independent draft scroll at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CashierWorkspaceLayout(
              children: [
                const Text('Catalogue'),
                const Divider(key: ValueKey('pos_draft_divider')),
                for (var i = 0; i < 200; i++) Text('Draft line $i'),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(ListView), findsNWidgets(width >= 1100 ? 2 : 1));
      final scroll = width >= 1100
          ? find.byKey(const ValueKey('pos_draft_scroll'))
          : find.byType(ListView);
      await tester.drag(scroll, const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(find.text('Draft line 199'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
