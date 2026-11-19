import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/owner_visit_recovery.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';

class Store implements OfflineClaimStore {
  String? id;
  List<String> writes = [];
  @override
  Future<String?> read() async => id;
  @override
  Future<void> write(String v) async {
    id = v;
    writes.add(v);
  }

  @override
  Future<void> clear() async {
    id = null;
  }
}

class Gateway implements OfflineClaimGateway {
  List<(String, Map<String, dynamic>)> calls = [];
  late Future<dynamic> Function(String, Map<String, dynamic>) handler;
  @override
  Future<dynamic> rpc(String n, Map<String, dynamic> p) {
    calls.add((n, p));
    return handler(n, p);
  }
}

Map<String, dynamic> item({bool mapped = false}) => {
  'case_id': 'case-1',
  'created_at': '2026-11-15T00:00:00Z',
  'status': 'awaiting_matching',
  'requester_name': 'QA Person',
  'registered_phone': '01000000000',
  'identity_current': true,
  'canonical_claim_mapped': mapped,
  'canonical_claim_reference': mapped ? 'claim-1' : null,
  'more_info_available': !mapped,
  'reject_available': !mapped,
};
Map<String, dynamic> page({bool mapped = false}) => {
  'items': [item(mapped: mapped)],
  'next_cursor': null,
};
void main() {
  late SupabaseClient client;
  setUpAll(() {
    client = SupabaseClient('http://127.0.0.1:54321', 'test-key');
  });
  tearDownAll(() async {
    await client.dispose();
  });
  test(
    'persists UUID before prepare; server payload and expected status retained',
    () async {
      final s = Store(), g = Gateway();
      g.handler = (n, p) async {
        if (n == 'list_visit_recovery_requests') return page();
        expect(s.id, p['p_request']);
        expect(p['p_expected_status'], 'awaiting_matching');
        return {
          'request_id': p['p_request'],
          'state': 'open',
          'payload': {'private_reason': p['p_reason']},
        };
      };
      final c = OwnerVisitRecoveryController(gateway: g, store: s);
      await c.initialize();
      await c.prepare(item(), 'reject', 'Actual private owner reason');
      expect(c.state, 'open');
      expect(s.writes.length, 1);
      expect(s.writes.single, isNot(contains('reason')));
      expect(g.calls.last.$1, 'prepare_visit_recovery_review');
      c.dispose();
    },
  );
  test('lost prepare freezes and absent recovery cannot clear nonce; close fences it', () async {
    final s = Store(), g = Gateway();
    g.handler = (n, p) async {
      if (n == 'list_visit_recovery_requests') return page();
      if (n == 'prepare_visit_recovery_review') throw Exception('network');
      return {
        'request_id': p['p_request'],
        'state': n == 'close_visit_recovery_review' ? 'closed' : 'absent',
      };
    };
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    await c.initialize();
    await c.prepare(item(), 'reject', 'A legitimate owner reason');
    final nonce = c.requestId;
    await c.refresh();
    expect(c.state, 'absent');
    await c.acknowledge();
    expect(c.requestId, nonce);
    expect(c.locked, true);
    await c.close();
    expect(c.state, 'closed');
    await c.acknowledge();
    expect(c.requestId, null);
    expect(s.id, null);
    c.dispose();
  });
  test('restart open receipt retries apply by UUID only, never reconstructed reason', () async {
    final s = Store()..id = 'saved-uuid', g = Gateway();
    g.handler = (n, p) async {
      if (n == 'list_visit_recovery_requests') return page();
      if (n == 'apply_visit_recovery_review') {
        expect(p, {'p_request': 'saved-uuid'});
        return {
          'request_id': 'saved-uuid',
          'state': 'succeeded',
          'result': {'case_status': 'rejected'},
        };
      }
      return {
        'request_id': 'saved-uuid',
        'state': 'open',
        'payload': {'private_reason': 'Server prepared exact reason'},
      };
    };
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    await c.initialize();
    await c.apply();
    expect(c.state, 'succeeded');
    expect(s.id, 'saved-uuid');
    await c.acknowledge();
    expect(s.id, null);
    c.dispose();
  });
  test(
    'mapped case and invalid short reason do not create review commands',
    () async {
      final s = Store(), g = Gateway()..handler = (n, p) async => page();
      final c = OwnerVisitRecoveryController(gateway: g, store: s);
      await c.initialize();
      await c.prepare(
        item(mapped: true),
        'reject',
        'A legitimate owner reason',
      );
      await c.prepare(item(), 'reject', 'short');
      expect(g.calls.length, 1);
      expect(s.id, null);
      c.dispose();
    },
  );
  test('stale comparison keeps nonce frozen until close', () async {
    final s = Store(), g = Gateway();
    g.handler = (n, p) async {
      if (n == 'list_visit_recovery_requests') return page();
      throw const PostgrestException(message: 'Changed', code: '40001');
    };
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    await c.initialize();
    await c.prepare(item(), 'reject', 'Actual private owner reason');
    expect(c.error, 'stale');
    expect(c.locked, true);
    expect(c.requestId, isNotNull);
    c.dispose();
  });
  test('session epoch clears private views and ignores late previous identity list', () async {
    final pending = Completer<dynamic>();
    final s = Store(), g = Gateway()..handler = (n, p) => pending.future;
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    final task = c.initialize();
    await Future<void>.delayed(Duration.zero);
    c.invalidate();
    pending.complete(page());
    await task;
    expect(c.items, isEmpty);
    expect(c.invalid, true);
    expect(c.receipt, null);
    c.dispose();
  });
  test('pagination sends only bounded complete server cursor', () async {
    final s = Store(), g = Gateway();
    var loads = 0;
    g.handler = (n, p) async {
      loads++;
      expect(p['p_limit'], 25);
      if (loads == 1) {
        return {
          'items': [item()],
          'next_cursor': {'created_at': 'date', 'case_id': 'case-1'},
        };
      }
      expect(p['p_before_created_at'], 'date');
      expect(p['p_before_case'], 'case-1');
      return {'items': [], 'next_cursor': null};
    };
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    await c.initialize();
    await c.loadMore();
    expect(c.items.length, 1);
    expect(c.cursor, null);
    c.dispose();
  });
  test('owner permission failure clears cached private case data', () async {
    final s = Store(), g = Gateway();
    var first = true;
    g.handler = (name, params) async {
      if (first) {
        first = false;
        return page();
      }
      throw const PostgrestException(message: 'Denied', code: '42501');
    };
    final c = OwnerVisitRecoveryController(gateway: g, store: s);
    await c.initialize();
    expect(c.items, isNotEmpty);
    await c.refresh();
    expect(c.items, isEmpty);
    expect(c.receipt, null);
    expect(c.error, 'denied');
    c.dispose();
  });
  for (final config in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets('mapped canonical callback no approval action ${config.$1}', (
      tester,
    ) async {
      tester.view.physicalSize = Size(config.$2, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = Gateway()..handler = (n, p) async => page(mapped: true);
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(config.$1),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: OwnerVisitRecoveryScreen(
            client: client,
            gateway: g,
            store: Store(),
            onCanonicalReview: (context, id) async {
              expect(id, 'claim-1');
              called = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('claim-1'), findsOneWidget);
      final label = config.$1 == 'ar'
          ? 'فتح مراجعة الإثبات'
          : 'Open canonical review';
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(called, true);
      expect(find.text('Reject'), findsNothing);
      expect(find.text('رفض'), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
