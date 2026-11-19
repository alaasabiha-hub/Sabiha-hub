import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabiha_hub/visit_recovery_evidence.dart';

import 'visit_recovery_evidence_test.dart' as evidence;
import 'visit_recovery_request_test.dart' as request;

class CurrentEvidence extends evidence.Gateway {
  CurrentEvidence(super.store, this.readLatest);
  final Map<String, dynamic> Function() readLatest;
  int latestReads = 0;
  @override
  Future<Map<String, dynamic>> currentCase(String? id) async {
    latestReads++;
    return readLatest();
  }
}

void main() {
  testWidgets(
    'confirmed new request refreshes stale terminal evidence without manual refresh or proof mutation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final old = {
        ...request.receipt(),
        'case': {
          'case_id': request.otherId,
          'status': 'rejected',
          'identity_current': true,
        },
        'new_request_allowed': true,
        'consent': request.notice()['consent'],
      };
      Map<String, dynamic> latest = old;
      final apiCalls = <String>[];
      final auth = evidence.TestAuth();
      final client = (await tester.runAsync(
        () async => evidence.TestClient(
          auth,
          transport: MockClient((r) async {
            final name = r.url.path.split('/').last;
            apiCalls.add(name);
            expect(
              name,
              anyOf(
                'get_my_visit_recovery_request',
                'submit_visit_recovery_request',
              ),
            );
            if (name == 'submit_visit_recovery_request') {
              expect(
                (jsonDecode(r.body)['p_consent'] as Map)['accepted'],
                true,
              );
              latest = request.receipt();
            }
            return http.Response(
              jsonEncode(latest),
              200,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }),
        ),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async {
          await client.dispose();
          await auth.events.close();
          auth.dispose();
        });
      });
      final store = evidence.Store([]);
      final proof = CurrentEvidence(store, () => latest);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: VisitRecoveryEvidenceScreen(
            proposalBuilder: (_, _) => const SizedBox.shrink(),
            client: client,
            gateway: proof,
            attachmentStore: store,
            claimStore: evidence.ClaimStore(),
          ),
        ),
      );
      Future<void> flush() async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
      }

      await flush();
      expect(
        find.text(
          'Review of this request has ended. Check its status before any new request.',
        ),
        findsOneWidget,
      );
      final before = proof.latestReads;
      await tester.ensureVisible(
        find.byKey(const ValueKey('recovery_consent')),
      );
      await tester.tap(find.byKey(const ValueKey('recovery_consent')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('recovery_submit')));
      await tester.tap(find.byKey(const ValueKey('recovery_submit')));
      await flush();
      expect(
        apiCalls.where((name) => name == 'submit_visit_recovery_request'),
        hasLength(1),
      );
      expect(proof.latestReads, greaterThan(before));
      expect(
        find.text(
          'Review of this request has ended. Check its status before any new request.',
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('recovery-open-proof')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('recovery-open-proof')),
            )
            .onPressed,
        isNotNull,
      );
      expect(store.refs, isEmpty);
      expect(proof.sent, isEmpty);
      expect(
        proof.events.where((value) => value.startsWith('claim:')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
