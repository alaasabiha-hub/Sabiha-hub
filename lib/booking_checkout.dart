import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

/// One request identity for the lifetime of a booking form, including retries
/// after a lost response. Amount and invoice creation are confirmed by the RPC.
class ServiceBookingCheckout {
  final SupabaseClient client;
  final String requestId;

  ServiceBookingCheckout(this.client) : requestId = newOrderRequestId();

  Future<Map<String, dynamic>> submit({
    required String serviceId,
    required String branchId,
    required String vehicleId,
    required String date,
    required String time,
    required num expectedPrice,
    required String notes,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
      'place_customer_service_booking',
      params: {
        'p_request': requestId,
        'p_service': serviceId,
        'p_branch': branchId,
        'p_vehicle': vehicleId,
        'p_date': date,
        'p_time': time,
        'p_expected_price': expectedPrice,
        'p_notes': notes.trim().isEmpty ? null : notes.trim(),
      },
    ),
  );
}
