import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/customer_service_reward.dart';
import 'package:sabiha_hub/service_booking_attempt.dart';
import 'package:sabiha_hub/loyalty_visit_lifecycle.dart';

const terms = {
  'pooling': 'policy_version',
  'expiry': 'no_expiry',
  'cancellation': 'restore_visits',
  'refunded_contribution': 'offset_future_visits',
};
const fields = {
  'p_service': 's',
  'p_branch': 'b',
  'p_vehicle': 'v',
  'p_date': '2026-12-01',
  'p_time': '10:00:00',
  'p_expected_price': 137.45,
  'p_notes': null,
};
void main() {
  Future<(ServiceBookingAttempt, List<Map<String, dynamic>>, List<bool>)> open(
    WidgetTester t, {
    String locale = 'en',
    double width = 1440,
    bool blocked = false,
  }) async {
    t.view.physicalSize = Size(width, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final writes = <Map<String, dynamic>>[];
    final modes = <bool>[];
    String state = 'absent';
    String? id, stored;
    Map<String, dynamic>? payload;
    final attempt = ServiceBookingAttempt(
      readId: () async => stored,
      writeId: (v) async => stored = v,
      clearId: () async => stored = null,
      rpc: (name, args) async {
        if (name == 'prepare_service_booking_attempt') {
          id = args['p_request'];
          payload = Map<String, dynamic>.from(args['p_payload'] as Map);
          state = 'open';
          return {
            'state': state,
            'mode': 'reward',
            'request_id': id,
            'payload': payload,
          };
        }
        if (name == 'place_customer_reward_booking') {
          writes.add(args);
          state = 'succeeded';
          return {};
        }
        if (name == 'get_service_booking_attempt') {
          return {
            'state': state,
            'request_id': id,
            'mode': 'reward',
            'payload': payload,
            if (state == 'succeeded')
              'result': {
                'booking_number': 'SH-BKG-000010',
                'invoice_number': 'SH-INV-000009',
                'gross_amount': 137.45,
                'reward_discount': 137.45,
                'amount_due': 0,
                'payment_status': 'covered_by_reward',
                'rules': terms,
              },
          };
        }
        throw StateError(name);
      },
    );
    await attempt.initialize();
    addTearDown(attempt.dispose);
    late SupabaseClient client;
    await t.runAsync(() async {
      client = SupabaseClient(
        'http://localhost:54321',
        'test',
        accessToken: () async => 'test',
        httpClient: MockClient((r) async {
          dynamic data;
          if (r.url.path.endsWith('get_service_reward_options')) {
            data = {
              'redemption_enabled': true,
              'programs': [
                {
                  'policy_version_id': 'policy',
                  'rules_version_id': 'rules',
                  'threshold_visits': 5,
                  'available_visits': 5,
                  'eligible': true,
                  'terms_snapshot': {
                    'offer': {'name': 'Actual reward offer'},
                  },
                },
              ],
            };
          } else if (r.url.path.endsWith('quote_service_reward')) {
            expect(jsonDecode(r.body)['p_expected_price'], isNull);
            data = blocked
                ? {'eligible': false, 'reason': 'quote_expired'}
                : {
                    'eligible': true,
                    'quote_id': 'quote',
                    'fingerprint': 'fingerprint',
                    'gross_amount': 137.45,
                    'reward_discount': 137.45,
                    'amount_due': 0,
                    'currency': 'EGP',
                    'threshold_visits': 5,
                    'terms_snapshot': {'rules': terms},
                    'expires_at': '2026-12-01T10:00:00Z',
                    'adoption_required': true,
                  };
          } else {
            throw StateError(r.url.path);
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
      );
    });
    addTearDown(() async {
      await t.runAsync(client.dispose);
    });
    await t.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('en'), Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: CustomerServiceRewardPanel(
              client: client,
              attempt: attempt,
              normalPayload: fields,
              appointmentReviewed: true,
              onModeChanged: modes.add,
              onAcknowledged: () {},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return (attempt, writes, modes);
  }

  Future<void> click(WidgetTester t, String text) async {
    final f = find.text(text);
    await t.ensureVisible(f);
    await t.tap(f);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await t.pumpAndSettle();
  }

  Future<void> quote(WidgetTester t, bool ar) async {
    await click(
      t,
      ar
          ? 'التحقق من مكافأة زيارات · اختياري'
          : 'Check visit reward · optional',
    );
    await t.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await t.tap(find.byType(DropdownButtonFormField<String>));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Actual reward offer').last);
    await t.pumpAndSettle();
    await click(
      t,
      ar ? 'تحميل عرض المكافأة الفعلي' : 'Load actual reward quote',
    );
  }

  for (final sample in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'Actual reward quote consent and adoption ${sample.$1} ${sample.$2}',
      (t) async {
        final (attempt, writes, modes) = await open(
          t,
          locale: sample.$1,
          width: sample.$2,
        );
        expect(writes, isEmpty);
        expect(modes, isEmpty);
        await quote(t, sample.$1 == 'ar');
        final box = find.byType(CheckboxListTile);
        expect(box, findsNWidgets(2));
        expect(
          t.widgetList<CheckboxListTile>(box).every((w) => !w.value!),
          isTrue,
        );
        final confirm = find.widgetWithText(
          FilledButton,
          sample.$1 == 'ar'
              ? 'تأكيد حجز المكافأة المعروض'
              : 'Confirm this quoted reward booking',
        );
        expect(t.widget<FilledButton>(confirm).onPressed, isNull);
        await t.ensureVisible(box.at(0));
        await t.tap(box.at(0));
        await t.pumpAndSettle();
        expect(t.widget<FilledButton>(confirm).onPressed, isNull);
        await t.ensureVisible(box.at(1));
        await t.tap(box.at(1));
        await t.pumpAndSettle();
        await t.ensureVisible(confirm);
        await t.tap(confirm);
        await t.pumpAndSettle();
        expect(writes.single['p_accept_terms'], true);
        expect(writes.single['p_adopt_existing_visits'], true);
        expect(writes.single['p_quote'], 'quote');
        expect(writes.single.keys, hasLength(5));
        expect(attempt.locked, isTrue);
        expect(attempt.succeeded, isTrue);
        expect(find.textContaining('SH-BKG-000010'), findsOneWidget);
        expect(
          find.text(
            sample.$1 == 'ar'
                ? 'مغطى بمكافأة الزيارات'
                : 'Covered by visit reward',
          ),
          findsOneWidget,
        );
        expect(modes, [true]);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('Blocked reward never silently switches to ordinary booking', (
    t,
  ) async {
    final (_, writes, modes) = await open(t, blocked: true);
    await quote(t, false);
    expect(find.textContaining('Quote expired'), findsOneWidget);
    expect(find.text('Confirm this quoted reward booking'), findsNothing);
    expect(modes, [true]);
    expect(writes, isEmpty);
  });
  testWidgets(
    'Wallet keeps overlapping pools separate and refreshes actual counts',
    (t) async {
      int visits = 5;
      late SupabaseClient client;
      await t.runAsync(() async {
        client = SupabaseClient(
          'http://localhost:54321',
          'test',
          accessToken: () async => 'test',
          httpClient: MockClient((r) async {
            expect(r.url.path, endsWith('/get_my_reward_wallet'));
            return http.Response(
              jsonEncode({
                'global_spendable_balance': null,
                'pools_overlap': true,
                'programs': [
                  for (final name in ['Actual A', 'Actual B'])
                    {
                      'offer_name': name,
                      'unused_valid_visits': visits,
                      'threshold_visits': 5,
                      'adoption_required_visits': 0,
                    },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }),
        );
      });
      addTearDown(() async {
        await t.runAsync(client.dispose);
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CustomerRewardWallet(client: client)),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Unused valid visits: 5'), findsNWidgets(2));
      expect(find.textContaining('do not add them'), findsOneWidget);
      visits = 1;
      refreshRewardWallet();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Unused valid visits: 1'), findsNWidgets(2));
    },
  );
  testWidgets(
    'Lifetime net visits are not labelled available redemption balance',
    (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CanonicalServiceVisitsCard(summary: {'net_visits': 7}),
          ),
        ),
      );
      expect(find.text('7'), findsOneWidget);
      expect(
        find.textContaining('not an available redemption balance'),
        findsOneWidget,
      );
      expect(find.textContaining('redemption is disabled'), findsNothing);
    },
  );
}
