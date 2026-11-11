import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  test('Sabiha Hub app widget can be created', () {
    const app = SabihaHubApp();
    expect(app, isA<SabihaHubApp>());
  });
}
