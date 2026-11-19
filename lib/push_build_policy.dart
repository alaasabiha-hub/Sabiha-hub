/// Build-time policy that can disable APNs-dependent registration in the
/// free Personal Team iOS QA build without removing the FCM implementation.
bool pushAllowedForBuild({
  required bool configured,
  required bool isIos,
  required bool disableIosPush,
}) {
  if (isIos && disableIosPush) return false;
  return configured;
}
