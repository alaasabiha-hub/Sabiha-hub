import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/visit_recovery_proposal.dart';

import 'visit_recovery_proposal_test.dart' as proposal;
import 'visit_recovery_request_test.dart' as auth;

class Gateway extends proposal.Gateway {
  Gateway(super.store);
  int currents = 0;
  final acceptedConsents = <Map<String, dynamic>>[];
  final acceptedClaims = <Map<String, dynamic>>[];
  final readRequests = <String>[];
  final closedRequests = <String>[];
  @override
  Future<Map<String, dynamic>> current(String id) async {
    currents++;
    return {
      ...await super.current(id),
      'old_profile_name': 'DO-NOT-DISPLAY-OLD-NAME',
      'old_profile_phone': 'DO-NOT-DISPLAY-OLD-PHONE',
      'receipt_secret': 'DO-NOT-DISPLAY-SECRET',
    };
  }

  @override
  Future<Map<String, dynamic>> accept(
    RecoveryProposalReference ref,
    Map<String, dynamic> consent,
    Map<String, dynamic> claimConsent,
  ) async {
    store.trace.add('accept');
    accepts++;
    expect(store.ref!.values, ref.values);
    acceptedConsents.add(Map.of(consent));
    acceptedClaims.add(Map.of(claimConsent));
    if (pending != null) return await pending!.future;
    return receipt(ref);
  }

  @override
  Future<Map<String, dynamic>> result(String request) {
    readRequests.add(request);
    return super.result(request);
  }

  @override
  Future<Map<String, dynamic>> close(String request) {
    closedRequests.add(request);
    return super.close(request);
  }
}

Future<void> showPanel(
  WidgetTester tester,
  auth.TestClient client,
  Gateway gateway,
  proposal.Store store, {
  String language = 'en',
  double width = 1440,
  String caseId = proposal.caseId,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: RecoveryProposalPanel(
            client: client,
            caseId: caseId,
            gateway: gateway,
            store: store,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'proposal ${config.$1} ${config.$2} renders frozen notices and needs both unchecked consents before actual review',
      (tester) async {
        final client = await auth.client(tester), store = proposal.Store();
        final gateway = Gateway(store), ar = config.$1 == 'ar';
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await showPanel(
          tester,
          client,
          gateway,
          store,
          language: config.$1,
          width: config.$2,
        );
        expect(
          find.text(ar ? 'موافقة المراجعة' : 'Review consent'),
          findsOneWidget,
        );
        expect(
          find.text(ar ? 'تحقق مستقل' : 'Independent verification'),
          findsOneWidget,
        );
        for (final secret in [
          'must-not-cache',
          'DO-NOT-DISPLAY-OLD-NAME',
          'DO-NOT-DISPLAY-OLD-PHONE',
          'DO-NOT-DISPLAY-SECRET',
          proposal.proposal,
        ]) {
          expect(find.textContaining(secret), findsNothing);
        }
        final first = find.widgetWithText(
          CheckboxListTile,
          ar
              ? 'أوافق على مراجعة اقتراح المالك'
              : 'I agree to review the owner proposal',
        );
        final second = find.widgetWithText(
          CheckboxListTile,
          ar
              ? 'أوافق على طلب التحقق المستقل'
              : 'I agree to request independent verification',
        );
        final submit = find.byKey(const ValueKey('recovery-proposal-accept'));
        expect(tester.widget<CheckboxListTile>(first).value, false);
        expect(tester.widget<CheckboxListTile>(second).value, false);
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        await press(tester, first);
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        expect(gateway.accepts, 0);
        await press(tester, second);
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
        await press(tester, submit);
        expect(gateway.accepts, 1);
        expect(store.trace, ['persist', 'accept']);
        expect(gateway.acceptedConsents.single, {
          'accepted': true,
          'version': 'visit-recovery-proposal-v1',
          'language': config.$1,
          'text': ar ? 'موافقة المراجعة' : 'Review consent',
        });
        expect(gateway.acceptedClaims.single, {
          'accepted': true,
          'version': 'offline-claim-v1',
          'language': config.$1,
          'text': ar ? 'تحقق مستقل' : 'Independent verification',
        });
        expect(find.byType(CheckboxListTile), findsNothing);
        expect(
          find.byKey(const ValueKey('recovery-proposal-accept')),
          findsNothing,
        );
        expect(
          find.text(
            ar
                ? 'سُجل طلب التحقق. راجع حالة طلب الاسترجاع لمعرفة القرار النهائي؛ هذه الخطوة لا تنشئ ربطًا بنفسها.'
                : 'Your verification request is recorded. Check your recovery request for the final decision; this step does not create a link.',
          ),
          findsOneWidget,
        );
        expect(store.ref, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'proposal Auth invalidation clears notices and late acceptance cannot show a private success',
    (tester) async {
      final client = await auth.client(tester), store = proposal.Store();
      final gateway = Gateway(store)
        ..pending = Completer<Map<String, dynamic>>();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(tester, client, gateway, store);
      client.testAuth.events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession),
      );
      await tester.pump();
      for (final title in [
        'I agree to review the owner proposal',
        'I agree to request independent verification',
      ]) {
        await press(tester, find.widgetWithText(CheckboxListTile, title));
      }
      final submit = find.byKey(const ValueKey('recovery-proposal-accept'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      final saved = store.ref!;
      expect(gateway.accepts, 1);
      client.testAuth.user = null;
      gateway.user = null;
      client.testAuth.events.add(AuthState(AuthChangeEvent.signedOut, null));
      await tester.pump();
      gateway.pending!.complete(gateway.receipt(saved));
      await tester.pumpAndSettle();
      expect(
        find.text('Your session changed. Reopen with the correct account.'),
        findsOneWidget,
      );
      expect(find.text('Review consent'), findsNothing);
      expect(find.text('Independent verification'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(
        find.text(
          'Your verification request is recorded. Check your recovery request for the final decision; this step does not create a link.',
        ),
        findsNothing,
      );
      expect(store.ref!.values, saved.values);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uncertain proposal restart only reads same saved nonce then explicit safe close and acknowledgement',
    (tester) async {
      final client = await auth.client(tester), store = proposal.Store();
      const saved = RecoveryProposalReference(
        '44444444-4444-4444-8444-444444444444',
        proposal.caseId,
        proposal.proposal,
      );
      store.ref = saved;
      final gateway = Gateway(store)..outcome = 'absent';
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(tester, client, gateway, store);
      expect(gateway.currents, 0);
      expect(gateway.readRequests, [saved.request]);
      expect(gateway.accepts, 0);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(
        find.byKey(const ValueKey('recovery-proposal-accept')),
        findsNothing,
      );
      expect(
        find.text(
          'The previous attempt may have completed. Check its result or safely close its reference before another attempt.',
        ),
        findsOneWidget,
      );
      await press(
        tester,
        find.widgetWithText(OutlinedButton, 'Refresh proposal and outcome'),
      );
      expect(gateway.readRequests, [saved.request, saved.request]);
      expect(store.ref!.values, saved.values);
      await press(
        tester,
        find.widgetWithText(OutlinedButton, 'Safely close attempt reference'),
      );
      expect(gateway.closedRequests, [saved.request]);
      expect(store.ref!.values, saved.values);
      expect(
        find.text(
          'The attempt reference is closed; prior reviews were not cancelled.',
        ),
        findsOneWidget,
      );
      await press(
        tester,
        find.widgetWithText(OutlinedButton, 'I reviewed the consent outcome'),
      );
      expect(store.ref, isNull);
      expect(gateway.accepts, 0);
      expect(gateway.currents, 1);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(
                CheckboxListTile,
                'I agree to review the owner proposal',
              ),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(
                CheckboxListTile,
                'I agree to request independent verification',
              ),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('recovery-proposal-accept')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reusing proposal panel for changed case invalidates view without adopting or clearing saved tuple',
    (tester) async {
      final client = await auth.client(tester), store = proposal.Store();
      const saved = RecoveryProposalReference(
        '44444444-4444-4444-8444-444444444444',
        proposal.caseId,
        proposal.proposal,
      );
      store.ref = saved;
      final gateway = Gateway(store)..outcome = 'absent';
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPanel(tester, client, gateway, store);
      expect(gateway.readRequests, [saved.request]);
      await showPanel(
        tester,
        client,
        gateway,
        store,
        caseId: '55555555-5555-4555-8555-555555555555',
      );
      expect(
        find.text('Your session changed. Reopen with the correct account.'),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(
        find.byKey(const ValueKey('recovery-proposal-accept')),
        findsNothing,
      );
      expect(gateway.readRequests, [saved.request]);
      expect(gateway.currents, 0);
      expect(gateway.accepts, 0);
      expect(gateway.closedRequests, isEmpty);
      expect(store.ref!.values, saved.values);
      expect(tester.takeException(), isNull);
    },
  );
}
