import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_console.dart';

class OwnerReportsScreen extends StatelessWidget {
  final SupabaseClient client;
  const OwnerReportsScreen({super.key, required this.client});
  @override
  Widget build(BuildContext context) =>
      AdminConsole(client: client, initialSection: 'reports');
}

/// Hour-of-day totals across the selected Cairo window, with exact-value tooltips.
class SalesHourChart extends StatelessWidget {
  final List<Map> rows;
  final bool arabic;
  const SalesHourChart({super.key, required this.rows, required this.arabic});
  @override
  Widget build(BuildContext context) {
    final peak = rows.fold<double>(1, (max, r) {
      final v = (r['net_billed'] as num? ?? 0).toDouble();
      return v > max ? v : max;
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              arabic
                  ? 'قيمة الفواتير حسب ساعة الإصدار · القاهرة'
                  : 'Invoice value by issue hour · Cairo',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              arabic
                  ? 'عدد الزيارات المكتملة يحسب من وقت انتهاء الخدمة الموثق فقط، وليس من ساعة الفاتورة أو الدفع.'
                  : 'Completed visits require a verified service end time; invoice and payment hours are not used.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: rows.map((r) {
                  final amount = (r['net_billed'] as num? ?? 0).toDouble();
                  final visits = (r['completed_service_visits'] as num? ?? 0)
                      .toInt();
                  final hour = '${r['hour']}'.padLeft(2, '0');
                  return Tooltip(
                    triggerMode: TooltipTriggerMode.tap,
                    message: arabic
                        ? '$hour:00 · ${amount.toStringAsFixed(2)} EGP · $visits زيارة مكتملة موثقة'
                        : '$hour:00 · ${amount.toStringAsFixed(2)} EGP · $visits verified completed visits',
                    child: SizedBox(
                      width: 38,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox(
                            height: 150,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: 23,
                                height: amount / peak * 150,
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xff2272bd),
                                      Color(0xff071a36),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(hour),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
