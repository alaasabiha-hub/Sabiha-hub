import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/vehicle_pricing.dart';

void main() {
  test(
    'uses only the selected class price and never falls back to flat price',
    () {
      final service = {
        'price': 100,
        'vehicle_prices': {'sedan': 120, 'suv': 175},
      };
      expect(
        servicePriceForVehicle(service, {'vehicle_class_code': 'sedan'}),
        120,
      );
      expect(
        servicePriceForVehicle(service, {'vehicle_class_code': 'suv'}),
        175,
      );
      expect(
        servicePriceForVehicle(service, {'vehicle_class_code': 'van'}),
        isNull,
      );
      expect(
        servicePriceForVehicle({'price': 100}, {'vehicle_class_code': 'sedan'}),
        isNull,
      );
      expect(servicePriceForVehicle(service, null), isNull);
    },
  );

  test('rejects negative, non-numeric and non-finite class amounts', () {
    for (final value in [-1, 'NaN', 'Infinity', 'not-a-price']) {
      expect(
        servicePriceForVehicle(
          {
            'vehicle_prices': {'sedan': value},
          },
          {'vehicle_class_code': 'sedan'},
        ),
        isNull,
      );
    }
  });
}
