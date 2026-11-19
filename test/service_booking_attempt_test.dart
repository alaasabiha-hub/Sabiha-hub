import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/service_booking_attempt.dart';

const normal = {
  'p_service': 'service',
  'p_branch': 'branch',
  'p_vehicle': 'car',
  'p_date': '2026-12-01',
  'p_time': '10:00:00',
  'p_expected_price': 137.45,
  'p_notes': 'server-private-note',
};

class Server {
  String? stored;
  String state = 'absent', mode = 'normal';
  Map<String, dynamic>? payload;
  bool losePlacement = false,
      loseRecovery = false,
      loseAck = false,
      commitBeforeLoss = false;
  final writes = <Map<String, dynamic>>[];
  final preferenceWrites = <String>[];
  Future<dynamic> rpc(String name, Map<String, dynamic> args) async {
    if (name == 'get_service_booking_attempt') {
      if (loseRecovery) {
        loseRecovery = false;
        throw const SocketException('lost lookup');
      }
      return {
        'state': state,
        'request_id': args['p_request'] ?? stored,
        'mode': mode,
        if (payload != null) 'payload': payload,
        if (state == 'succeeded')
          'result': {
            'booking_id': 'saved',
            'invoice_id': 'issued',
            'amount_due': mode == 'reward' ? 0 : 137.45,
          },
      };
    }
    if (name == 'prepare_service_booking_attempt') {
      payload = Map<String, dynamic>.from(args['p_payload'] as Map);
      mode = args['p_mode'] as String;
      state = 'open';
      return {
        'state': 'open',
        'request_id': args['p_request'],
        'mode': mode,
        'payload': payload,
      };
    }
    if (name.startsWith('place_')) {
      writes.add(Map<String, dynamic>.from(args));
      if (losePlacement) {
        if (commitBeforeLoss) {
          state = 'succeeded';
          loseRecovery = true;
        }
        losePlacement = false;
        throw const SocketException('response lost');
      }
      state = 'succeeded';
      return {'booking_id': 'saved'};
    }
    if (name == 'close_service_booking_attempt') {
      if (state != 'succeeded') state = 'closed';
      return {
        'state': state,
        'request_id': args['p_request'],
        if (state == 'succeeded') 'result': {'booking_id': 'saved'},
      };
    }
    if (name == 'acknowledge_service_booking_attempt') {
      if (loseAck) {
        loseAck = false;
        throw TimeoutException('ack lost');
      }
      return {'state': 'acknowledged', 'request_id': args['p_request']};
    }
    throw StateError(name);
  }

  ServiceBookingAttempt client() => ServiceBookingAttempt(
    rpc: rpc,
    readId: () async => stored,
    writeId: (id) async {
      stored = id;
      preferenceWrites.add(id);
    },
    clearId: () async => stored = null,
  );
}

void main() {
  test('unknown normal placement freezes mode and reopens exact eight argument retry with UUID-only persistence', () async {
    final server = Server()..losePlacement = true;
    final first = server.client();
    await first.initialize();
    await first.submit('normal', normal);
    expect(first.locked, isTrue);
    expect(server.writes.single.keys, hasLength(8));
    final original = Map<String, dynamic>.from(server.writes.single);
    await first.submit('reward', {'p_quote': 'different'});
    expect(server.writes, hasLength(1));
    expect(first.mode, 'normal');
    expect(
      server.preferenceWrites.every(
        (id) => RegExp(r'^[a-f0-9-]{36}$').hasMatch(id),
      ),
      isTrue,
    );
    expect(server.stored, original['p_request']);
    first.dispose();
    final reopened = server.client();
    await reopened.initialize();
    expect(reopened.locked, isTrue);
    await reopened.retry();
    expect(server.writes, hasLength(2));
    expect(server.writes.last, original);
    expect(reopened.succeeded, isTrue);
    expect(reopened.locked, isTrue);
    expect(await reopened.acknowledge(), isTrue);
    expect(reopened.locked, isFalse);
    expect(server.stored, isNull);
    reopened.dispose();
  });
  test(
    'saved UUID plus absent lookup never unlocks without server tombstone',
    () async {
      final server = Server()..stored = 'old-id';
      final attempt = server.client();
      await attempt.initialize();
      expect(attempt.state, 'absent');
      expect(attempt.locked, isTrue);
      await attempt.close();
      expect(attempt.state, 'closed');
      expect(attempt.locked, isFalse);
      expect(server.stored, isNull);
      attempt.dispose();
    },
  );
  test('failed cross-device recovery with no UUID stays frozen', () async {
    final server = Server()..loseRecovery = true;
    final attempt = server.client();
    await attempt.initialize();
    expect(attempt.locked, isTrue);
    expect(attempt.state, 'unknown');
    await attempt.recover();
    expect(attempt.locked, isFalse);
    attempt.dispose();
  });
  test(
    'reward retry uses exact prepared consent body and never normal endpoint',
    () async {
      final server = Server()..losePlacement = true;
      final attempt = server.client();
      await attempt.initialize();
      await attempt.submit('reward', {
        'p_quote': 'quote',
        'p_fingerprint': 'fingerprint',
        'p_accept_terms': true,
        'p_adopt_existing_visits': true,
      });
      expect(attempt.locked, isTrue);
      await attempt.retry();
      expect(server.writes[0], server.writes[1]);
      expect(
        server.writes.first.keys,
        unorderedEquals([
          'p_request',
          'p_quote',
          'p_fingerprint',
          'p_accept_terms',
          'p_adopt_existing_visits',
        ]),
      );
      expect(attempt.mode, 'reward');
      attempt.dispose();
    },
  );
  test(
    'successful close result is a receipt, not cancellation or unlock',
    () async {
      final server = Server()
        ..losePlacement = true
        ..commitBeforeLoss = true;
      final attempt = server.client();
      await attempt.initialize();
      await attempt.submit('normal', normal);
      expect(attempt.locked, isTrue);
      await attempt.close();
      expect(attempt.succeeded, isTrue);
      expect(attempt.locked, isTrue);
      expect(server.stored, isNotNull);
      attempt.dispose();
    },
  );
  test('lost acknowledgement retains UUID and canonical receipt until explicit retry', () async {
    final server = Server()..loseAck = true;
    final attempt = server.client();
    await attempt.initialize();
    await attempt.submit('normal', normal);
    expect(await attempt.acknowledge(), isFalse);
    expect(attempt.succeeded, isTrue);
    expect(attempt.locked, isTrue);
    expect(await attempt.acknowledge(), isTrue);
    attempt.dispose();
  });
  test('different mode and manual review never unlock or place', () async {
    for (final status in ['different_mode', 'manual_review_required']) {
      final server = Server()
        ..stored = 'id'
        ..state = status;
      final attempt = server.client();
      await attempt.initialize();
      expect(attempt.locked, isTrue);
      expect(attempt.canRetry, isFalse);
      await attempt.submit('normal', normal);
      expect(server.writes, isEmpty);
      attempt.dispose();
    }
  });
}
