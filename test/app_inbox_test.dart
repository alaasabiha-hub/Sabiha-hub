import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_inbox.dart';
import 'package:sabiha_hub/offline_customer_claim.dart';

class Gateway implements OfflineClaimGateway {
  final calls = <Map<String, dynamic>>[];
  Future<dynamic> Function(String, Map<String, dynamic>)? handle;
  @override
  Future<dynamic> rpc(String name, Map<String, dynamic> parameters) async {
    calls.add({'name': name, ...parameters});
    return handle!(name, parameters);
  }
}

Map<String, dynamic> page({
  String id = 'event-a',
  Map<String, dynamic>? cursor,
}) => {
  'items': [
    {
      'event_id': id,
      'read': false,
      'title_en': 'Awaiting matching',
      'body_en': 'Private message',
    },
  ],
  'unread_count': 2,
  'next_cursor': cursor,
};
void main() {
  test(
    'bounded paired cursor and deduplication preserve one message',
    () async {
      final gateway = Gateway();
      final cursor = {
        'created_at': '2026-11-15T00:00:00Z',
        'event_id': 'event-a',
      };
      gateway.handle = (_, p) async =>
          page(cursor: p['p_before_event'] == null ? cursor : null);
      final flow = AppInboxController(
        gateway: gateway,
        actorId: () => 'actor-a',
      );
      await flow.refresh();
      await flow.refresh(more: true);
      expect(gateway.calls.first['p_limit'], 25);
      expect(gateway.calls.last['p_before_created_at'], cursor['created_at']);
      expect(gateway.calls.last['p_before_event'], cursor['event_id']);
      expect(flow.items.length, 1);
      expect(flow.cursor, isNull);
      flow.dispose();
    },
  );
  test(
    'lost read acknowledgement retries same nonce without optimistic mark',
    () async {
      final gateway = Gateway();
      var attempt = 0;
      gateway.handle = (name, p) async {
        if (name == 'list_my_app_inbox') return page();
        if (++attempt == 1) throw StateError('Lost response');
        return {
          'event_id': p['p_event'],
          'read': true,
          'read_at': '2026-11-15T00:00:00Z',
        };
      };
      final flow = AppInboxController(
        gateway: gateway,
        actorId: () => 'actor-a',
      );
      await flow.refresh();
      await flow.markRead('event-a');
      expect(flow.failed, isTrue);
      expect(flow.items, isEmpty);
      final nonce = gateway.calls.last['p_request'];
      await flow.refresh();
      await flow.markRead('event-a');
      expect(gateway.calls.last['p_request'], nonce);
      expect(flow.items.single['read'], isTrue);
      expect(flow.unread, 1);
      flow.dispose();
    },
  );
  test(
    'account switch clears messages and rejects late old account response',
    () async {
      final pending = Completer<dynamic>();
      final gateway = Gateway();
      String? actor = 'actor-a';
      gateway.handle = (_, _) => pending.future;
      final flow = AppInboxController(gateway: gateway, actorId: () => actor);
      final work = flow.refresh();
      actor = 'actor-b';
      flow.clearOnAccountChange();
      pending.complete(page());
      await work;
      expect(flow.items, isEmpty);
      expect(flow.unread, 0);
      expect(flow.busy, isFalse);
      await flow.refresh();
      expect(gateway.calls.length, 1);
      flow.dispose();
    },
  );
  test('authorization failure removes old private messages', () async {
    final gateway = Gateway();
    gateway.handle = (_, _) async => page();
    final flow = AppInboxController(gateway: gateway, actorId: () => 'actor-a');
    await flow.refresh();
    expect(flow.items, isNotEmpty);
    gateway.handle = (_, _) async => throw StateError('Permission revoked');
    await flow.refresh();
    expect(flow.items, isEmpty);
    expect(flow.failed, isTrue);
    flow.dispose();
  });
  test('disposed controller ignores in-flight response', () async {
    final pending = Completer<dynamic>();
    final gateway = Gateway();
    gateway.handle = (_, _) => pending.future;
    final flow = AppInboxController(gateway: gateway, actorId: () => 'actor-a');
    final work = flow.refresh();
    flow.dispose();
    pending.complete(page());
    await work;
    expect(flow.items, isEmpty);
  });
}
