import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/payment_checkout.dart';
import 'package:sabiha_hub/invoice_presentation.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  test('display number, localized states and Cairo invoice dates', () {
    expect(
      invoiceNumber({
        'invoice_id': 'legacy',
        'invoice_number': 'SH-INV-000001',
      }),
      'SH-INV-000001',
    );
    expect(invoiceNumber({'invoice_id': 'legacy'}), 'legacy');
    expect(invoiceState('cash_on_receipt', true), 'نقدًا عند الاستلام');
    expect(invoiceState('pending', false), 'Awaiting confirmation');
    expect(
      invoiceDate({'issued_at_cairo': '2026-11-14T13:05:00'}, false),
      '14 November 2026 · 1:05 PM Cairo',
    );
    expect(
      invoiceDate({'issued_at_cairo': '2026-11-14T13:05:00'}, true),
      contains('نوفمبر'),
    );
  });
  for (final language in ['ar', 'en']) {
    testWidgets(
      'Sandbox disabled, server quote, no gateway calls $language mobile',
      (t) async {
        t.view.physicalSize = const Size(390, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final calls = <String>[];
        late SupabaseClient client;
        await t.runAsync(() async {
          client = SupabaseClient(
            'http://localhost:54321',
            'test',
            accessToken: () async => 'test',
            httpClient: MockClient((r) async {
              calls.add(r.url.path);
              final result = r.url.path.endsWith('invoice_payment_quote')
                  ? {
                      'invoice_number': 'SH-INV-000001',
                      'base_amount': 137.45,
                      'cash_total': 137.45,
                      'card_total': 137.45,
                      'customer_fee': 0,
                    }
                  : {'status': 'not_started'};
              return http.Response(
                jsonEncode(result),
                200,
                headers: {'content-type': 'application/json'},
                request: r,
              );
            }),
          );
        });
        addTearDown(() async {
          await t.pumpWidget(const SizedBox());
          await t.runAsync(client.dispose);
        });
        await t.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: PaymentCheckoutScreen(client: client, invoiceId: 'internal'),
          ),
        );
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await t.pumpAndSettle();
        expect(find.text('SH-INV-000001'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(
          find.text(language == 'ar' ? 'سيتم تفعيل خدمة الدفع الإلكتروني قريبًا' : 'Online payment will be available soon'),
          findsOneWidget,
        );
        expect(calls.length, 2);
        expect(calls.every((p) => p.startsWith('/rest/v1/rpc/')), isTrue);
        expect(t.takeException(), isNull);
      },
    );
  }
  test(
    'numbered bilingual invoice PDF retains secure QR in all formats',
    () async {
      final font = File('assets/NotoNaskhArabic-Regular.ttf').readAsBytesSync(),
          logo = File('assets/sabiha_brand_approved.png').readAsBytesSync();
      final doc = <String, dynamic>{
        'invoice_id': 'internal-uuid',
        'invoice_number': 'SH-INV-000001',
        'document_token': '00000000-0000-4000-8000-000000000123',
        'portal_origin': 'https://sabiha.example.test',
        'issued_at_cairo': '2026-11-14T13:05:00',
        'payment_status': 'unpaid',
        'payment_method': 'cash_on_receipt',
        'service_status': 'pending',
        'snapshot': {
          'branch': {'name_ar': 'اختبار معزول', 'name_en': 'Isolated QA'},
          'lines': [
            {
              'name': 'خدمة اختبار / Test service',
              'quantity': 1,
              'unit_price': 137.45,
              'subtotal': 137.45,
            },
          ],
          'total': 137.45,
          'discount': 0,
          'tax_amount': null,
        },
      };
      final out = Platform.environment['SABIHA_NUMBERED_PDF_OUTPUT'];
      for (final ar in [true, false]) {
        for (final paper in ['A4', '58', '80']) {
          final bytes = await buildInvoicePdf(
            doc,
            font,
            logo,
            paper: paper,
            arabic: ar,
          );
          expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
          if (out != null) {
            await File('$out/Sabiha-numbered-${ar ? 'ar' : 'en'}-$paper.pdf')
                .writeAsBytes(bytes);
          }
        }
      }
      expect(
        invoiceDocumentUrl(doc),
        contains('?invoice=00000000-0000-4000-8000-000000000123'),
      );
      expect(invoiceDocumentUrl(doc), isNot(contains('SH-INV')));
    },
  );
}
