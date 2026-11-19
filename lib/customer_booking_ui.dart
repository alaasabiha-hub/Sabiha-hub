import 'package:flutter/material.dart';

import 'customer_visuals.dart';
import 'invoice_presentation.dart' show invoiceHasRewardRecord;

String bookingReference(Map booking) {
  final saved = booking['booking_number'];
  return saved is String && saved.startsWith('SH-BKG-')
      ? saved
      : shortBookingReference('${booking['id'] ?? ''}');
}

String shortBookingReference(String id) {
  final compact = id.replaceAll('-', '').toUpperCase();
  return compact.isEmpty
      ? '—'
      : 'SH-${compact.substring(0, compact.length < 8 ? compact.length : 8)}';
}

String bookingAppointmentLabel(BuildContext context, Map booking) {
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  final date = DateTime.tryParse('${booking['booking_date']}');
  final parts = '${booking['booking_time']}'.split(':');
  final hour = parts.isEmpty ? null : int.tryParse(parts[0]);
  final minute = parts.length < 2 ? null : int.tryParse(parts[1]);
  if (date == null ||
      hour == null ||
      minute == null ||
      hour > 23 ||
      hour < 0 ||
      minute > 59 ||
      minute < 0) {
    return ar ? 'الموعد غير مسجل' : 'Appointment not recorded';
  }
  final local = MaterialLocalizations.of(context);
  // These are Cairo civil appointment values, not UTC timestamps to convert.
  return '${local.formatFullDate(date)} · ${local.formatTimeOfDay(TimeOfDay(hour: hour, minute: minute), alwaysUse24HourFormat: false)}';
}

String bookingPaymentLabel(String? status, bool ar) {
  const labels = {
    'paid': ('تم تأكيد الدفع', 'Payment confirmed'),
    'covered_by_reward': ('مغطى بمكافأة الزيارات', 'Covered by visit reward'),
    'unpaid': ('بانتظار تأكيد الدفع', 'Awaiting payment confirmation'),
    'refunded': ('مسترد', 'Refunded'),
    'cancelled': ('ملغى', 'Cancelled'),
    'verification_required': (
      'الدفع الإلكتروني غير موثّق',
      'Electronic payment not verified',
    ),
  };
  final label = labels[status];
  return label == null
      ? (ar ? 'حالة الدفع غير مسجلة' : 'Payment status not recorded')
      : (ar ? label.$1 : label.$2);
}

bool isPastBooking(Map booking) =>
    const {'completed', 'cancelled', 'no_show'}.contains(booking['status']);
List<Map<String, dynamic>> filterCustomerBookings(
  List<Map<String, dynamic>> bookings,
  String query,
  String view,
) {
  final search = query.trim().toLowerCase();
  return bookings.where((b) {
    final past = isPastBooking(b);
    if (view == 'current' && past || view == 'past' && !past) return false;
    final vehicle = b['vehicle'] is Map ? b['vehicle'] as Map : const {};
    return '${b['id']} ${bookingReference(b)} ${b['service_name']} ${b['booking_date']} ${vehicle['plate_number'] ?? ''} ${vehicle['brand'] ?? ''} ${vehicle['model'] ?? ''}'
        .toLowerCase()
        .contains(search);
  }).toList();
}

class BookingRewardAmounts extends StatelessWidget {
  final Map<String, dynamic> booking;
  final bool arabic;
  const BookingRewardAmounts({
    super.key,
    required this.booking,
    required this.arabic,
  });
  @override
  Widget build(BuildContext context) {
    if (!invoiceHasRewardRecord(booking)) {
      return const SizedBox.shrink();
    }
    final coverage = booking['reward_coverage'] as Map;
    final gross = booking['quoted_price'] ?? coverage['gross_amount'];
    final discount = booking['invoice_discount'] ?? coverage['reward_discount'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          arabic ? 'المستحق: 0.00 EGP' : 'Amount due: 0.00 EGP',
          style: const TextStyle(
            color: customerGold,
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          '${arabic ? 'السعر قبل المكافأة' : 'Before reward'}: $gross EGP · ${arabic ? 'خصم المكافأة' : 'Reward discount'}: $discount EGP',
          style: const TextStyle(color: customerIce, fontSize: 12),
        ),
      ],
    );
  }
}

/// Saved, own-customer values only. A short reference is display/search text,
/// never a database identifier or authorization token.
class CustomerBookingCard extends StatelessWidget {
  final Map<String, dynamic> booking;
  final bool arabic;
  final VoidCallback onInspection;
  final VoidCallback? onDetails;
  final Widget support;
  const CustomerBookingCard({
    super.key,
    required this.booking,
    required this.arabic,
    required this.onInspection,
    required this.support,
    this.onDetails,
  });
  String t(String a, String e) => arabic ? a : e;
  @override
  Widget build(BuildContext context) {
    const labels = {
      'pending': ('في الانتظار', 'Awaiting confirmation'),
      'confirmed': ('مؤكد', 'Confirmed'),
      'in_progress': ('قيد التنفيذ', 'In progress'),
      'completed': ('مكتمل', 'Completed'),
      'cancelled': ('ملغي', 'Cancelled'),
      'no_show': ('لم يحضر', 'No show'),
    };
    final status = '${booking['status']}';
    final label = labels[status];
    final price = num.tryParse('${booking['quoted_price']}');
    final title = '${booking['service_name'] ?? ''}';
    final car = booking['vehicle'] is Map
        ? booking['vehicle'] as Map
        : const {};
    final carLabel = [
      car['brand'],
      car['model'],
      car['year'],
      car['plate_number'],
    ].where((v) => v != null && '$v'.trim().isNotEmpty).join(' · ');
    final color = status == 'completed' || status == 'confirmed'
        ? const Color(0xff087f4c)
        : status == 'cancelled'
        ? const Color(0xffa43b45)
        : const Color(0xff135d9f);
    return CustomerPanel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  customerServicePhoto(title),
                  width: 86,
                  height: 100,
                  fit: BoxFit.cover,
                  semanticLabel: t(
                    'صورة توضيحية لخدمة العناية بالسيارة',
                    'Illustrative car care photograph',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        label == null ? status : t(label.$1, label.$2),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Tooltip(
                      message: '${booking['id'] ?? ''}',
                      child: Text(
                        bookingReference(booking),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          color: customerIce,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            carLabel.isEmpty
                ? t('بيانات السيارة غير مسجلة', 'Vehicle details not recorded')
                : carLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            bookingAppointmentLabel(context, booking),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          Text(
            t('بتوقيت القاهرة', 'Cairo time'),
            style: const TextStyle(color: customerIce, fontSize: 11),
          ),
          const SizedBox(height: 12),
          if (invoiceHasRewardRecord(booking))
            BookingRewardAmounts(booking: booking, arabic: arabic)
          else
            Text(
              price == null
                  ? t('السعر غير مسجل', 'Price not recorded')
                  : '${price.toStringAsFixed(2)} EGP',
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                color: customerGold,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          const SizedBox(height: 7),
          Text(
            bookingPaymentLabel(booking['payment_status'] as String?, arabic),
            style: const TextStyle(
              color: customerIce,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: arabic ? Alignment.centerRight : Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onDetails ?? onInspection,
              icon: const Icon(Icons.car_crash_outlined, size: 17),
              label: Text(t('التفاصيل والفاتورة', 'Details & invoice')),
              style: OutlinedButton.styleFrom(
                foregroundColor: customerGold,
                side: const BorderSide(color: customerGold),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
