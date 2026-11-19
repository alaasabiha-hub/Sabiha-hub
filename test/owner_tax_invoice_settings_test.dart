import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_tax_invoice_settings.dart';

const branch = '10000000-0000-4000-8000-000000000001',
    item = '20000000-0000-4000-8000-000000000001',
    proposal = '30000000-0000-4000-8000-000000000001';

class Gateway implements OwnerTaxGateway {
  bool live = true, lose = false, integrated = false;
  final changed = StreamController<void>.broadcast(sync: true);
  final commands = <Map<String, dynamic>>[];
  Map<String, dynamic>? spec, activeSpec, defaults;
  bool reviewed = false;
  int version = 0;
  Map<String, dynamic>? receipt;
  Completer<Map<String, dynamic>>? waiting;
  @override
  bool get current => live;
  @override
  Stream<void> get changes => changed.stream;
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> p) async {
    if (name == 'get_owner_tax_invoice_settings') {
      return {
        'owner_only': true,
        'notice_version': 'tax-review-v1',
        'notice_ar': 'إقرار مراجعة المختص والأدلة للاختبار فقط',
        'notice_en': 'QA specialist evidence review notice only',
        'eta_submission_enabled': false,
        'invoice_issuance_integrated': integrated,
        'invoice_issuance_scope': 'reviewed_cashier_registered_customer_only',
        'default_rate_assumed': false,
        'has_more': false,
        'defaults': defaults,
        'items': [
          {
            'item_id': item,
            'name': 'خدمة اختبار',
            'name_en': 'QA service',
            'price': 100,
            'active_version': version,
            'active_classification': activeSpec,
            'pending_proposals': spec != null && !reviewed
                ? [
                    {
                      'proposal_id': proposal,
                      'base_version': 0,
                      'spec': spec,
                      'created_at': '2026-11-15T12:00:00Z',
                    },
                  ]
                : [],
          },
        ],
      };
    }
    commands.add({'name': name, 'params': jsonDecode(jsonEncode(p))});
    if (waiting != null) return waiting!.future;
    if (name == 'propose_owner_tax_classification') {
      spec ??= Map<String, dynamic>.from(p['p_spec'] as Map);
      receipt ??= {
        'proposal_id': proposal,
        'state': 'pending_review',
        'base_version': 0,
        'active': false,
        'eta_accepted': false,
      };
      if (lose) {
        lose = false;
        throw TimeoutException('QA lost ACK');
      }
      return receipt!;
    }
    if (name == 'review_owner_tax_classification') {
      reviewed = true;
      if (p['p_decision'] == 'approve') {
        activeSpec = spec;
        version = 1;
      }
      return {
        'proposal_id': proposal,
        'state': p['p_decision'] == 'approve' ? 'owner_reviewed' : 'rejected',
        'active_version': version,
        'active': p['p_decision'] == 'approve',
        'legally_verified_by_software': false,
        'eta_accepted': false,
      };
    }
    if (name == 'pause_owner_tax_classification') {
      activeSpec = null;
      version++;
      return {
        'state': 'paused',
        'zero_tax_fallback': false,
        'active_version': version,
        'blocks_unreviewed_issuance': true,
      };
    }
    if (name == 'save_owner_tax_invoice_defaults') {
      defaults = {
        'version': 1,
        'display_mode': p['p_display_mode'],
        'default_rate': p['p_default_rate'],
      };
      return {
        ...defaults!,
        'requires_item_review': true,
        'changes_existing_invoices': false,
      };
    }
    throw StateError('Unexpected RPC');
  }
}

Future<void> mount(
  WidgetTester tester,
  Gateway g,
  String lang,
  double width,
) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(g.changed.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: OwnerTaxInvoiceSettingsScreen(gateway: g, branch: branch),
    ),
  );
  await tester.pumpAndSettle();
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Future<void> click(WidgetTester tester, String label) async {
  final f = find.text(label).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> propose(WidgetTester tester, String lang) async {
  final ar = lang == 'ar';
  await click(
    tester,
    ar ? 'اقتراح تصنيف موثّق' : 'Propose documented classification',
  );
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(ar ? 'غير شامل الضريبة' : 'Tax exclusive').last);
  await tester.pumpAndSettle();
  await tester.enterText(
    field(ar ? 'النسبة الصريحة %' : 'Explicit rate %'),
    ar ? '١٤' : '14',
  );
  await tester.tap(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('V009').last);
  await tester.pumpAndSettle();
  await tester.enterText(
    field(ar ? 'الأساس القانوني' : 'Legal basis'),
    'ISOLATED QA legal basis only',
  );
  await tester.enterText(
    field(
      ar
          ? 'مرجع الأدلة أو مراجعة المختص'
          : 'Evidence or specialist review reference',
    ),
    'ISOLATED QA evidence reference',
  );
  await click(tester, ar ? 'حفظ الاقتراح' : 'Save proposal');
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('owner tax proposes then separately reviews $lang $width', (
        tester,
      ) async {
        final g = Gateway();
        await mount(tester, g, lang, width);
        await propose(tester, lang);
        expect(g.commands.length, 1);
        expect(g.commands.single['params']['p_spec']['rate_percent'], 14);
        expect(g.activeSpec, isNull);
        expect(
          find.text(lang == 'ar' ? 'بانتظار المراجعة' : 'Awaiting review'),
          findsOneWidget,
        );
        await click(
          tester,
          lang == 'ar' ? 'مراجعة واعتماد' : 'Review and approve',
        );
        await tester.enterText(
          field(lang == 'ar' ? 'سبب القرار' : 'Decision reason'),
          'ISOLATED QA reviewed source',
        );
        await click(tester, lang == 'ar' ? 'تأكيد القرار' : 'Confirm decision');
        expect(g.commands.length, 1);
        final box = find.byType(CheckboxListTile);
        await tester.ensureVisible(box);
        await tester.tap(box);
        await click(tester, lang == 'ar' ? 'تأكيد القرار' : 'Confirm decision');
        expect(g.commands.length, 2);
        expect(g.commands.last['params']['p_ack'], {
          'version': 'tax-review-v1',
          'language': lang,
          'text': lang == 'ar'
              ? 'إقرار مراجعة المختص والأدلة للاختبار فقط'
              : 'QA specialist evidence review notice only',
          'reviewed': true,
        });
        expect(g.version, 1);
        expect(
          find.text(lang == 'ar' ? 'بانتظار المراجعة' : 'Awaiting review'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'owner tax lost acknowledgement freezes inputs and replays same request',
    (tester) async {
      final g = Gateway()..lose = true;
      await mount(tester, g, 'en', 390);
      await propose(tester, 'en');
      expect(g.commands.length, 1);
      expect(
        tester.widget<TextField>(field('Search services and products')).enabled,
        isFalse,
      );
      await click(tester, 'Retry the same settings request');
      expect(g.commands.length, 2);
      expect(g.commands[0], g.commands[1]);
      expect(find.text('Awaiting review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'owner tax defaults do not invent a rate or permit zero fallback',
    (tester) async {
      final g = Gateway();
      await mount(tester, g, 'en', 390);
      expect(
        find.text('Current default: Not configured'),
        findsOneWidget,
      );
      await click(
        tester,
        'Change this branch’s default price method',
      );
      expect(
        find.text('Price display and tax calculation for this branch'),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tax inclusive').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('Optional suggested rate %'), '0');
      await tester.enterText(field('Reason for change'), 'QA no rate default');
      await click(tester, 'Save settings');
      expect(g.commands, isEmpty);
      await tester.enterText(field('Optional suggested rate %'), '');
      await click(tester, 'Save settings');
      expect(g.commands.single['params']['p_default_rate'], isNull);
      expect(g.commands.single['params']['p_display_mode'], 'inclusive');
      expect(g.activeSpec, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('owner branch tax display mode labels both price conventions', (
    tester,
  ) async {
    final g = Gateway()
      ..defaults = {'version': 4, 'display_mode': 'inclusive', 'default_rate': 14};
    await mount(tester, g, 'ar', 390);
    expect(
      find.text('طريقة عرض واحتساب الأسعار — هذا الفرع'),
      findsOneWidget,
    );
    expect(find.text('الافتراضي الحالي: شامل الضريبة'), findsOneWidget);
    expect(find.text('الأسعار شاملة ضريبة القيمة المضافة'), findsOneWidget);
    expect(find.text('الأسعار غير شاملة ضريبة القيمة المضافة'), findsOneWidget);
    expect(
      find.textContaining('لا تُفترض نسبة أو معاملة قانونية'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('owner tax account change closes modal and clears evidence', (
    tester,
  ) async {
    final g = Gateway();
    await mount(tester, g, 'en', 390);
    await click(tester, 'Propose documented classification');
    await tester.enterText(field('Legal basis'), 'QA private evidence note');
    g.live = false;
    g.changed.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('The owner must sign in again.'), findsOneWidget);
    expect(find.text('QA private evidence note'), findsNothing);
    expect(g.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'owner rejects stale proposal using current version without replacing active tax',
    (tester) async {
      final g = Gateway()
        ..version = 1
        ..spec = {
          'tax_mode': 'exclusive',
          'rate_percent': 14,
          'eta_subtype': 'V009',
          'legal_basis': 'QA older proposal',
          'evidence_reference': 'QA evidence',
        }
        ..activeSpec = {
          'tax_mode': 'inclusive',
          'rate_percent': 14,
          'eta_subtype': 'V009',
        };
      await mount(tester, g, 'en', 390);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review and approve'),
            )
            .onPressed,
        isNull,
      );
      await click(tester, 'Reject with reason');
      await tester.enterText(
        field('Decision reason'),
        'QA reject superseded candidate',
      );
      await click(tester, 'Confirm decision');
      expect(g.commands.single['params']['p_expected_version'], 1);
      expect(g.commands.single['params']['p_decision'], 'reject');
      expect(g.activeSpec!['tax_mode'], 'inclusive');
      expect(g.version, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
