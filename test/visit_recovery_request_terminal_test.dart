import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'visit_recovery_request_test.dart' as fixtures;

class TerminalGateway extends fixtures.Gateway {
  TerminalGateway(this.snapshot);
  final Map<String, dynamic> snapshot;
  @override
  Future<Map<String, dynamic>> current() async => snapshot;
}

void main() {
  testWidgets(
    'terminal new review needs fresh server flag and consent; active and linked never resubmit',
    (t) async {
      final client = await fixtures.client(t);
      for (final status in [
        'awaiting_matching',
        'linked',
        'rejected',
        'revoked',
      ]) {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump();
        final snapshot = {
          ...fixtures.receipt(),
          'case': {
            'case_id': fixtures.otherId,
            'status': status,
            'identity_current': false,
          },
          'new_request_allowed': true,
          'consent': {
            'version': 'visit-recovery-v1',
            'notice_ar': 'موافقة جديدة من الخادم للمراجعة المستقلة',
            'notice_en': 'Fresh independent review notice from server',
          },
        };
        final api = TerminalGateway(snapshot), store = fixtures.Store();
        final language = status == 'revoked' ? 'en' : 'ar';
        await fixtures.showPanel(
          t,
          client,
          api,
          store,
          language: language,
          width: language == 'ar' ? 390 : 1440,
        );
        if (['awaiting_matching', 'linked'].contains(status)) {
          expect(find.byKey(const ValueKey('recovery_submit')), findsNothing);
          expect(api.submits, isEmpty);
          continue;
        }
        expect(
          find.text(
            language == 'ar'
                ? 'إرسال طلب جديد للمراجعة'
                : 'Send a new request for review',
          ),
          findsOneWidget,
        );
        expect(
          t
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('recovery_consent')),
              )
              .value,
          isFalse,
        );
        expect(
          t
              .widget<FilledButton>(
                find.byKey(const ValueKey('recovery_submit')),
              )
              .onPressed,
          isNull,
        );
        await fixtures.press(t, 'recovery_consent');
        await fixtures.press(t, 'recovery_submit');
        expect(api.submits, hasLength(1));
        expect(
          (api.submits.single['p_consent'] as Map)['text'],
          language == 'ar'
              ? 'موافقة جديدة من الخادم للمراجعة المستقلة'
              : 'Fresh independent review notice from server',
        );
        expect((api.submits.single['p_consent'] as Map)['language'], language);
        expect(
          api.submits.single.keys,
          unorderedEquals(['p_request', 'p_consent']),
        );
        expect(
          find.text(fixtures.receipt()['receipt_message_$language'] as String),
          findsOneWidget,
        );
        expect(store.writes, hasLength(1));
        await fixtures.press(t, 'recovery_acknowledge');
        expect(store.value, isNull);
        expect(t.takeException(), isNull);
      }
      for (final allowed in [false, true]) {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump();
        final api = TerminalGateway({
          ...fixtures.receipt(),
          'case': {
            'case_id': fixtures.otherId,
            'status': 'rejected',
            'identity_current': true,
          },
          'new_request_allowed': allowed,
        });
        await fixtures.showPanel(t, client, api, fixtures.Store());
        expect(find.byKey(const ValueKey('recovery_submit')), findsNothing);
        expect(api.submits, isEmpty);
      }
    },
  );
}
