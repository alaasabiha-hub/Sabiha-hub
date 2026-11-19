import 'dart:io';

import 'package:sabiha_hub/shift_pdf.dart';

Future<void> main(List<String> args) async {
  final totals = <String, dynamic>{
    'shift_id': 'LOCAL-SAMPLE-SHIFT',
    'status': 'awaiting_approval',
    'opening_cash': 100,
    'cash_payments_net': 150,
    'electronic_payments_net': 60,
    'cash_movements_net': -10,
    'expected_cash': 240,
    'actual_cash': 238,
    'difference': -2,
    'difference_reason': 'فرق تجريبي للمراجعة فقط',
  };
  await File(args.single).writeAsBytes(
    await buildShiftPdf(
      totals,
      'الفرع الرئيسي',
      await File('assets/NotoNaskhArabic-Regular.ttf').readAsBytes(),
      await File('assets/sabiha_brand_approved.png').readAsBytes(),
    ),
  );
}
