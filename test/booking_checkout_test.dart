import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/booking_checkout.dart';

void main() {
  test(
    'Lost booking response retries the same checkout identity and server price',
    () async {
      final writes = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'http://localhost:54321',
        'test',
        accessToken: () async => 'isolated-test',
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            '/rest/v1/rpc/place_customer_service_booking',
          );
          writes.add(Map<String, dynamic>.from(jsonDecode(request.body)));
          if (writes.length == 1) {
            throw const SocketException('Response lost after commit');
          }
          return http.Response(
            jsonEncode({
              'booking_id': 'same-booking',
              'invoice_id': 'same-invoice',
              'quoted_price': 137.45,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final checkout = ServiceBookingCheckout(client);
      Future<Map<String, dynamic>> send() => checkout.submit(
        serviceId: 'service',
        branchId: 'branch',
        vehicleId: 'vehicle',
        date: '2026-12-01',
        time: '10:00:00',
        expectedPrice: 137.45,
        notes: '  customer note  ',
      );
      await expectLater(send(), throwsA(isA<SocketException>()));
      final result = await send();
      expect(writes, hasLength(2));
      expect(writes[0], writes[1]);
      expect(writes[1]['p_notes'], 'customer note');
      expect(result['quoted_price'], 137.45);
      expect(
        ServiceBookingCheckout(client).requestId,
        isNot(checkout.requestId),
      );
    },
  );
}
