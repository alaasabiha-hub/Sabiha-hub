import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/customer_session_guard.dart';

class _FakeGateway implements CustomerSessionGateway {
  _FakeGateway(this.result);

  CustomerSessionCheck result;
  final StreamController<Object?> _changes =
      StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get changes => _changes.stream;

  @override
  Future<CustomerSessionCheck> verify() async => result;

  void update(CustomerSessionCheck next) {
    result = next;
    _changes.add(Object());
  }

  Future<void> close() => _changes.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpGuard(WidgetTester tester, _FakeGateway gateway) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomerSessionGuard(
          gateway: gateway,
          child: const Text('private customer content'),
          loginBuilder: (_) => const Text('sign in required'),
          notCustomerBuilder: (_) => const Text('customer profile required'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('private content requires an authorized customer profile', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      const CustomerSessionCheck(CustomerSessionStatus.signedOut),
    );
    await pumpGuard(tester, gateway);
    expect(find.text('sign in required'), findsOneWidget);
    expect(find.text('private customer content'), findsNothing);

    gateway.update(
      const CustomerSessionCheck(
        CustomerSessionStatus.authorized,
        userId: 'customer-1',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('private customer content'), findsOneWidget);
    await gateway.close();
  });

  testWidgets('staff profile is not accepted as a customer profile', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      const CustomerSessionCheck(CustomerSessionStatus.notCustomer),
    );
    await pumpGuard(tester, gateway);
    expect(find.text('customer profile required'), findsOneWidget);
    expect(find.text('private customer content'), findsNothing);
    await gateway.close();
  });

  testWidgets('a session becoming signed out hides previously mounted data', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      const CustomerSessionCheck(
        CustomerSessionStatus.authorized,
        userId: 'customer-1',
      ),
    );
    await pumpGuard(tester, gateway);
    expect(find.text('private customer content'), findsOneWidget);

    gateway.update(const CustomerSessionCheck(CustomerSessionStatus.signedOut));
    await tester.pumpAndSettle();
    expect(find.text('sign in required'), findsOneWidget);
    expect(find.text('private customer content'), findsNothing);
    await gateway.close();
  });

  testWidgets('network failure is retryable and is not treated as sign-out', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      const CustomerSessionCheck(CustomerSessionStatus.unavailable),
    );
    await pumpGuard(tester, gateway);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('sign in required'), findsNothing);
    expect(find.text('private customer content'), findsNothing);
    await gateway.close();
  });
}
