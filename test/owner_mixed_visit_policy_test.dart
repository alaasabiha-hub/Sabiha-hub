import 'package:supabase_flutter/supabase_flutter.dart';
import 'visit_recovery_request_test.dart' as auth;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/owner_mixed_visit_policy.dart';

class Gateway implements MixedVisitPolicyGateway {
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic>? saved;
  String? savedNonce;
  bool loseAck = false;
  Future<Map<String, dynamic>>? waiting;
  Map<String, dynamic> context(String b, String r) => {
    'unit': 'service_visits',
    'branch_id': b,
    'rules_version_id': r,
    'future_terms_only': true,
    'public_redemption_enabled': false,
    'mixed_invoice_issuer_available': false,
    'current': saved,
    'history': [],
  };
  @override
  Future<Map<String, dynamic>> read(String b, String r) async =>
      waiting ?? context(b, r);
  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> p) async {
    calls.add(Map.of(p));
    savedNonce ??= p['p_request'] as String;
    saved = {'version_no': 1, 'version_id': savedNonce, 'terms': p['p_terms']};
    if (loseAck) {
      loseAck = false;
      throw StateError('ACK lost');
    }
    return {
      'version_id': savedNonce,
      'version_no': 1,
      'future_terms_only': true,
      'redemption_activated': false,
      'prior_invoices_changed': false,
    };
  }
}

Widget app(Gateway g, String lang, {String branch = 'branch'}) => MaterialApp(
  locale: Locale(lang),
  supportedLocales: const [Locale('ar'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(
    body: SingleChildScrollView(
      child: OwnerMixedVisitPolicyPanel(
        gateway: g,
        branch: branch,
        rules: 'rules',
      ),
    ),
  ),
);
Future<void> choose(WidgetTester t, Finder f, String label) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

Future<void> fill(WidgetTester t, String lang) async {
  await choose(
    t,
    find.byType(DropdownButtonFormField<bool>).at(0),
    lang == 'ar' ? 'نعم' : 'Yes',
  );
  await choose(
    t,
    find.byType(DropdownButtonFormField<String>),
    lang == 'ar' ? 'خصم تجاري قبل الضريبة' : 'Commercial discount before tax',
  );
  await choose(
    t,
    find.byType(DropdownButtonFormField<bool>).at(1),
    lang == 'ar' ? 'لا' : 'No',
  );
  for (final x in [
    (0, 'QA explicitly reviewed treatment'),
    (1, '3'),
    (2, '0'),
    (3, 'QA explicit future terms reason'),
  ]) {
    final f = find.byType(TextField).at(x.$1);
    await t.ensureVisible(f);
    await t.enterText(f, x.$2);
  }
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1024.0, 1440.0]) {
      testWidgets('Explicit future visit terms $lang $width', (t) async {
        t.view.physicalSize = Size(width, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final g = Gateway();
        await t.pumpWidget(app(g, lang));
        await t.pumpAndSettle();
        expect(
          find.textContaining(
            lang == 'ar' ? 'لا يحجز زيارات' : 'does not reserve visits',
          ),
          findsOneWidget,
        );
        await fill(t, lang);
        final save = find.text(
          lang == 'ar' ? 'حفظ شروط مستقبلية فقط' : 'Save future terms only',
        );
        await t.ensureVisible(save);
        await t.tap(save);
        await t.pumpAndSettle();
        expect(g.calls.length, 1);
        expect(g.calls.single['p_expected_version'], 0);
        expect(g.saved?['version_no'], 1);
        expect((g.calls.single['p_terms'] as Map)['allow_walk_in'], true);
        expect(
          (g.calls.single['p_terms'] as Map)['allow_manual_discount'],
          false,
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('Lost acknowledgement retries exact saved nonce and version', (
    t,
  ) async {
    final g = Gateway()..loseAck = true;
    await t.pumpWidget(app(g, 'en'));
    await t.pumpAndSettle();
    await fill(t, 'en');
    final save = find.text('Save future terms only');
    await t.ensureVisible(save);
    await t.tap(save);
    await t.pumpAndSettle();
    expect(find.textContaining('Save is unconfirmed'), findsOneWidget);
    await t.ensureVisible(save);
    await t.tap(save);
    await t.pumpAndSettle();
    expect(g.calls.length, 2);
    expect(g.calls[0], g.calls[1]);
    expect(g.saved?['version_no'], 1);
  });
  testWidgets('Branch and gateway replacement discards late owner terms', (
    t,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final old = Gateway()..waiting = pending.future;
    final next = Gateway();
    await t.pumpWidget(app(old, 'en'));
    await t.pump();
    await t.pumpWidget(app(next, 'en', branch: 'new-branch'));
    await t.pumpAndSettle();
    pending.complete(
      old.context('branch', 'rules')
        ..['current'] = {
          'version_no': 99,
          'terms': {
            'allow_walk_in': true,
            'allow_manual_discount': true,
            'tax_treatment': 'commercial_before_tax',
            'maximum_covered_units': 999,
            'minimum_invoice_egp': 999,
            'tax_review_reference': 'OLD OWNER NOTES',
          },
        },
    );
    await t.pumpAndSettle();
    expect(find.text('OLD OWNER NOTES'), findsNothing);
    expect(find.text('Saved version: 0'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('Arabic digit limits use existing numeric normalization', (
    t,
  ) async {
    final g = Gateway();
    await t.pumpWidget(app(g, 'ar'));
    await t.pumpAndSettle();
    await fill(t, 'ar');
    final units = find.byType(TextField).at(1);
    await t.ensureVisible(units);
    await t.enterText(units, '٣');
    final minimum = find.byType(TextField).at(2);
    await t.ensureVisible(minimum);
    await t.enterText(minimum, '٠');
    final save = find.text('حفظ شروط مستقبلية فقط');
    await t.ensureVisible(save);
    await t.tap(save);
    await t.pumpAndSettle();
    expect(g.calls.length, 1);
    expect((g.calls.single['p_terms'] as Map)['maximum_covered_units'], 3);
    expect((g.calls.single['p_terms'] as Map)['minimum_invoice_egp'], 0);
  });
testWidgets('Auth scope loss clears owner notes and ignores late reload',(t)async{
 final c=await auth.client(t);final g=Gateway()..saved={'version_no':1,'terms':{'allow_walk_in':false,'allow_manual_discount':false,'tax_treatment':'commercial_before_tax','maximum_covered_units':3,'minimum_invoice_egp':0,'tax_review_reference':'OWNER PRIVATE NOTE'}};
 await t.pumpWidget(MaterialApp(locale:const Locale('en'),supportedLocales:const[Locale('ar'),Locale('en')],localizationsDelegates:GlobalMaterialLocalizations.delegates,home:Scaffold(body:SingleChildScrollView(child:OwnerMixedVisitPolicyPanel(client:c,gateway:g,branch:'branch',rules:'rules')))));await t.pumpAndSettle();expect(find.text('Saved version: 1'),findsOneWidget);
 final pending=Completer<Map<String,dynamic>>();g.waiting=pending.future;await t.tap(find.text('Refresh mixed-invoice terms'));await t.pump();c.testAuth.user=null;c.testAuth.events.add(const AuthState(AuthChangeEvent.signedOut,null));await t.pump();pending.complete(g.context('branch','rules'));await t.pumpAndSettle();expect(find.byType(TextField),findsNothing);expect(find.text('Save future terms only'),findsNothing);expect(find.text('Account changed. Reopen this screen.'),findsOneWidget);expect(t.takeException(),isNull);
});
}
