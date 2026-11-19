import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/service_quality.dart';

class Gateway implements ServiceQualityGateway {
  final calls = <Map<String, dynamic>>[];
  bool lose = false, passed = false;
  int version = 0;
  Map<String, dynamic>? savedPolicy, receipt;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    calls.add({'name': name, ...params});
    if (name == 'get_service_quality') {
      return {
        'order_id': 'qa-order',
        'required': true,
        'can_submit': true,
        'status': 'quality_check',
        'items': [
          {'id': 'body', 'ar': 'الهيكل نظيف', 'en': 'Body is clean'},
        ],
        'checks': receipt == null
            ? []
            : [
                {
                  'passed': passed,
                  'note': 'QA inspection',
                  'current_crew': true,
                },
              ],
      };
    }
    if (name == 'submit_service_quality') {
      receipt ??= {'request_id': params['p_request'], 'passed': true};
      passed = true;
      if (lose) {
        lose = false;
        throw StateError('Reply lost');
      }
      return receipt!;
    }
    if (name == 'get_service_quality_policy') {
      return {
        'version': version,
        'enabled': savedPolicy?['p_enabled'] ?? false,
        'items': savedPolicy?['p_items'] ?? [],
        'future_starts_only': true,
      };
    }
    if (name == 'save_service_quality_policy') {
      savedPolicy = Map.of(params);
      version = 1;
      return {'request_id': params['p_request'], 'version': 1};
    }
    throw StateError('Unexpected RPC');
  }
}

Future<void> host(
  WidgetTester tester,
  Widget screen,
  String lang, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: screen,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> click(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('quality inspect and exact retry $lang $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = Gateway()..lose = true;
        await host(
          tester,
          ServiceQualityScreen(order: 'qa-order', gateway: g),
          lang,
        );
        final submit = find.text(
          lang == 'ar' ? 'تسجيل نتيجة الفحص' : 'Record inspection result',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.ancestor(of: submit, matching: find.byType(FilledButton)),
              )
              .onPressed,
          isNull,
        );
        await click(tester, find.byType(ChoiceChip).first);
        final note = find.byType(TextField);
        await tester.enterText(note, 'QA inspection');
        await click(tester, submit);
        final retry = find.text(
          lang == 'ar'
              ? 'إعادة نفس طلب الفحص'
              : 'Retry same inspection request',
        );
        expect(retry, findsOneWidget);
        expect(
          tester
              .widget<ChoiceChip>(find.byType(ChoiceChip).first)
              .onSelected,
          isNull,
        );
        await click(tester, retry);
        final writes = g.calls
            .where((v) => v['name'] == 'submit_service_quality')
            .toList();
        expect(writes.length, 2);
        expect(writes[0], writes[1]);
        expect(writes[0]['p_answers'], {'body': true});
        expect(find.text(lang == 'ar' ? 'ناجح' : 'Passed'), findsWidgets);
        expect(
          g.calls.every((v) => !v['name'].toString().contains('payment')),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      });
      testWidgets('owner quality policy bilingual $lang $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = Gateway();
        await host(
          tester,
          ServiceQualityPolicyScreen(branch: 'qa-branch', gateway: g),
          lang,
        );
        await click(tester, find.byType(SwitchListTile));
        for (final (index, value) in [
          (0, 'الهيكل نظيف'),
          (1, 'Body is clean'),
          (2, 'Owner enables explicit checklist'),
        ]) {
          final field = find.byType(TextField).at(index);
          await tester.ensureVisible(field);
          await tester.enterText(field, value);
        }
        await click(
          tester,
          find.text(lang == 'ar' ? 'حفظ نسخة جديدة' : 'Save new version'),
        );
        expect(g.savedPolicy!['p_expected_version'], 0);
        expect(g.savedPolicy!['p_enabled'], true);
        expect((g.savedPolicy!['p_items'] as List).single, {
          'id': 'item_1',
          'ar': 'الهيكل نظيف',
          'en': 'Body is clean',
        });
        expect(
          g.calls
              .where((v) => v['name'] == 'save_service_quality_policy')
              .length,
          1,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final language in ['ar', 'en']) {
    testWidgets(
      'owner explicit recovery of rejected policy version $language',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final g = ConflictGateway();
        await host(
          tester,
          ServiceQualityPolicyScreen(branch: 'qa-branch', gateway: g),
          language,
        );
        final field = find.byType(TextField).at(2);
        await tester.ensureVisible(field);
        await tester.enterText(field, 'Another owner saved a newer version');
        await click(
          tester,
          find.text(language == 'ar' ? 'حفظ نسخة جديدة' : 'Save new version'),
        );
        expect(
          g.calls
              .where((v) => v['name'] == 'save_service_quality_policy')
              .length,
          1,
        );
        await click(
          tester,
          find.text(
            language == 'ar'
                ? 'تجاهل الطلب المرفوض وتحميل النسخة الحالية'
                : 'Discard rejected request and load current version',
          ),
        );
        expect(
          find.text(language == 'ar' ? 'الإصدار: 2' : 'Version: 2'),
          findsOneWidget,
        );
        expect(
          g.calls
              .where((v) => v['name'] == 'save_service_quality_policy')
              .length,
          1,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('quality context cannot display another order', (tester) async {
    final g = Gateway();
    await host(
      tester,
      ServiceQualityScreen(order: 'other-order', gateway: g),
      'ar',
    );
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(g.calls.length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late quality scope result is ignored', (tester) async {
    final slow = SlowGateway();
    await host(
      tester,
      ServiceQualityScreen(order: 'old-order', gateway: slow),
      'en',
      settle: false,
    );
    await host(
      tester,
      ServiceQualityScreen(order: 'qa-order', gateway: Gateway()),
      'en',
    );
    slow.result.complete({
      'order_id': 'old-order',
      'required': true,
      'can_submit': true,
      'items': [
        {'id': 'secret', 'ar': 'قديم خاص', 'en': 'Old private'},
      ],
      'checks': [],
    });
    await tester.pumpAndSettle();
    expect(find.text('Old private'), findsNothing);
    expect(find.text('Body is clean'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class SlowGateway implements ServiceQualityGateway {
  final result = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> params) =>
      result.future;
}

class ConflictGateway extends Gateway {
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    if (name == 'save_service_quality_policy') {
      calls.add({'name': name, ...params});
      version = 2;
      throw const PostgrestException(message: 'Stale policy', code: '40001');
    }
    return super.call(name, params);
  }
}
