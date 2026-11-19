import 'package:sabiha_hub/mixed_points_live.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/mixed_points_earnings.dart';

Map<String, dynamic> points() => {
  'unit': 'reward_points_v1',
  'has_earnings': true,
  'ledger_only': true,
  'legacy_converted': false,
  'redemption_available': false,
  'buckets': [
    {
      'earned_points': '110',
      'refund_offsets': '10',
      'net_earned_points': '100',
      'review_required': true,
    },
    {
      'earned_points': '9007199254740993',
      'refund_offsets': '0',
      'net_earned_points': '9007199254740993',
      'review_required': false,
    },
  ],
};
Future<SupabaseClient> client(
  WidgetTester t,
  Future<http.Response> Function(http.Request) handler,
) async => (await t.runAsync(
  () async => SupabaseClient(
    'http://127.0.0.1:54321',
    'test',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final out = await handler(request);
      return http.Response(
        out.body,
        out.statusCode,
        headers: out.headers,
        request: request,
      );
    }),
  ),
))!;
http.Response response(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
Future<void> show(
  WidgetTester t,
  SupabaseClient c,
  String lang,
  double width,
) async {
  t.view.physicalSize = Size(width, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => c.dispose());
  });
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(child: MixedPointsEarningsPanel(client: c)),
      ),
    ),
  );
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await t.pumpAndSettle();
}

class QuietPointHints implements MixedPointsHintTransport {
  @override
  Future<void> connect({required VoidCallback onHint, required VoidCallback onReconnect}) async {}
  @override
  Future<void> reauthenticate() async {}
  @override
  Future<void> close() async {}
}

void main() {
  for (final lang in ['ar', 'en']) {
    testWidgets('Reserved and redeemed customer points projection $lang', (
      t,
    ) async {
      final payload = points();
      (payload['buckets'] as List).first.addAll({
        'available_points': '89',
        'reserved_points': '10',
        'redeemed_points': '1',
      });
      final c = await client(t, (_) async => response(payload));
      await show(t, c, lang, lang == 'ar' ? 390 : 1440);
      expect(
        find.text(
          lang == 'ar'
              ? 'غير مستخدم: 89 · محجوز: 10 · مستبدل بعد الاستردادات: 1'
              : 'Unused: 89 · Reserved: 10 · Redeemed after returns: 1',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }

  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1024.0, 1440.0]) {
      testWidgets('Scoped exact point entitlements $lang $width', (t) async {
        final c = await client(t, (_) async => response(points()));
        await show(t, c, lang, width);
        expect(
          find.text('100 ${lang == 'ar' ? 'نقطة مسجلة' : 'recorded points'}'),
          findsOneWidget,
        );
        expect(
          find.text(
            '9007199254740993 ${lang == 'ar' ? 'نقطة مسجلة' : 'recorded points'}',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            lang == 'ar'
                ? 'بانتظار مراجعة المالك بعد الاسترداد.'
                : 'Awaiting owner review after a refund.',
          ),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsNothing);
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('Absent new program does not present legacy or invented zero', (
    t,
  ) async {
    final c = await client(
      t,
      (_) async =>
          response({...points(), 'has_earnings': false, 'buckets': []}),
    );
    await show(t, c, 'ar', 390);
    expect(find.text('نقاط الولاء المسجلة'), findsNothing);
    expect(find.textContaining('0 نقطة'), findsNothing);
  });
  testWidgets('Redemption-capable or numeric-rounded receipt rejected', (
    t,
  ) async {
    final c = await client(
      t,
      (_) async => response({...points(), 'redemption_available': true}),
    );
    await show(t, c, 'en', 390);
    expect(find.textContaining('100 recorded points'), findsNothing);
    expect(
      find.text('Loyalty points could not be verified. Refresh the page.'),
      findsOneWidget,
    );
  });
  testWidgets('Account switch rejects a late point balance', (t) async {
    final pending = Completer<http.Response>();
    final c = await client(t, (_) => pending.future);
    String session(String id) {
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      String enc(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return jsonEncode({
        'access_token':
            '${enc({'alg': 'HS256'})}.${enc({'sub': id, 'exp': expiry})}.unit-test-only',
        'refresh_token': 'unit-test-only',
        'token_type': 'bearer',
        'expires_at': expiry,
        'expires_in': 3600,
        'user': {
          'id': id,
          'aud': 'authenticated',
          'created_at': '2026-11-16T00:00:00Z',
          'app_metadata': {},
          'user_metadata': {},
        },
      });
    }

    await t.runAsync(
      () => c.auth.recoverSession(
        session('00000000-0000-4000-8000-000000000001'),
      ),
    );
    await t.pumpWidget(MaterialApp(home: MixedPointsEarningsPanel(client: c, hintTransport: QuietPointHints(), fallbackInterval: Duration.zero)));
    await t.pump();
    await t.runAsync(
      () => c.auth.recoverSession(
        session('00000000-0000-4000-8000-000000000002'),
      ),
    );
    await t.pump();
    pending.complete(response(points()));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('100 recorded points'), findsNothing);
    expect(find.text('Recorded loyalty points'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => c.dispose());
  });
  testWidgets('A pending response after disposal is ignored', (t) async {
    final pending = Completer<http.Response>();
    final c = await client(t, (_) => pending.future);
    await t.pumpWidget(MaterialApp(home: MixedPointsEarningsPanel(client: c)));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    pending.complete(response(points()));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.runAsync(() => c.dispose());
  });
}
