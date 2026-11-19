import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_booking_ui.dart';

void main() {
  final bookings = [
    {'id': 'LOCAL-TEST-A', 'service_name': 'Vehicle wash', 'status': 'confirmed', 'booking_date': '2026-11-13', 'booking_time': '10:00', 'quoted_price': 150},
    {'id': 'LOCAL-TEST-B', 'service_name': 'Polishing', 'status': 'completed'},
    {'id': 'LOCAL-TEST-C', 'service_name': 'Wash', 'status': 'cancelled'},
  ];
  test('current/past and search keep real status and never invent prices', () {
    expect(filterCustomerBookings(bookings, '', 'current').map((b) => b['id']), ['LOCAL-TEST-A']);
    expect(filterCustomerBookings(bookings, '', 'past').length, 2);
    expect(filterCustomerBookings(bookings, 'polish', 'past').single['id'], 'LOCAL-TEST-B');
    expect(filterCustomerBookings(bookings, ' LOCAL-TEST-A ', 'all').length, 1);
    expect(filterCustomerBookings(bookings, 'absent', 'all'), isEmpty);
  });
  for (final size in [const Size(320,568),const Size(390,844),const Size(430,932)]) {
    for (final arabic in [true,false]) {
      testWidgets('booking card fits $size arabic=$arabic and inspection navigates', (tester) async {
        tester.view.physicalSize=size;tester.view.devicePixelRatio=1;
        addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
        var inspected=false;
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: Directionality(textDirection: arabic ? TextDirection.rtl : TextDirection.ltr, child: ListView(children: [CustomerBookingCard(booking: {...bookings.first, 'service_name': 'العناية المتكاملة للسيارة · Interior and exterior vehicle care'}, arabic: arabic, onInspection: () => inspected=true, support: TextButton(onPressed: () {}, child: Text(arabic ? 'الدعم' : 'Support')))])))));
        await tester.pumpAndSettle();expect(tester.takeException(),isNull);
        expect(find.text('150.00 EGP'),findsOneWidget);
        await tester.tap(find.byIcon(Icons.car_crash_outlined));expect(inspected,isTrue);
      });
    }
  }
  testWidgets('missing stored quote is explicit, never zero EGP', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CustomerBookingCard(booking: bookings[1],arabic:false,onInspection:(){},support:const SizedBox()))));
    expect(find.text('Price not recorded'),findsOneWidget);expect(find.text('0.00 EGP'),findsNothing);
  });
}
