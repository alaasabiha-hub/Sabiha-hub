import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/cashier_invoice_draft.dart';
import 'package:sabiha_hub/cashier_loyalty_intent.dart';

class Gateway implements CashierCartGateway {
  bool live = true, loseAck = false, forgeAuthorization = false;
  Completer<Map<String, dynamic>>? wait;
  final events = StreamController<void>.broadcast(sync: true);
  final calls = <Map<String, dynamic>>[];
  String state = 'current';
  @override
  bool get current => live;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async {
    calls.add({'name': name, ...params});
    if (wait != null) return wait!.future;
    if (loseAck) {
      loseAck = false;
      throw TimeoutException('Lost seal response');
    }
    return receipt(
      params['p_request'],
      forge: forgeAuthorization,
      state: name.startsWith('get_') ? state : null,
    );
  }
}

Map<String, dynamic> receipt(Object? id, {bool forge = false, String? state}) =>
    {
      'intent_id': id,
      'fingerprint': 'a' * 64,
      'expires_at': '2026-11-16T12:00:00Z',
      'seal_only': true,
      'consent_authorized': forge,
      'redemption_enabled': false,
      if (state != null) ...{'state': state, 'wallet_disclosed': false},
    };
CashierLoyaltyDraftSeal seal(Gateway g) => CashierLoyaltyDraftSeal(
  gateway: g,
  branch: 'qa-branch',
  draft: 'qa-draft',
  draftVersion: 3,
  bindingVersion: 2,
);
void main() {
  test('An uncertain seal retries the exact nonce and immutable version, never a monetary operation', () async {
    final g = Gateway()..loseAck = true;
    final c = seal(g);
    await expectLater(c.prepare(), throwsA(isA<TimeoutException>()));
    final result = await c.prepare();
    expect(g.calls[0], g.calls[1]);
    expect(result['consent_authorized'], false);
    expect(g.calls[0].keys.toSet(), {
      'name',
      'p_request',
      'p_branch',
      'p_draft',
      'p_expected_draft_version',
      'p_expected_binding_version',
    });
    expect(() => result['redemption_enabled'] = true, throwsUnsupportedError);
    c.dispose();
    await g.events.close();
  });
  test('Concurrent prepares coalesce; an identity change discards the delayed response', () async {
    final g = Gateway()..wait = Completer();
    final c = seal(g);
    final a = c.prepare(), b = c.prepare();
    expect(identical(a, b), true);
    expect(g.calls.length, 1);
    final rejection = expectLater(a, throwsStateError);
    g.live = false;
    g.events.add(null);
    g.wait!.complete(receipt(g.calls.single['p_request']));
    await rejection;
    expect(() => c.prepare(), throwsStateError);
    await g.events.close();
  });
  test(
    'The base seal rejects forged spending or customer-consent authorization',
    () async {
      final g = Gateway()..forgeAuthorization = true;
      final c = seal(g);
      await expectLater(c.prepare(), throwsStateError);
      c.dispose();
      await g.events.close();
    },
  );
  test(
    'Stale and expired states stay explicit and do not request another seal',
    () async {
      final g = Gateway();
      final c = seal(g);
      await c.prepare();
      for (final state in ['stale', 'expired']) {
        g.state = state;
        expect((await c.refresh())['state'], state);
      }
      expect(
        g.calls.where((x) => x['name'] == 'seal_cashier_loyalty_draft').length,
        1,
      );
      c.dispose();
      await g.events.close();
    },
  );
}
