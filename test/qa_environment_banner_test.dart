import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/qa_environment_banner.dart';

void main() {
  testWidgets('shows a prominent localized QA label when enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QaEnvironmentFrame(
          enabled: true,
          locale: Locale('ar'),
          child: Scaffold(body: Text('site')),
        ),
      ),
    );
    expect(find.textContaining('بيئة تجريبية QA'), findsOneWidget);
    expect(find.text('site'), findsOneWidget);
  });

  testWidgets('keeps the production frame unchanged when disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QaEnvironmentFrame(
          enabled: false,
          locale: Locale('en'),
          child: Scaffold(body: Text('site')),
        ),
      ),
    );
    expect(find.text('QA TEST ENVIRONMENT • No real data or payments'), findsNothing);
    expect(find.text('site'), findsOneWidget);
  });
}
