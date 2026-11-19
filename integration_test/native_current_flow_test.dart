import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sabiha_hub/main.dart' as app;
import 'package:sabiha_hub/admin_console.dart';
import 'package:sabiha_hub/branch_settings.dart';
import 'package:sabiha_hub/cashier_shifts.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const email = String.fromEnvironment('TEST_CUSTOMER_EMAIL'),
      password = String.fromEnvironment('TEST_PASSWORD'),
      owner = String.fromEnvironment('TEST_OWNER_EMAIL'),
      ownerPassword = String.fromEnvironment('TEST_OWNER_PASSWORD'),
      branch = String.fromEnvironment('TEST_INVENTORY_BRANCH'),
      service = String.fromEnvironment('TEST_BOOKING_SERVICE'),
      invoice = String.fromEnvironment('TEST_PAYMENT_INVOICE');
  Future<void> waitFor(WidgetTester t, Finder f) async {
    for (var i = 0; i < 100; i++) {
      await t.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) {
        await t.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    throw TestFailure('Expected native screen/control did not appear');
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
  }

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: child,
  );
  testWidgets(
    'Native customer login and booking, cashier collection and owner report against isolated local data',
    (t) async {
      expect(email, isNotEmpty);
      expect(branch, isNotEmpty);
      await app.main();
      await waitFor(t, find.text('تسجيل الدخول'));
      await t.ensureVisible(find.text('تسجيل الدخول').first);
      await t.tap(find.text('تسجيل الدخول').first);
      await waitFor(t, find.byType(TextField));
      await t.enterText(find.byType(TextField).at(0), email);
      await t.enterText(find.byType(TextField).at(1), password);
      FocusManager.instance.primaryFocus?.unfocus();
      await t.ensureVisible(find.text('تسجيل الدخول'));
      await t.tap(find.text('تسجيل الدخول'));
      await waitFor(t, find.byType(app.CustomerDashboardScreen));
      expect(app.supabase.auth.currentUser?.email, email);
      expect(t.takeException(), isNull, reason: 'customer dashboard');
      debugPrint('NATIVE_CUSTOMER_LOGIN_OK');
      BranchSelection.current = branch;
      unawaited(
        app.appNavigatorKey.currentState!.push(
          MaterialPageRoute(
            builder: (_) =>
                const app.CreateBookingScreen(initialServiceId: service),
          ),
        ),
      );
      await waitFor(t, find.textContaining('QA native wash'));
      final beforeBookings = await app.supabase
          .from('bookings')
          .select('id')
          .eq('branch_id', branch)
          .eq('customer_id', app.supabase.auth.currentUser!.id);
      final time = find.byIcon(Icons.schedule);
      await t.scrollUntilVisible(
        time,
        200,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await t.tap(time);
      await waitFor(t, find.text('اختر موعدك'));
      // Capacity availability is separate from the vehicle overlap guard.
      // Repeated isolated runs retain bookings, so choose a free vehicle interval.
      final ownBookings = await app.supabase
          .from('bookings')
          .select('booking_date,booking_time,duration_minutes,status')
          .eq('customer_id', app.supabase.auth.currentUser!.id);
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final day =
          '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
      int minutes(String value) {
        final bits = value.split(':');
        return int.parse(bits[0]) * 60 + int.parse(bits[1]);
      }

      final timeChoices = find.byWidgetPredicate((w) {
        if (w is! Text || !RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? '')) {
          return false;
        }
        final start = minutes(w.data!);
        return !ownBookings.any(
          (b) =>
              b['booking_date'] == day &&
              !['cancelled', 'completed'].contains(b['status']) &&
              minutes(b['booking_time']) < start + 30 &&
              minutes(b['booking_time']) +
                      (b['duration_minutes'] as num).toInt() >
                  start,
        );
      });
      expect(timeChoices, findsWidgets);
      await t.tap(timeChoices.first);
      await settle(t);
      final send = find.text('إرسال طلب الحجز');
      await t.scrollUntilVisible(
        send,
        200,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await t.tap(send);
      await settle(t);
      for (var attempt = 0; attempt < 30; attempt++) {
        final saved = await app.supabase
            .from('bookings')
            .select('id')
            .eq('branch_id', branch)
            .eq('customer_id', app.supabase.auth.currentUser!.id);
        if (saved.length > beforeBookings.length) break;
        await t.pump(const Duration(milliseconds: 300));
      }
      debugPrint(
        'NATIVE_BOOKING_UI_MESSAGES: ${find.byType(SnackBar).evaluate().map((e) => (e.widget as SnackBar).content).toList()}',
      );
      final bookings = await app.supabase
          .from('bookings')
          .select('id,branch_id,status,quoted_price')
          .eq('branch_id', branch)
          .eq('customer_id', app.supabase.auth.currentUser!.id);
      expect(bookings.length, beforeBookings.length + 1);
      expect(bookings.last['quoted_price'], 12);
      expect(t.takeException(), isNull, reason: 'booking and slot selection');
      debugPrint('NATIVE_BOOKING_CREATED_OK');
      await app.supabase.auth.signOut();
      await app.supabase.auth.signInWithPassword(
        email: owner,
        password: ownerPassword,
      );
      await t.pumpWidget(
        host(CashierShiftsScreen(client: app.supabase, role: 'owner')),
      );
      await settle(t);
      final existingShifts = await app.supabase
          .from('business_cashier_shifts')
          .select('shift_id')
          .eq('branch_id', branch)
          .eq('cashier_id', app.supabase.auth.currentUser!.id)
          .eq('status', 'open');
      if (existingShifts.isEmpty) {
        final open = find.text('فتح ورديتي في هذا الفرع');
        await t.ensureVisible(open);
        await t.tap(open);
        await settle(t);
      }
      final payment = find.text('تحصيل / استرداد');
      await t.ensureVisible(payment.first);
      await t.tap(payment.first);
      await waitFor(t, find.text('تسجيل مرة واحدة'));
      await t.tap(find.text('تسجيل مرة واحدة'));
      await settle(t);
      final events = await app.supabase
          .from('business_payment_events')
          .select('amount,event_type,method')
          .eq('invoice_id', invoice);
      expect(events.length, 1);
      expect(events.single['amount'], 5.37);
      expect(events.single['method'], 'cash');
      expect(
        t.takeException(),
        isNull,
        reason: 'native cashier and payment dialog',
      );
      debugPrint('NATIVE_LOCAL_CASH_COLLECTION_OK');
      await t.pumpWidget(
        host(
          AdminConsole(
            client: app.supabase,
            fullName: 'Local native QA',
            onLogout: () {},
          ),
        ),
      );
      await settle(t);
      expect(find.text('نظرة عامة على المدفوعات'), findsOneWidget);
      final name = t.widget<Text>(
        find.byKey(const ValueKey('admin-brand-name')),
      );
      expect(name.maxLines, 1);
      expect(name.softWrap, false);
      expect(t.takeException(), isNull);
      debugPrint('NATIVE_ADMIN_SCREEN_READY');
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 12)));
      await t.ensureVisible(find.byKey(const ValueKey('admin-nav-reports')));
      await t.tap(find.byKey(const ValueKey('admin-nav-reports')));
      await settle(t);
      expect(find.byKey(const ValueKey('report-summary')), findsOneWidget);
      debugPrint('NATIVE_CURRENT_FLOW_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
