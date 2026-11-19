import 'dart:math';

const bookingTransitions = <String, List<String>>{
  'pending': ['confirmed', 'cancelled'],
  'confirmed': ['in_progress', 'cancelled'],
  'in_progress': ['completed', 'cancelled'],
  'completed': [],
  'cancelled': [],
};

bool isFutureBooking(DateTime date, int hour, int minute, DateTime now) =>
    DateTime(date.year, date.month, date.day, hour, minute).isAfter(now);

int? documentDaysRemaining(String? date, DateTime today) {
  final expiry = DateTime.tryParse(date ?? '');
  if (expiry == null) return null;
  return DateTime.utc(
    expiry.year,
    expiry.month,
    expiry.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
}

// Token length is configured by Auth; do not hard-code an eight-digit-only UI.
bool isValidEmailOtp(String code) => RegExp(r'^\d{6,8}$').hasMatch(code);

String newOrderRequestId() {
  final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

