import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';
import 'package:sabiha_hub/cashier_points_verbal.dart';

class PointsGateway implements CashierCartGateway {
  bool alive = true, enabled = true, timeoutReserve = false;
  final events = StreamController<void>.broadcast();
  final calls = <Map<String, dynamic>>[];
  @override
  bool get current => alive;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) async {
    calls.add({'name': name, 'params': Map<String, dynamic>.from(p)});
    if (name == 'get_cashier_mixed_points_context') {
      return {
        'enabled': enabled,
        'state': 'ready',
        'draft_version': 1,
        'binding_version': 1,
        'buckets': [
          {
            'earning_policy_id': 'policy',
            'available_points': '25',
            'point_value_egp': 2,
          },
        ],
        'documents': [
          {'invoice_id': 'original', 'number': 'SH-INV-000123'},
        ],
      };
    }
    if (name == 'seal_cashier_loyalty_draft') {
      return {'intent_id': p['p_request'], 'seal_only': true};
    }
    if (name == 'reserve_cashier_mixed_points') {
      if (timeoutReserve) {
        timeoutReserve = false;
        throw TimeoutException('uncertain response');
      }
      return {
        'reservation_id': p['p_request'],
        'fingerprint': 'sealed-exact-terms',
        'balance_reserved': true,
        'payment_confirmed': false,
        'quote': {
          'loyalty_points': 10,
          'loyalty_payable_reduction': 20,
          'total': 144,
        },
        'verbal_notice_ar': 'إقرار بالموافقة الشفهية للشروط المحددة',
        'verbal_notice_en': 'Verbal assent to exact server terms',
      };
    }
    if (name == 'confirm_cashier_mixed_points_verbal') {
      return {
        'consent_id': p['p_request'],
        'accepted': true,
        'approval_method': 'cashier_attested_verbal',
        'payment_confirmed': false,
      };
    }
    if (name == 'release_cashier_mixed_points') return {'released': true};
    throw StateError(name);
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1024.0, 1440.0]) {
      testWidgets(
        'Verbal points $language $width independent identity and approval',
        (tester) async {
          tester.view.physicalSize = Size(width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final g = PointsGateway();
          addTearDown(g.events.close);
          Map<String, dynamic>? approval;
          bool pending = false;
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: CashierPointsVerbalPanel(
                    gateway: g,
                    branch: 'branch',
                    draft: 'draft',
                    onBusy: (_) {},
                    onSelectionPending: (v) => pending = v,
                    onApproval: (v) => approval = v,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            Directionality.of(
              tester.element(find.byType(CashierPointsVerbalPanel)),
            ),
            language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          );
          await tester.tap(find.byType(DropdownButtonFormField<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.textContaining('25 ').last);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('points_quantity')),
            language == 'ar' ? '١٠' : '10',
          );
          final reserve = find.text(
            language == 'ar'
                ? 'حجز النقاط ومعاينة السعر'
                : 'Reserve points and preview price',
          );
          await tester.ensureVisible(reserve);
          await tester.tap(reserve);
          await tester.pumpAndSettle();
          expect(pending, isTrue);
          expect(approval, isNull);
          expect(find.textContaining('144.00'), findsOneWidget);
          final approve = find.text(
            language == 'ar'
                ? 'تأكيد موافقة العميل الشفهية'
                : 'Confirm customer verbal approval',
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.ancestor(
                    of: approve,
                    matching: find.byType(FilledButton),
                  ),
                )
                .onPressed,
            isNull,
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('points_identity_method')),
          );
          await tester.tap(
            find.byKey(const ValueKey('points_identity_method')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .text(
                  language == 'ar'
                      ? 'وثيقة خدمة أصلية ومطابقة السيارة'
                      : 'Original service document and matching car',
                )
                .last,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('points_identity_record')),
          );
          await tester.tap(
            find.byKey(const ValueKey('points_identity_record')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('SH-INV-000123').last);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('points_identity_note')),
            'Original service document and matching car inspected',
          );
          for (final key in [
            'points_identity_checked',
            'points_verbal_checked',
          ]) {
            final check = find.byKey(ValueKey(key));
            await tester.ensureVisible(check);
            await tester.tap(check);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(approve);
          await tester.tap(approve);
          await tester.pumpAndSettle();
          expect(approval?['consent_id'], isNotNull);
          expect(pending, isFalse);
          final consent =
              g.calls.singleWhere(
                    (x) => x['name'] == 'confirm_cashier_mixed_points_verbal',
                  )['params']
                  as Map;
          expect(
            consent['p_identity_method'],
            'original_service_document_and_vehicle',
          );
          expect(consent['p_confirmed'], true);
          expect(
            consent.keys.any(
              (k) =>
                  '$k'.contains('email') ||
                  '$k'.contains('otp') ||
                  '$k'.contains('password'),
            ),
            false,
          );
          expect(
            g.calls.where((x) => '${x['name']}'.contains('payment')),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'Uncertain reservation retries exact nonce; no ordinary checkout authorization',
    (tester) async {
      final g = PointsGateway()..timeoutReserve = true;
      addTearDown(g.events.close);
      bool pending = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CashierPointsVerbalPanel(
                gateway: g,
                branch: 'b',
                draft: 'd',
                onApproval: (_) {},
                onBusy: (_) {},
                onSelectionPending: (v) => pending = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('25 ').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('points_quantity')),
        '10',
      );
      await tester.tap(find.text('Reserve points and preview price'));
      await tester.pumpAndSettle();
      expect(pending, true);
      await tester.tap(find.text('Retry the same request'));
      await tester.pumpAndSettle();
      final calls = g.calls
          .where((x) => x['name'] == 'reserve_cashier_mixed_points')
          .toList();
      expect(calls.length, 2);
      expect(calls[0]['params'], calls[1]['params']);
      g.alive = false;
      g.events.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Redeem loyalty points'), findsNothing);
    },
  );
  testWidgets(
    'Runtime off does not expose balances or enable a verbal button',
    (tester) async {
      final g = PointsGateway()..enabled = false;
      addTearDown(g.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CashierPointsVerbalPanel(
            gateway: g,
            branch: 'b',
            draft: 'd',
            onApproval: (_) {},
            onBusy: (_) {},
            onSelectionPending: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Confirm customer verbal approval'), findsNothing);
      expect(g.calls.map((x) => x['name']), [
        'get_cashier_mixed_points_context',
      ]);
    },
  );
}
