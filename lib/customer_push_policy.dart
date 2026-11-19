bool shouldRegisterCustomerPushToken({
  required bool hasValidSession,
  required bool hasMatchingCustomerProfile,
  required bool systemPermissionGranted,
  required bool operationalConsent,
  required bool marketingConsent,
}) =>
    hasValidSession &&
    hasMatchingCustomerProfile &&
    systemPermissionGranted &&
    (operationalConsent || marketingConsent);

bool shouldDefaultOperationalPush({
  required bool hasSavedPreference,
  required bool systemPermissionGranted,
}) => !hasSavedPreference && systemPermissionGranted;

String? safeCustomerNotificationRoute(String destination) {
  if (!RegExp(r'^/(offers|booking|orders)(/|\?|$)').hasMatch(destination)) {
    return null;
  }
  if (destination.startsWith('/booking')) return '/booking';
  if (destination.startsWith('/orders')) return '/orders';
  return '/offers';
}
