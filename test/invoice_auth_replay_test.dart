import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/invoices.dart';
import 'package:sabiha_hub/offline_history.dart';

const actor = '11111111-1111-4111-8111-111111111111';
const token = '33333333-3333-4333-8333-333333333333';
Map<String, dynamic> session() => {
  'access_token': 'test-session-token',
  'refresh_token': 'test-refresh',
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  'user': {
    'id': actor,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'qa@example.invalid',
    'created_at': '2026-11-15T00:00:00Z',
  },
};
http.Response response(dynamic data, [int code = 200, http.Request? request]) =>
    http.Response(
      code == 204 ? '' : jsonEncode(data),
      code,
      headers: {'content-type': 'application/json'},
      request: request,
    );
Map<String, dynamic> document() => {
  'invoice_id': 'QA-REPLAY',
  'invoice_number': 'SH-INV-000123',
  'document_token': token,
  'payment_status': 'unpaid',
  'payment_method': 'cash_on_receipt',
  'service_status': 'received',
  'snapshot': {
    'branch': {'name_en': 'QA'},
    'lines': [
      {
        'name': 'Replay service',
        'quantity': 1,
        'unit_price': 137.45,
        'subtotal': 137.45,
      },
    ],
    'total': 137.45,
    'discount': 0,
  },
};
void main() {
  for (final signOutDuringLoad in [false, true]) {
    testWidgets(
      'real SDK auth replay; signout during load=$signOutDuringLoad',
      (t) async {
        t.view.physicalSize = const Size(1200, 2000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final listing = Completer<http.Response>();
        final paths = <String>[];
        final client = (await t.runAsync(() async {
          final c = SupabaseClient(
            'http://localhost:54321',
            'test',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((r) async {
              paths.add(r.url.path);
              if (r.url.path.endsWith('/token')) {
                return response(session(), 200, r);
              }
              if (r.url.path.endsWith('/logout')) return response(null, 204, r);
              if (r.url.path.endsWith('/list_invoice_documents')) {
                return listing.future.then(
                  (v) => http.Response(
                    v.body,
                    v.statusCode,
                    headers: v.headers,
                    request: r,
                  ),
                );
              }
              if (r.url.path.endsWith('/resolve_invoice_document')) {
                return response(document(), 200, r);
              }
              throw StateError('Unexpected request');
            }),
          );
          await c.auth.signInWithPassword(
            email: 'qa@example.invalid',
            password: 'isolated',
          );
          return c;
        }))!;
        addTearDown(client.dispose);
        await t.pumpWidget(
          MaterialApp(
            home: InvoiceDocumentsScreen(
              client: client,
              role: 'manager',
              initialToken: token,
            ),
          ),
        );
        await t
            .pump(); // Allow the SDK's actual asynchronous ReplaySubject event.
        if (signOutDuringLoad) {
          await t.runAsync(
            () => client.auth.signOut(scope: SignOutScope.local),
          );
          await t.pump();
        }
        listing.complete(
          response([
            {'invoice_id': 'QA-REPLAY', 'document_token': token},
          ]),
        );
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pumpAndSettle();
        expect(
          paths.where((p) => p.endsWith('/resolve_invoice_document')).length,
          signOutDuringLoad ? 0 : 1,
        );
        if (!signOutDuringLoad) {
          expect(find.textContaining('SH-INV-000123'), findsWidgets);
          await t.runAsync(
            () => client.auth.signOut(scope: SignOutScope.local),
          );
          await t.pumpAndSettle();
          expect(find.textContaining('SH-INV-000123'), findsNothing);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }

  for (final signOutDuringLoad in [false, true]) {
    testWidgets(
      'history genuine replay; signout during load=$signOutDuringLoad',
      (t) async {
        final pending = Completer<http.Response>();
        final client = (await t.runAsync(() async {
          final c = SupabaseClient(
            'http://localhost:54321',
            'test',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((r) async {
              if (r.url.path.endsWith('/token')) {
                return response(session(), 200, r);
              }
              if (r.url.path.endsWith('/logout')) return response(null, 204, r);
              if (r.url.path.endsWith('/get_my_offline_history_context')) {
                return pending.future.then(
                  (v) => http.Response(
                    v.body,
                    v.statusCode,
                    headers: v.headers,
                    request: r,
                  ),
                );
              }
              throw StateError('Unexpected request');
            }),
          );
          await c.auth.signInWithPassword(
            email: 'qa@example.invalid',
            password: 'isolated',
          );
          return c;
        }))!;
        addTearDown(client.dispose);
        await t.pumpWidget(
          MaterialApp(home: OfflineHistoryScreen(client: client)),
        );
        await t.pump();
        if (signOutDuringLoad) {
          await t.runAsync(
            () => client.auth.signOut(scope: SignOutScope.local),
          );
          await t.pump();
        }
        pending.complete(response({'state': 'review_required'}));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pumpAndSettle();
        final review = find.text(
          'A receipt link and current owner-reviewed identity are required.',
        );
        expect(review, signOutDuringLoad ? findsNothing : findsOneWidget);
        if (!signOutDuringLoad) {
          await t.runAsync(
            () => client.auth.signOut(scope: SignOutScope.local),
          );
          await t.pumpAndSettle();
          expect(review, findsNothing);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      },
    );
  }
}
