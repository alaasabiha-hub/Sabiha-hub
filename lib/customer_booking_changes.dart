import 'customer_service_reward.dart' show refreshRewardWallet;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

bool customerBookingChangeVisible(Map booking) =>
    booking['status'] == 'pending';
String newBookingChangeRequest() {
  final r = Random.secure();
  final bytes = List.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

/// Embed in own-customer details; server remains authoritative for eligibility.
class CustomerBookingChanges extends StatefulWidget {
  final Map<String, dynamic> booking;
  final bool arabic;
  final VoidCallback onChanged;
  const CustomerBookingChanges({
    super.key,
    required this.booking,
    required this.arabic,
    required this.onChanged,
  });
  @override
  State<CustomerBookingChanges> createState() => _CustomerBookingChangesState();
}

class _CustomerBookingChangesState extends State<CustomerBookingChanges> {
  bool busy = false;
  Map<String, dynamic>? pending;
  String t(String ar, String en) => widget.arabic ? ar : en;
  Future<void> submit(Map<String, dynamic> payload) async {
    setState(() => busy = true);
    pending = payload;
    try {
      await Supabase.instance.client.rpc(
        'change_customer_booking',
        params: payload,
      );
      refreshRewardWallet();
      pending = null;
      if (!mounted) return;
      widget.onChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('تم تحديث الحجز', 'Booking updated'))),
      );
    } catch (e) {
      // Preserve identity and exact payload after uncertain transport failures.
      if (e is PostgrestException) pending = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is PostgrestException
                  ? e.message
                  : t(
                      'لم يتم تأكيد النتيجة. أعد المحاولة بنفس الطلب.',
                      'Result unconfirmed. Retry the same request.',
                    ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancel() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('إلغاء الحجز؟', 'Cancel booking?')),
        content: Text(
          t(
            'متاح فقط للحجز القادم المعلق غير المسند وغير المدفوع. المدفوع والمؤكد يتطلب الإدارة.',
            'Only future pending, unassigned and unpaid bookings qualify. Paid or confirmed bookings require management.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('رجوع', 'Back')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('تأكيد الإلغاء', 'Confirm cancellation')),
          ),
        ],
      ),
    );
    if (yes == true) {
      await submit({
        'p_request': newBookingChangeRequest(),
        'p_booking': widget.booking['id'],
        'p_action': 'cancel',
        'p_date': null,
        'p_time': null,
      });
    }
  }

  Future<void> reschedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    setState(() => busy = true);
    try {
      final day =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final rows = await Supabase.instance.client.rpc(
        'available_booking_slots',
        params: {
          'p_branch': widget.booking['branch_id'],
          'p_service': widget.booking['catalog_item_id'],
          'p_date': day,
        },
      );
      final slots = (rows as List)
          .map((r) => r['slot_time'].toString())
          .toList();
      if (!mounted) return;
      final slot = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(t('المواعيد المتاحة', 'Available appointments')),
          children: slots.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      t('لا توجد مواعيد متاحة', 'No available appointments'),
                    ),
                  ),
                ]
              : slots
                    .map(
                      (s) => SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, s),
                        child: Text(s.substring(0, 5)),
                      ),
                    )
                    .toList(),
        ),
      );
      if (slot != null) {
        await submit({
          'p_request': newBookingChangeRequest(),
          'p_booking': widget.booking['id'],
          'p_action': 'reschedule',
          'p_date': day,
          'p_time': slot,
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('تعذر تحميل المواعيد', 'Unable to load appointments'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!customerBookingChangeVisible(widget.booking)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t(
            'التعديل الذاتي للحجز القادم المعلق وغير المسند وغير المدفوع فقط. الحالات الأخرى عبر الإدارة.',
            'Self service is limited to future pending, unassigned, unpaid bookings. Contact management for other states.',
          ),
        ),
        const SizedBox(height: 8),
        if (pending != null)
          FilledButton(
            onPressed: busy ? null : () => submit(pending!),
            child: Text(t('إعادة نفس الطلب', 'Retry same request')),
          )
        else
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : reschedule,
                child: Text(t('تغيير الموعد', 'Reschedule')),
              ),
              TextButton(
                onPressed: busy ? null : cancel,
                child: Text(t('إلغاء الحجز', 'Cancel booking')),
              ),
            ],
          ),
        if (busy) const LinearProgressIndicator(),
      ],
    );
  }
}
