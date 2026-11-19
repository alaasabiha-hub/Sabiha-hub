import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_history.dart';
import 'package:sabiha_hub/invoices.dart';

const token = '00000000-0000-4000-8000-000000000123';
Map<String, dynamic> document() => {
  'schema_version': 'offline-customer-invoice-v1',
  'source_kind': 'offline_walk_in',
  'invoice_id': 'internal',
  'invoice_number': 'SH-INV-000007',
  'document_token': token,
  'portal_origin': 'http://127.0.0.1:8501',
  'issued_at': '2026-11-14T10:00:00Z',
  'payment_status': 'unpaid',
  'payment_method': 'cash_on_receipt',
  'service_status': 'received',
  'snapshot': {
    'branch': {'name_ar': 'فرع', 'name_en': 'Branch', 'address_ar': ''},
    'lines': [
      {
        'name': 'Actual service',
        'quantity': 1,
        'unit_price': 120,
        'subtotal': 120,
      },
    ],
    'discount': 0,
    'total': 120,
    'tax_amount': null,
  },
};
SupabaseClient mockClient(
  Future<http.Response> Function(http.Request) handler,
) => SupabaseClient(
  'http://localhost:54321',
  'test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
  httpClient: MockClient((request) async {
    final result = await handler(request);
    return http.Response(
      result.body,
      result.statusCode,
      headers: result.headers,
      request: request,
    );
  }),
);
Future<SupabaseClient> widgetClient(
  WidgetTester t,
  Future<http.Response> Function(http.Request) handler,
) async => (await t.runAsync(() async => mockClient(handler)))!;
http.Response response(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

class FakeHistory extends OfflineHistoryGateway {
  int loads = 0, pages = 0, consents = 0;
  bool recorded = false, denyNext = false;
  String? consentId;
  Map<String, dynamic>? supplied;
  @override
  Future<Map<String, dynamic>> context() async {
    loads++;
    return recorded
        ? {
            'state': 'available',
            'cars': [
              {'plate_number': 'QA123', 'brand': 'QA'},
            ],
          }
        : {
            'state': 'consent_required',
            'consent': {
              'version': 'offline-history-v1',
              'notice_ar': 'نطاق السجل الفعلي',
              'notice_en': 'Actual history scope',
            },
          };
  }

  @override
  Future<Map<String, dynamic>> consent(
    String request,
    Map<String, dynamic> notice,
  ) async {
    consents++;
    consentId = request;
    supplied = notice;
    recorded = true;
    return {'state': 'consent_recorded'};
  }

  @override
  Future<Map<String, dynamic>> history(Map<String, dynamic>? cursor) async {
    pages++;
    if (denyNext) {
      throw const PostgrestException(message: 'Unavailable', code: '42501');
    }
    return {
      'state': 'available',
      'items': [
        {
          'order_id': cursor == null ? 'one' : 'two',
          'invoice_number': cursor == null ? 'SH-INV-000007' : 'SH-INV-000008',
          'invoice_token': token,
          'service_name': 'الخدمات الفعلية',
          'service_name_en': 'Actual service',
          'source_kind': 'offline_mixed_cashier',
          'car': {'plate_number': 'QA123'},
          'branch': {'name_ar': 'فرع', 'name_en': 'Branch'},
          'service_status': 'received',
          'payment_status': 'unpaid',
          'invoice_total': 120,
        },
      ],
      'next_cursor': cursor == null
          ? {'created_at': '2026-11-14T10:00:00Z', 'order_id': 'one'}
          : null,
    };
  }
}

class PendingHistory extends OfflineHistoryGateway {
  PendingHistory(this.pending);
  final Completer<Map<String, dynamic>> pending;
  int historyCalls = 0;
  @override
  Future<Map<String, dynamic>> context() => pending.future;
  @override
  Future<Map<String, dynamic>> consent(
    String request,
    Map<String, dynamic> notice,
  ) async => {};
  @override
  Future<Map<String, dynamic>> history(Map<String, dynamic>? cursor) async {
    historyCalls++;
    return {};
  }
}

Future<void> settle(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 70)),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets(
        'History explicit scope and read-only invoice route $language $width',
        (t) async {
          t.view.physicalSize = Size(width, 1100);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final gateway = FakeHistory();
          final client = await widgetClient(t, (_) async => response({}));
          addTearDown(() async {
            await t.pumpWidget(const SizedBox());
            await t.runAsync(() => client.dispose());
          });
          String? opened;
          await t.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: OfflineHistoryScreen(
                client: client,
                gateway: gateway,
                onOpenInvoice: (value) async {
                  opened = value;
                },
              ),
            ),
          );
          await t.pumpAndSettle();
          final button = find.text(
            language == 'ar' ? 'تسجيل الموافقة' : 'Record consent',
          );
          expect(
            t
                .widget<FilledButton>(
                  find.ancestor(
                    of: button,
                    matching: find.byType(FilledButton),
                  ),
                )
                .onPressed,
            isNull,
          );
          await t.tap(find.byType(CheckboxListTile));
          await t.pump();
          await t.tap(button);
          await t.pumpAndSettle();
          expect(gateway.consents, 1);
          expect(gateway.supplied, {
            'accepted': true,
            'version': 'offline-history-v1',
            'language': language,
            'text': language == 'ar'
                ? 'نطاق السجل الفعلي'
                : 'Actual history scope',
          });
          expect(find.text('QA123'), findsOneWidget);
          expect(find.text('SH-INV-000007'), findsOneWidget);
          final open = find.text(
            language == 'ar' ? 'فتح الفاتورة' : 'Open invoice',
          );
          await t.ensureVisible(open);
          await t.tap(open);
          await t.pumpAndSettle();
          expect(opened, token);
          expect(find.byType(TextField), findsNothing);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('Pagination denial clears all cached reception data', (t) async {
    final gateway = FakeHistory()..recorded = true;
    final client = await widgetClient(t, (_) async => response({}));
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => client.dispose());
    });
    await t.pumpWidget(
      MaterialApp(
        home: OfflineHistoryScreen(client: client, gateway: gateway),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('SH-INV-000007'), findsOneWidget);
    gateway.denyNext = true;
    await t.ensureVisible(find.text('Load more'));
    await t.tap(find.text('Load more'));
    await t.pumpAndSettle();
    expect(find.text('SH-INV-000007'), findsNothing);
    expect(find.text('QA123'), findsNothing);
    expect(
      find.text('Access could not be verified. Refresh or contact the owner.'),
      findsOneWidget,
    );
  });
  for (final mode in [
    'customer42501',
    'owner42501',
    'customer500',
    'customer401',
  ]) {
    test('Typed fallback only customer42501: $mode', () async {
      var typed = 0;
      final customer = mode.startsWith('customer');
      final code = mode.endsWith('42501') ? '42501' : 'XX000';
      final client = mockClient((request) async {
        if (request.url.path.endsWith('/resolve_invoice_document')) {
          return response(
            {'code': code, 'message': 'Unavailable'},
            mode.endsWith('500')
                ? 500
                : mode.endsWith('401')
                ? 401
                : 403,
          );
        }
        typed++;
        expect(request.url.path, endsWith('/get_my_offline_invoice_by_token'));
        return response(document());
      });
      addTearDown(client.dispose);
      if (mode == 'customer42501') {
        expect(
          (await resolveInvoiceForViewer(
            client,
            token,
            'customer',
          ))['invoice_number'],
          'SH-INV-000007',
        );
        expect(typed, 1);
      } else {
        await expectLater(
          resolveInvoiceForViewer(
            client,
            token,
            customer ? 'customer' : 'owner',
          ),
          throwsA(isA<PostgrestException>()),
        );
        expect(typed, 0);
      }
    });
  }
  test('Network failure never falls back', () async {
    var calls = 0;
    final client = mockClient((request) async {
      calls++;
      throw http.ClientException('offline');
    });
    addTearDown(client.dispose);
    await expectLater(
      resolveInvoiceForViewer(client, token, 'customer'),
      throwsA(isA<http.ClientException>()),
    );
    expect(calls, 1);
  });
  test('Fresh typed export reader rejects changed token proof', () async {
    final client = mockClient(
      (request) async => response(
        document()..['document_token'] = '00000000-0000-4000-8000-000000000999',
      ),
    );
    addTearDown(client.dispose);
    await expectLater(
      reauthorizeOfflineInvoice(client, token),
      throwsFormatException,
    );
  });
  testWidgets(
    'Paste QR token uses typed reader and hides payment and reviews',
    (t) async {
      var typed = 0, review = 0;
      final client = await widgetClient(t, (request) async {
        final path = request.url.path;
        if (path.endsWith('/list_invoice_documents')) return response([]);
        if (path.endsWith('/resolve_invoice_document')) {
          return response({'code': '42501', 'message': 'Unavailable'}, 403);
        }
        if (path.endsWith('/get_my_offline_invoice_by_token')) {
          typed++;
          return response(document());
        }
        review++;
        return response({'can_review': false});
      });
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => client.dispose());
      });
      await t.pumpWidget(
        MaterialApp(home: InvoiceDocumentsScreen(client: client)),
      );
      await settle(t);
      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.labelText ==
                'رمز الفاتورة أو رابط QR / Invoice token or QR link',
      );
      expect(field, findsOneWidget);
      await t.ensureVisible(field);
      await t.enterText(field, 'http://127.0.0.1:8501/?invoice=$token');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await settle(t);
      // The actual open button is also exercised if the input uses no submitted action.
      if (typed == 0) {
        await t.tap(find.text('فتح الفاتورة / Open Invoice'));
        await settle(t);
      }
      expect(typed, 1);
      expect(review, 0);
      expect(find.textContaining('Payment options & prices'), findsNothing);
      expect(find.byType(InvoiceReviewPanel), findsNothing);
    },
  );
  testWidgets('Typed PDF export reauthorizes and clears view after revoke', (
    t,
  ) async {
    var typed = 0;
    final client = await widgetClient(t, (request) async {
      if (request.url.path.endsWith('/list_invoice_documents')) {
        return response([]);
      }
      if (request.url.path.endsWith('/resolve_invoice_document')) {
        return response({'code': '42501', 'message': 'Unavailable'}, 403);
      }
      typed++;
      return typed == 1
          ? response(document())
          : response({'code': '42501', 'message': 'Unavailable'}, 403);
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => client.dispose());
    });
    await t.pumpWidget(
      MaterialApp(
        home: InvoiceDocumentsScreen(client: client, initialToken: token),
      ),
    );
    await settle(t);
    final download = find.text('تنزيل PDF مع QR / Download PDF with QR');
    await t.scrollUntilVisible(
      download,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(download);
    await t.tap(download);
    await settle(t);
    expect(typed, 2);
    expect(find.textContaining('SH-INV-000007\n'), findsNothing);
    expect(find.byType(InvoiceReviewPanel), findsNothing);
  });
  testWidgets('Late history response cannot restore data after signout', (
    t,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final gateway = PendingHistory(pending);
    final client = await widgetClient(t, (_) async => response({}));
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => client.dispose());
    });
    await t.pumpWidget(
      MaterialApp(
        home: OfflineHistoryScreen(client: client, gateway: gateway),
      ),
    );
    await client.auth.signOut(scope: SignOutScope.local);
    await t.pump();
    pending.complete({
      'state': 'available',
      'cars': [
        {'plate_number': 'PRIVATE OLD CAR'},
      ],
    });
    await t.pumpAndSettle();
    expect(find.text('PRIVATE OLD CAR'), findsNothing);
    expect(gateway.historyCalls, 0);
  });
  testWidgets('Late typed invoice response cannot restore data after signout', (
    t,
  ) async {
    final pending = Completer<http.Response>();
    final client = await widgetClient(t, (request) async {
      if (request.url.path.endsWith('/list_invoice_documents')) {
        return response([]);
      }
      if (request.url.path.endsWith('/resolve_invoice_document')) {
        return response({'code': '42501', 'message': 'Unavailable'}, 403);
      }
      return pending.future;
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => client.dispose());
    });
    await t.pumpWidget(
      MaterialApp(
        home: InvoiceDocumentsScreen(client: client, initialToken: token),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 70)),
    );
    await client.auth.signOut(scope: SignOutScope.local);
    await t.pump();
    pending.complete(response(document()));
    await settle(t);
    expect(find.textContaining('SH-INV-000007\n'), findsNothing);
  });
  test(
    'Whitelisted typed document generates PDF with existing QR URL',
    () async {
      final font = await rootBundle.load('assets/NotoNaskhArabic-Regular.ttf');
      final logo = await rootBundle.load('assets/sabiha_brand_approved.png');
      final bytes = await buildInvoicePdf(
        document(),
        font.buffer.asUint8List(),
        logo.buffer.asUint8List(),
        arabic: false,
      );
      expect(bytes.length, greaterThan(1000));
      expect(utf8.decode(bytes.take(4).toList()), '%PDF');
      expect(
        invoiceDocumentUrl(document()),
        'http://127.0.0.1:8501/?invoice=$token',
      );
    },
  );
  for (final role in ['customer', 'owner']) {
    testWidgets('Generic200 legacy invoice retains controls $role', (t) async {
      var typed = 0;
      final generic = document()
        ..remove('schema_version')
        ..remove('source_kind');
      final client = await widgetClient(t, (request) async {
        if (request.url.path.endsWith('/list_invoice_documents')) {
          return response([]);
        }
        if (request.url.path.endsWith('/resolve_invoice_document')) {
          return response(generic);
        }
        if (request.url.path.endsWith('/get_my_offline_invoice_by_token')) {
          typed++;
          return response(document());
        }
        return response({'can_review': false});
      });
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => client.dispose());
      });
      await t.pumpWidget(
        MaterialApp(
          home: InvoiceDocumentsScreen(
            client: client,
            initialToken: token,
            role: role,
          ),
        ),
      );
      await settle(t);
      if (role == 'customer') {
        await t.scrollUntilVisible(
          find.text('Payment options & prices'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Payment options & prices'), findsOneWidget);
        await t.scrollUntilVisible(
          find.byType(InvoiceReviewPanel),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(InvoiceReviewPanel), findsOneWidget);
      } else {
        final print = find.text('Print / reprint');
        await t.scrollUntilVisible(
          print,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(print, findsOneWidget);
        expect(find.byType(InvoiceReviewPanel), findsNothing);
      }
      expect(typed, 0);
    });
  }
}
