import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/invoice_presentation.dart';
import 'package:sabiha_hub/customer_booking_ui.dart';
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/payment_checkout.dart';

Map<String, dynamic> coverage() => {
  'state': 'covered_by_reward',
  'amount_due': 0,
  'gross_amount': 137.45,
  'reward_discount': 137.45,
  'threshold_visits': 7,
};
void main() {
  test('zero due alone does not prove reward coverage or cash collection', () {
    expect(
      invoiceHasRewardRecord({'payment_status': 'unpaid', 'invoice_total': 0}),
      isFalse,
    );
    expect(
      invoiceHasRewardCoverage({
        'payment_status': 'covered_by_reward',
        'invoice_total': 0,
      }),
      isFalse,
    );
    expect(
      invoiceHasRewardCoverage({
        'payment_status': 'covered_by_reward',
        'invoice_total': 1,
        'reward_coverage': coverage(),
      }),
      isFalse,
    );
    expect(
      invoiceHasRewardCoverage({
        'payment_status': 'covered_by_reward',
        'invoice_total': 0,
        'reward_coverage': coverage(),
      }),
      isTrue,
    );
    expect(
      invoiceHasRewardCoverage({
        'payment_status': 'cancelled',
        'invoice_total': 0,
        'reward_coverage': {...coverage(), 'state': 'cancelled_reward'},
      }),
      isFalse,
    );
    expect(invoiceState('covered_by_reward', false), 'Covered by visit reward');
    expect(invoiceState('covered_by_reward', true), 'مغطاة بمكافأة الزيارات');
    expect(invoiceState('reward_coverage', false), 'Visit reward');
  });
  for (final locale in ['ar', 'en']) {
    testWidgets(
      'Covered reward payment $locale skips billing, provider and cash instructions',
      (tester) async {
        tester.view.physicalSize = Size(locale == 'ar' ? 390 : 1440, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        late SupabaseClient client;
        await tester.runAsync(() async {
          client = SupabaseClient(
            'https://local.example.test',
            'anon',
            accessToken: () async => 'test',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              calls.add(request.url.path);
              expect(request.url.path, endsWith('/invoice_payment_quote'));
              return http.Response(
                jsonEncode({
                  'invoice_number': 'SH-INV-000007',
                  'payment_status': 'covered_by_reward',
                  'reward_coverage': coverage(),
                  'amount_due': 0,
                  'base_amount': 0,
                  'gross_amount': 137.45,
                  'discount': 137.45,
                  'cash_total': 0,
                  'card_total': 0,
                  'customer_fee': 0,
                  'collectible': false,
                }),
                200,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }),
          );
        });
        addTearDown(() async {
          await tester.runAsync(client.dispose);
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: PaymentCheckoutScreen(
              client: client,
              invoiceId: 'internal-id',
              sandboxEnabled: true,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(invoiceState('covered_by_reward', locale == 'ar')),
          findsOneWidget,
        );
        expect(find.byType(TextFormField), findsNothing);
        expect(find.textContaining('Sandbox'), findsNothing);
        expect(
          find.textContaining(locale == 'ar' ? 'المستحق' : 'Amount due'),
          findsOneWidget,
        );
        expect(calls, ['/rest/v1/rpc/invoice_payment_quote']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets('Reward booking $locale retains gross but displays zero due', (
      tester,
    ) async {
      tester.view.physicalSize = Size(locale == 'ar' ? 390 : 1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final booking = <String, dynamic>{
        'id': '12345678-1234-4000-8000-123456789012',
        'booking_number': 'SH-BKG-000007',
        'service_name': 'خدمة / Service',
        'booking_date': '2026-11-16',
        'booking_time': '10:30:00',
        'status': 'pending',
        'quoted_price': 137.45,
        'invoice_total': 0,
        'invoice_discount': 137.45,
        'payment_status': 'covered_by_reward',
        'reward_coverage': coverage(),
      };
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: ListView(
              children: [
                CustomerBookingCard(
                  booking: booking,
                  arabic: locale == 'ar',
                  onInspection: () {},
                  support: const SizedBox(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          locale == 'ar' ? 'المستحق: 0.00 EGP' : 'Amount due: 0.00 EGP',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          locale == 'ar' ? 'السعر قبل المكافأة' : 'Before reward',
        ),
        findsOneWidget,
      );
      expect(booking['quoted_price'], 137.45);
      expect(tester.takeException(), isNull);
    });
  }
  test('Reward PDF A4 and thermal preserve full price, discount and same QR in both languages', () async {
    final document = <String, dynamic>{
      'invoice_id': 'INTERNAL-ID',
      'invoice_number': 'SH-INV-000007',
      'document_token': '00000000-0000-4000-8000-000000000123',
      'portal_origin': 'https://sabiha.example.test',
      'issued_at_cairo': '2026-11-14T13:05:00',
      'payment_status': 'covered_by_reward',
      'payment_method': 'reward_coverage',
      'reward_coverage': coverage(),
      'snapshot': {
        'branch': {'name_ar': 'فرع اختبار', 'name_en': 'QA Branch'},
        'lines': [
          {
            'name': 'غسيل / Wash',
            'quantity': 1,
            'unit_price': 137.45,
            'subtotal': 137.45,
          },
        ],
        'total': 0,
        'discount': 137.45,
        'tax_amount': null,
      },
    };
    final original = jsonEncode(document);
    final url = invoiceDocumentUrl(document);
    final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(),
        logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
    final output = Platform.environment['SABIHA_REWARD_PDF_OUTPUT_DIR'];
    for (final arabic in [true, false]) {
      for (final paper in ['A4', '58', '80']) {
        final bytes = await buildInvoicePdf(
          document,
          font,
          logo,
          paper: paper,
          reprint: true,
          arabic: arabic,
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1000));
        if (output != null) {
          await Directory(output).create(recursive: true);
          await File(
            '$output/reward-invoice-${arabic ? 'ar' : 'en'}-$paper.pdf',
          ).writeAsBytes(bytes);
        }
        expect(invoiceDocumentUrl(document), url);
        expect(jsonEncode(document), original);
      }
    }
  });
}
