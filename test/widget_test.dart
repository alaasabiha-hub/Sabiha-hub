import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app opens on the Arabic home screen by default', (tester) async {
    await tester.pumpWidget(const SabihaHubApp());
    await tester.pumpAndSettle();

    expect(find.text('SABIHA HUB'), findsOneWidget);
    expect(find.text('دخول العميل'), findsOneWidget);
    expect(find.text('دخول الموظفين'), findsOneWidget);
  });
}
