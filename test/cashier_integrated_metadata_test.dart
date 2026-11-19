import 'package:flutter_test/flutter_test.dart';

import 'owner_tax_invoice_settings_test.dart' as tax;
import 'cashier_checkout_test.dart' as checkout;

class WorkGateway extends checkout.CheckoutGateway {
  WorkGateway() {
    issued = true;
  }
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    final data = await super.call(name, params);
    if (name == 'get_cashier_checkout_state') {
      data['work'] = [
        {
          'order_id': 'work',
          'reference': 'SH-BKG-000001',
          'name': 'غسيل',
          'name_en': 'Frozen wash',
          'status': 'received',
          'can_open': true,
        },
      ];
    }
    return data;
  }
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('integrated reviewed tax scope $lang', (tester) async {
      final gateway = tax.Gateway()..integrated = true;
      await tax.mount(tester, gateway, lang, lang == 'ar' ? 390 : 1440);
      expect(
        find.text(
          lang == 'ar'
              ? 'التصنيف المعتمد يطبّق على فواتير نقطة البيع الجديدة للعملاء المسجلين، دون إعادة حساب الفواتير السابقة.'
              : 'Reviewed tax applies to new point-of-sale invoices for registered customers; earlier invoices are not recalculated.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          lang == 'ar' ? 'إعدادات قيد الربط' : 'Settings are awaiting',
        ),
        findsNothing,
      );
      expect(gateway.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets('frozen service work name follows locale $lang', (
      tester,
    ) async {
      final gateway = WorkGateway();
      await checkout.mount(tester, gateway, lang, lang == 'ar' ? 390 : 1440);
      expect(find.text(lang == 'ar' ? 'غسيل' : 'Frozen wash'), findsOneWidget);
      expect(gateway.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
