import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/push_build_policy.dart';

void main() {
  test('Personal Team QA disables iOS Push while retaining configuration', () {
    expect(
      pushAllowedForBuild(
        configured: true,
        isIos: true,
        disableIosPush: true,
      ),
      isFalse,
    );
  });

  test('normal iOS builds retain configured Push support', () {
    expect(
      pushAllowedForBuild(
        configured: true,
        isIos: true,
        disableIosPush: false,
      ),
      isTrue,
    );
  });

  test('QA-only iOS flag does not disable Android Push', () {
    expect(
      pushAllowedForBuild(
        configured: true,
        isIos: false,
        disableIosPush: true,
      ),
      isTrue,
    );
  });
}
