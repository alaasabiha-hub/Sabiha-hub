import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_reports.dart';

void main() {
  testWidgets(
    'owner report renders server totals and sends bounded accounting dates',
    (tester) async {
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'http://localhost:54321',
          'local-test',
          accessToken: () async => 'local-test',
          httpClient: MockClient((request) async {
            if (request.url.path == '/rest/v1/business_branches') {
              return http.Response(
                '[]',
                200,
                request: request,
                headers: {'Content-Type': 'application/json'},
              );
            }
            expect(request.url.path, '/rest/v1/rpc/get_admin_console');
            expect((jsonDecode(request.body) as Map)['p_branch'], isNull);
            final query = jsonDecode(request.body) as Map;
            expect(query.containsKey('p_zone'), isFalse);
            expect(query['p_from_local'], isNotEmpty);
            expect(query['p_to_local'], isNotEmpty);
            return http.Response(
              jsonEncode({
                'financial': true,
                'role': 'owner',
                'branches': [],
                'staff': [],
                'catalog': [],
                'bookings': [],
                'invoices': [],
                'report': {
                  'net_billed': 300,
                  'invoice_count': 2,
                  'refunded_total': 50,
                  'commissions': 30,
                  'expenses': 20,
                  'net_sales_ex_tax': null,
                  'hourly': [],
                  'payments': [],
                  'cash_activity': {'collections': 300},
                },
              }),
              200,
              request: request,
              headers: {'Content-Type': 'application/json'},
            );
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpWidget(
        MaterialApp(home: OwnerReportsScreen(client: client)),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Net Sales'));
      await tester.tap(find.text('Net Sales'));
      await tester.pumpAndSettle();
      expect(find.text('300.00 EGP'), findsWidgets);
      expect(find.text('250.00 EGP'), findsNothing);
      expect(find.text('Not recorded / incomplete'), findsWidgets);
      expect(find.text('Net before tax'), findsNothing);
      await tester.runAsync(client.dispose);
    },
  );
  testWidgets('denied report access never renders financial totals', (
    tester,
  ) async {
    late SupabaseClient client;
    await tester.runAsync(() async {
      client = SupabaseClient(
        'http://localhost:54321',
        'local-test',
        accessToken: () async => 'local-test',
        httpClient: MockClient(
          (request) async => http.Response(
            '{"message":"Owner required","code":"42501"}',
            403,
            request: request,
            headers: {'Content-Type': 'application/json'},
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpWidget(
      MaterialApp(home: OwnerReportsScreen(client: client)),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(
      find.text('Could not load data. Check connection and permissions.'),
      findsOneWidget,
    );
    expect(find.text('Active sales'), findsNothing);
    await tester.runAsync(client.dispose);
  });
}
