import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_push_policy.dart';

void main() {
  test(
    'customer token needs session, matching profile, OS permission and consent',
    () {
      expect(
        shouldRegisterCustomerPushToken(
          hasValidSession: true,
          hasMatchingCustomerProfile: true,
          systemPermissionGranted: true,
          operationalConsent: true,
          marketingConsent: false,
        ),
        isTrue,
      );
      for (final failedCondition in [
        (false, true, true, true, false),
        (true, false, true, true, false),
        (true, true, false, true, false),
        (true, true, true, false, false),
      ]) {
        expect(
          shouldRegisterCustomerPushToken(
            hasValidSession: failedCondition.$1,
            hasMatchingCustomerProfile: failedCondition.$2,
            systemPermissionGranted: failedCondition.$3,
            operationalConsent: failedCondition.$4,
            marketingConsent: failedCondition.$5,
          ),
          isFalse,
        );
      }
    },
  );

  test('permission defaults operational on only when no choice is saved', () {
    expect(
      shouldDefaultOperationalPush(
        hasSavedPreference: false,
        systemPermissionGranted: true,
      ),
      isTrue,
    );
    expect(
      shouldDefaultOperationalPush(
        hasSavedPreference: true,
        systemPermissionGranted: true,
      ),
      isFalse,
    );
    expect(
      shouldDefaultOperationalPush(
        hasSavedPreference: false,
        systemPermissionGranted: false,
      ),
      isFalse,
    );
  });

  test(
    'notification deep links are restricted to known public/customer routes',
    () {
      expect(safeCustomerNotificationRoute('/booking?id=123'), '/booking');
      expect(safeCustomerNotificationRoute('/orders/abc'), '/orders');
      expect(safeCustomerNotificationRoute('/offers/campaign'), '/offers');
      expect(safeCustomerNotificationRoute('/owner'), isNull);
      expect(safeCustomerNotificationRoute('https://bad.example'), isNull);
    },
  );
}
