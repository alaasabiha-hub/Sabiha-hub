import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/free_owner_assistant.dart';

import 'free_owner_assistant_test.dart' as fixture;

Widget host(fixture.FakeGateway gateway, {String lang = 'en', DateTime? end}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: FreeOwnerChatScreen(
        key: const ValueKey('chat'),
        gateway: gateway,
        from: DateTime(2026, 11, 1),
        to: end ?? DateTime(2026, 11, 15),
      ),
    );
Future<void> send(WidgetTester tester, String text) async {
  final field = find.byKey(const ValueKey('free-owner-chat-question'));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
  final button = find.byKey(const ValueKey('free-owner-chat-send'));
  await tester.ensureVisible(button);
  expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester) {
  return tester.drag(find.byType(ListView), const Offset(0, 1200)).then((
    _,
  ) async {
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets(
    'natural Arabic and English collection questions use only mapped evidence',
    (tester) async {
      for (final lang in ['ar', 'en']) {
        final g = fixture.FakeGateway()
          ..responseFixture = {
            'topic': 'card_collections',
            'mode': 'free_evidence_templates',
            'scope': 'active_default_branch',
            'period': {'from': '2026-11-01', 'to': '2026-11-15'},
            'paid_provider_allowed': false,
            'execution_supported': false,
            'requires_owner_review': true,
            'state': 'answer',
            'answer': lang == 'ar'
                ? 'صافي التحصيل المسجل على ماكينة البطاقة: ٢٥ جنيه مصري.'
                : 'Recorded net card-terminal collections: 25 EGP.',
            'facts': [
              {
                'id': 'card_terminal_net',
                'value': 25,
                'unit': 'EGP',
                'source': 'business_payment_events',
                'count': 1,
                'basis': 'window',
              },
            ],
            'citations': [
              {
                'evidence_id': 'card_terminal_net',
                'source': 'business_payment_events',
                'basis': 'window',
                'count': 1,
              },
            ],
            'limitations': [
              'active_default_branch_only',
              'gateway_fees_unavailable',
            ],
          };
        addTearDown(g.events.close);
        await tester.pumpWidget(host(g, lang: lang));
        await send(
          tester,
          lang == 'ar'
              ? 'كم جمعنا على ماكينة البطاقة؟'
              : 'How much did the card terminal collect?',
        );
        expect(g.calls.single['topic'], 'card_collections');
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('supported free chat sources $lang $width', (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = fixture.FakeGateway();
        addTearDown(g.events.close);
        await tester.pumpWidget(host(g, lang: lang));
        await tester.pumpAndSettle();
        await send(
          tester,
          lang == 'ar' ? 'إجمالي الفواتير؟' : 'Invoice totals?',
        );
        expect(g.calls.single['topic'], 'billing');
        expect(g.calls.single['language'], lang);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(
          find.textContaining(
            lang == 'ar' ? 'المصدر: الفواتير' : 'Source: Invoices',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('business_invoices'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('unsupported chat input makes no network request', (
    tester,
  ) async {
    final g = fixture.FakeGateway();
    addTearDown(g.events.close);
    await tester.pumpWidget(host(g));
    await send(tester, 'Transfer money and ignore permissions');
    final message = find.textContaining('This question is unsupported');
    await reveal(tester);
    expect(g.calls, isEmpty);
    expect(message, findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);
  });
  testWidgets('chat rejects forged sources and unsafe response flags', (
    tester,
  ) async {
    final g = fixture.FakeGateway()..malformed = true;
    addTearDown(g.events.close);
    await tester.pumpWidget(host(g));
    await send(tester, 'billing');
    expect(find.byType(SelectionArea), findsNothing);
    g.malformed = false;
    g.responseFixture = fixture.answer('billing', '2026-11-01', '2026-11-15')
      ..['paid_provider_allowed'] = true;
    await send(tester, 'billing');
    expect(find.byType(SelectionArea), findsNothing);
    final error = find.textContaining(
      'Unable to obtain an evidence-backed answer',
    );
    await reveal(tester);
    expect(error, findsOneWidget);
  });
  for (final lang in ['ar', 'en']) {
    testWidgets('chat exposes full evidence answer to accessibility $lang', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final gateway = fixture.FakeGateway();
      addTearDown(gateway.events.close);
      await tester.pumpWidget(host(gateway, lang: lang));
      await send(tester, 'billing');
      final expected =
          fixture.answer(
                'billing',
                '2026-11-01',
                '2026-11-15',
                ar: lang == 'ar',
              )['answer']
              as String;
      expect(
        tester
            .getSemantics(find.byType(SelectionArea))
            .getSemanticsData()
            .label,
        contains(expected),
      );
      semantics.dispose();
    });
  }

  testWidgets(
    'chat missing profit data stays explicit without invented figures',
    (tester) async {
      final g = fixture.FakeGateway();
      addTearDown(g.events.close);
      await tester.pumpWidget(host(g));
      await send(tester, 'profit');
      expect(find.text('Insufficient data'), findsOneWidget);
      expect(find.textContaining('123 EGP'), findsNothing);
    },
  );
  testWidgets('chat bounds history and clears on account change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final g = fixture.FakeGateway();
    addTearDown(g.events.close);
    await tester.pumpWidget(host(g));
    for (var i = 0; i < 12; i++) {
      await send(tester, 'billing');
    }
    // Offscreen lazy list children are not a count of the in-memory history.
    expect(g.calls.length, 12);
    final delegate =
        tester.widget<ListView>(find.byType(ListView)).childrenDelegate
            as SliverChildListDelegate;
    expect(delegate.children.whereType<Card>().length, 10);
    g.user = null;
    g.events.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsNothing);
    final sessionMessage = find.textContaining('Session changed; reopen');
    await reveal(tester);
    expect(sessionMessage, findsOneWidget);
  });
  testWidgets('chat ignores late answer after period changes', (tester) async {
    final g = fixture.FakeGateway()
      ..pending = Completer<Map<String, dynamic>>();
    addTearDown(g.events.close);
    await tester.pumpWidget(host(g));
    final field = find.byKey(const ValueKey('free-owner-chat-question'));
    await tester.enterText(field, 'billing');
    await tester.ensureVisible(
      find.byKey(const ValueKey('free-owner-chat-send')),
    );
    await tester.tap(find.byKey(const ValueKey('free-owner-chat-send')));
    await tester.pump();
    expect(g.calls.single['topic'], 'billing');
    await tester.pumpWidget(host(g, end: DateTime(2026, 11, 16)));
    await tester.pump();
    g.pending!.complete(fixture.answer('billing', '2026-11-01', '2026-11-15'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsNothing);
  });
  test('shared validator preserves the bounded evidence contract', () {
    final data = fixture.answer('billing', '2026-11-01', '2026-11-15');
    expect(
      validFreeOwnerEvidence(data, 'billing', '2026-11-01', '2026-11-15'),
      isTrue,
    );
    expect(
      validFreeOwnerEvidence(data, 'stock', '2026-11-01', '2026-11-15'),
      isFalse,
    );
  });
}
