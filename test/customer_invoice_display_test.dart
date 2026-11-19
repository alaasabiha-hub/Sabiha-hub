import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/invoices.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'Customer invoice stays readable with full UUID $language $width',
        (t) async {
          t.view.physicalSize = Size(width, 1100);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          const token = '00000000-0000-4000-8000-000000000123';
          const id = 'BOOKING-00000000-0000-4000-8000-000000000456';
          late SupabaseClient client;
          await t.runAsync(() async {
            client = SupabaseClient(
              'http://localhost:54321',
              'test',
              accessToken: () async => 'test',
              httpClient: MockClient((request) async {
                Object result;
                if (request.url.path.endsWith('/list_invoice_documents')) {
                  result = [
                    {'invoice_id': id, 'document_token': token},
                  ];
                } else if (request.url.path.endsWith(
                  '/resolve_invoice_document',
                )) {
                  result = {
                    'invoice_id': id,
                    'document_token': token,
                    'issued_at': '2026-11-14T10:00:00Z',
                    'payment_status': 'unpaid',
                    'payment_method': 'cash_on_receipt',
                    'service_status': 'pending',
                    'snapshot': {
                      'branch': {
                        'name_ar': 'اختبار معزول',
                        'name_en': 'Isolated QA',
                        'address_ar': '',
                      },
                      'lines': [
                        {
                          'name': 'خدمة اختبار / Isolated service',
                          'quantity': 1,
                          'unit_price': 137.45,
                          'subtotal': 137.45,
                        },
                      ],
                      'discount': 0,
                      'total': 137.45,
                    },
                  };
                } else {
                  expect(request.url.path, endsWith('/invoice_review_context'));
                  result = {'can_review': false};
                }
                return http.Response(
                  jsonEncode(result),
                  200,
                  headers: {'content-type': 'application/json'},
                  request: request,
                );
              }),
            );
          });
          addTearDown(() async {
            await t.pumpWidget(const SizedBox());
            await t.runAsync(() => client.dispose());
          });
          await t.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: InvoiceDocumentsScreen(client: client),
            ),
          );
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await t.pumpAndSettle();
          final title = find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').startsWith('$id\n'),
          );
          await t.ensureVisible(title);
          await t.pumpAndSettle();
          final text = t.widget<Text>(title);
          final foreground =
              text.style?.color ??
              DefaultTextStyle.of(t.element(title)).style.color!;
          final background = Theme.of(t.element(title)).scaffoldBackgroundColor;
          final light = foreground.computeLuminance(),
              dark = background.computeLuminance();
          final contrast = (light > dark
              ? (light + .05) / (dark + .05)
              : (dark + .05) / (light + .05));
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: 'Invoice identity/payment status must be readable on the customer background',
          );
          final selector = find.byWidgetPredicate(
            (w) =>
                w is DropdownButtonFormField<String> &&
                w.key is ValueKey &&
                (w.key as ValueKey).value == token,
          );
          await t.scrollUntilVisible(
            selector,
            -150,
            scrollable: find
                .byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                )
                .first,
          );
          await t.ensureVisible(selector);
          await t.pumpAndSettle();
          await t.tap(selector);
          await t.pumpAndSettle();
          expect(
            t.takeException(),
            isNull,
            reason: 'Long invoice identity must fit both the selected field and dropdown menu',
          );
        },
      );
    }
  }
}
