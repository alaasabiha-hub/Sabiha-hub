import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_reports.dart';

void main() {
  for (final locale in const [Locale('ar'), Locale('en')]) {
    testWidgets('hourly visits are labeled as verified in ${locale.languageCode}',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          home: Scaffold(
            body: SalesHourChart(
              rows: const [
                {
                  'hour': 10,
                  'net_billed': 240,
                  'refunded_invoice_value': 0,
                  'completed_service_visits': 3,
                },
              ],
              arabic: locale.languageCode == 'ar',
            ),
          ),
        ),
      );

      expect(
        find.textContaining(
          locale.languageCode == 'ar'
              ? 'انتهاء الخدمة الموثق'
              : 'verified service end time',
        ),
        findsOneWidget,
      );
      final tooltip = find.byType(Tooltip);
      await tester.tap(tooltip);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          locale.languageCode == 'ar'
              ? '3 زيارة مكتملة موثقة'
              : '3 verified completed visits',
        ),
        findsOneWidget,
      );
    });
  }
}
