String invoiceNumber(Map document) =>
    '${document['invoice_number'] ?? document['invoice_id'] ?? '—'}';
String invoiceState(String? value, bool ar) {
  const states = {
    'settled_by_credit': (
      'لا يوجد مبلغ مستحق بعد التسويات',
      'No amount due after credits',
    ),
    'credit_settlement': (
      'تسوية دون تحصيل',
      'Credit settlement without collection',
    ),
    'unpaid': ('بانتظار الدفع', 'Awaiting payment'),
    'covered_by_reward': ('مغطاة بمكافأة الزيارات', 'Covered by visit reward'),
    'reward_coverage': ('مكافأة زيارات', 'Visit reward'),
    'cancelled_reward': ('مكافأة ملغاة', 'Cancelled reward'),
    'paid': ('مدفوع', 'Paid'),
    'cash_on_receipt': ('نقدًا عند الاستلام', 'Cash on receipt'),
    'cash': ('نقدي', 'Cash'),
    'electronic': ('دفع إلكتروني', 'Electronic payment'),
    'card': ('بطاقة', 'Card'),
    'card_terminal': ('بطاقة على ماكينة الكاشير', 'Card terminal'),
    'awaiting_terminal_payment': (
      'بانتظار الدفع بالبطاقة عند الكاشير',
      'Awaiting card payment at cashier',
    ),
    'pending': ('بانتظار التأكيد', 'Awaiting confirmation'),
    'confirmed': ('مؤكد', 'Confirmed'),
    'received': ('تم الاستلام', 'Received'),
    'in_progress': ('قيد التنفيذ', 'In progress'),
    'quality_check': ('مراجعة الجودة', 'Quality check'),
    'delivered': ('تم التسليم', 'Delivered'),
    'preparing': ('قيد التجهيز', 'Preparing'),
    'void_reported': ('إلغاء تجريبي موثق', 'Sandbox void reported'),
    'completed': ('مكتمل', 'Completed'),
    'cancelled': ('ملغي', 'Cancelled'),
    'refunded': ('مسترد', 'Refunded'),
    'partially_refunded': ('مسترد جزئيًا', 'Partially refunded'),
    'void': ('ملغاة', 'Void'),
    'active': ('سارية', 'Active'),
    'verification_required': ('دفع غير موثّق', 'Payment not verified'),
    'sandbox_succeeded': (
      'نجاح تجريبي — ليس تحصيلًا حقيقيًا',
      'Sandbox success — not a real collection',
    ),
    'creating': ('جارٍ التجهيز', 'Preparing'),
    'failed': ('فشل الدفع', 'Payment failed'),
    'uncertain': ('بانتظار التحقق', 'Verification pending'),
    'refund_reported': ('استرداد قيد التحقق', 'Refund verification pending'),
  };
  final label = states[value];
  return label == null
      ? (ar ? 'غير مسجل' : 'Not recorded')
      : ar
      ? label.$1
      : label.$2;
}

/// A server-provided canonical receipt is required; zero alone proves nothing.
bool invoiceHasRewardRecord(Map document) {
  final coverage = document['reward_coverage'];
  final snapshot = document['snapshot'];
  final due =
      document['invoice_total'] ??
      document['amount_due'] ??
      (snapshot is Map ? snapshot['total'] : null) ??
      document['base_amount'];
  return coverage is Map &&
      const {
        'covered_by_reward',
        'cancelled_reward',
      }.contains(coverage['state']) &&
      due is num &&
      due == 0 &&
      coverage['amount_due'] is num &&
      coverage['amount_due'] == 0;
}

bool invoiceHasRewardCoverage(Map document) =>
    document['payment_status'] == 'covered_by_reward' &&
    invoiceHasRewardRecord(document) &&
    (document['reward_coverage'] as Map)['state'] == 'covered_by_reward';

String invoiceDate(Map doc, bool ar) {
  final local = doc['issued_at_cairo'];
  final date = DateTime.tryParse('${local ?? doc['issued_at']}');
  if (date == null) return ar ? 'التاريخ غير مسجل' : 'Date not recorded';
  const arabic = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];
  const english = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final period = ar
      ? (date.hour < 12 ? 'ص' : 'م')
      : (date.hour < 12 ? 'AM' : 'PM');
  final zone = local != null
      ? (ar ? 'القاهرة' : 'Cairo')
      : (date.isUtc ? 'UTC' : '');
  return '${date.day} ${(ar ? arabic : english)[date.month - 1]} ${date.year} · $hour:${date.minute.toString().padLeft(2, '0')} $period $zone'
      .trim();
}
