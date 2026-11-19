import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/hr_payroll.dart';

void main() {
  test(
    'Service policy payroll explains frozen allocation without false zero rate',
    () {
      final line = {
        'model': 'owner_service_policy',
        'before_discount': 100,
        'rate_percent': null,
        'assigned_count': 2,
        'commission': 5,
        'service_policy_version': 1,
        'allocation_share_percent': 50,
      };
      for (final ar in [true, false]) {
        final text = hrCommissionExplanation(line, arabic: ar);
        expect(text, contains('50%'));
        expect(text, contains('5 EGP'));
        expect(text, isNot(contains('×')));
        expect(text, isNot(contains('null')));
      }
    },
  );
  test('Existing payroll explanations remain unchanged', () {
    final line = {
      'before_discount': 100,
      'rate_percent': 20,
      'assigned_count': 2,
      'commission': 10,
    };
    expect(hrCommissionExplanation(line, arabic: true), '100 × 20% ÷ 2 = 10');
    expect(hrCommissionExplanation(line, arabic: false), '100 × 20% ÷ 2 = 10');
  });
}
