import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiha_hub/customer_booking_changes.dart';

void main() {
  test('only pending bookings expose customer changes', () {
    expect(customerBookingChangeVisible({'status': 'pending'}), isTrue);
    for (final status in [
      'confirmed',
      'in_progress',
      'completed',
      'cancelled',
      'no_show',
    ]) {
      expect(customerBookingChangeVisible({'status': status}), isFalse);
    }
  });
  test('request IDs are valid UUID v4 and distinct', () {
    final a = newBookingChangeRequest();
    final b = newBookingChangeRequest();
    expect(
      a,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(a, isNot(b));
  });
  testWidgets('pending controls explain server policy', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomerBookingChanges(
            booking: const {'status': 'pending', 'id': 'test'},
            arabic: false,
            onChanged: () {},
          ),
        ),
      ),
    );
    expect(find.text('Reschedule'), findsOneWidget);
    expect(find.text('Cancel booking'), findsOneWidget);
    expect(find.textContaining('unassigned, unpaid'), findsOneWidget);
  });
  testWidgets('confirmed bookings do not show self service', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomerBookingChanges(
            booking: const {'status': 'confirmed'},
            arabic: false,
            onChanged: () {},
          ),
        ),
      ),
    );
    expect(find.text('Cancel booking'), findsNothing);
  });
}
