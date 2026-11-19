import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiha_hub/cashier_shifts.dart';

void main() {
  test('shift statuses have readable Arabic and English labels', () {
    const ar = Locale('ar');
    const en = Locale('en');

    expect(cashierShiftStatusLabel('open', ar), 'مفتوحة');
    expect(
      cashierShiftStatusLabel('awaiting_approval', ar),
      'بانتظار اعتماد المالك',
    );
    expect(cashierShiftStatusLabel('closed', ar), 'مغلقة ومعتمدة');
    expect(cashierShiftStatusLabel('open', en), 'Open');
    expect(
      cashierShiftStatusLabel('awaiting_approval', en),
      'Awaiting owner approval',
    );
    expect(cashierShiftStatusLabel('closed', en), 'Closed and approved');
    expect(cashierShiftStatusLabel('unexpected', en), 'Unknown status');
  });
}
