import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabiha_hub/delivery_support.dart';

void main() {
  testWidgets(
    'late restored checkout after sign-out cannot display or rewrite account data',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final calls = <String>[];
      final responseGate = Completer<void>();
      final requestStarted = Completer<void>();
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://local.example.test',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            calls.add(request.url.path);
            dynamic result;
            if (request.url.path.contains('/auth/')) {
              result = {
                'access_token':
                    '${base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'}))).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode({'sub': '00000000-0000-0000-0000-000000000001', 'role': 'authenticated', 'aud': 'authenticated', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.signature',
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': '00000000-0000-0000-0000-000000000001',
                  'aud': 'authenticated',
                  'email': 'test@example.test',
                  'created_at': '2026-11-14T00:00:00Z',
                },
              };
            } else if (request.url.path.endsWith('get_checkout_retry')) {
              requestStarted.complete();
              await responseGate.future;
              result = {
                'state': 'open',
                'request_id': '00000000-0000-4000-8000-000000000002',
                'branch_id': 'removed-branch',
                'payload': {
                  'p_request_id': '00000000-0000-4000-8000-000000000002',
                  'p_items': [
                    {'item_id': 'removed-product', 'quantity': 1},
                  ],
                  'p_method': 'delivery',
                  'p_zone': 'removed-zone',
                  'p_address': 'private saved address',
                  'p_phone': '+201000000001',
                  'p_note': '',
                  'p_coupon': '',
                  'p_expected_total': 24,
                },
              };
            } else {
              throw StateError('Unexpected stale catalog lookup');
            }
            return http.Response(
              jsonEncode(result),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        await client.auth.signInWithPassword(
          email: 'test@example.test',
          password: 'test-password',
        );
      });
      await tester.pumpWidget(
        MaterialApp(home: FulfillmentShopScreen(client: client)),
      );
      await tester.runAsync(() async {
        await requestStarted.future;
        await client.auth.signOut(scope: SignOutScope.local);
      });
      await tester.pump();
      responseGate.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.textContaining('Your sign-in changed.'), findsOneWidget);
      expect(find.text('private saved address'), findsNothing);
      expect(find.text('Retry same request'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => client.dispose());
    },
  );
  testWidgets(
    'late restored checkout cannot overwrite a newly signed-in account retry',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'checkout_retry_uuid_00000000-0000-0000-0000-000000000003':
            'new-account-pending',
      });
      var actor = '00000000-0000-0000-0000-000000000001';
      final calls = <String>[];
      final responseGate = Completer<void>();
      final requestStarted = Completer<void>();
      late SupabaseClient client;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://local.example.test',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            calls.add(request.url.path);
            dynamic result;
            if (request.url.path.contains('/auth/')) {
              result = {
                'access_token':
                    '${base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'}))).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode({'sub': actor, 'role': 'authenticated', 'aud': 'authenticated', 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.signature',
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': actor,
                  'aud': 'authenticated',
                  'email': 'test@example.test',
                  'created_at': '2026-11-14T00:00:00Z',
                },
              };
            } else if (request.url.path.endsWith('get_checkout_retry')) {
              requestStarted.complete();
              await responseGate.future;
              result = {
                'state': 'open',
                'request_id': '00000000-0000-4000-8000-000000000002',
                'branch_id': 'removed-branch',
                'payload': {
                  'p_request_id': '00000000-0000-4000-8000-000000000002',
                  'p_items': [
                    {'item_id': 'removed-product', 'quantity': 1},
                  ],
                  'p_method': 'delivery',
                  'p_zone': 'removed-zone',
                  'p_address': 'private saved address',
                  'p_phone': '+201000000001',
                  'p_note': '',
                  'p_coupon': '',
                  'p_expected_total': 24,
                },
              };
            } else {
              throw StateError('Unexpected stale catalog lookup');
            }
            return http.Response(
              jsonEncode(result),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        await client.auth.signInWithPassword(
          email: 'test@example.test',
          password: 'test-password',
        );
      });
      await tester.pumpWidget(
        MaterialApp(home: FulfillmentShopScreen(client: client)),
      );
      await tester.runAsync(() async {
        await requestStarted.future;
        await client.auth.signOut(scope: SignOutScope.local);
        actor = '00000000-0000-0000-0000-000000000003';
        await client.auth.signInWithPassword(
          email: 'second@example.test',
          password: 'test-password',
        );
      });
      await tester.pump();
      responseGate.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.textContaining('Your sign-in changed.'), findsOneWidget);
      expect(find.text('private saved address'), findsNothing);
      expect(find.text('Retry same request'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {
        'checkout_retry_uuid_00000000-0000-0000-0000-000000000003',
      });
      expect(prefs.getString(prefs.getKeys().single), 'new-account-pending');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => client.dispose());
    },
  );
}
