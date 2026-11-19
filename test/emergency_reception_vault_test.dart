import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/emergency_reception_vault.dart';

const actor = '10000000-0000-4000-8000-000000000001',
    branch = '20000000-0000-4000-8000-000000000001',
    booking = '30000000-0000-4000-8000-000000000001';
const password = 'isolated-vault-test-phrase-2026';
String id(int n) => '40000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
Map<String, dynamic> request(int n) => {
  'p_request': id(n),
  'p_booking': booking,
  'p_action': 'arrive',
  'p_priority': 'normal',
  'p_expected_revision': 0,
  'p_reason': 'Isolated emergency arrival note',
};

class Store implements EmergencyVaultStore {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? readGate;
  @override
  Future<String?> read(String key) async {
    if (readGate != null) await readGate!.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String ciphertext) async {
    if (fail) throw StateError('Isolated storage unavailable');
    values[key] = ciphertext;
  }
}

EmergencyReceptionVault vault(
  Store store, {
  String phrase = password,
  String user = actor,
  bool Function()? current,
}) => EmergencyReceptionVault(
  store: store,
  actor: user,
  password: phrase,
  current: current ?? () => true,
);
final code = (String value) =>
    isA<EmergencyVaultException>().having((e) => e.code, 'code', value);
void main() {
  late String seed;
  late String key;
  setUpAll(() async {
    final store = Store(), v = vault(Store());
    v.lock();
    final prepared = vault(store);
    await prepared.enqueue(request: request(1), branch: branch);
    key = prepared.storageKey;
    seed = store.values[key]!;
    prepared.lock();
    final output = Platform.environment['SABIHA_VAULT_ORACLE_FILE'];
    if (output != null) File(output).writeAsStringSync(seed);
  });
  Store seeded() => Store()..values[key] = seed;
  test('AES-GCM journal is encrypted and reopens using real PBKDF2', () async {
    final store = seeded();
    final v = vault(store);
    final rows = await v.list();
    expect(rows.single['request'], request(1));
    expect(seed.contains(password), isFalse);
    expect(seed.contains('Isolated emergency arrival note'), isFalse);
    expect(seed.contains(actor), isFalse);
    final envelope = jsonDecode(seed) as Map;
    expect(envelope['iterations'], 600000);
    expect(base64Decode(envelope['salt']).length, 16);
    expect(base64Decode(envelope['nonce']).length, 12);
    expect(base64Decode(envelope['tag']).length, 16);
    v.lock();
  });
  test(
    'wrong unlock phrase preserves the existing encrypted journal',
    () async {
      final store = seeded();
      final v = vault(store, phrase: 'a-different-long-test-phrase');
      await expectLater(v.list(), throwsA(code('corrupt_or_wrong_key')));
      expect(store.values[key], seed);
      v.lock();
    },
  );
  test(
    'ciphertext substitution and another account fail authentication',
    () async {
      final store = seeded();
      final envelope = jsonDecode(seed) as Map<String, dynamic>;
      final tag = base64Decode(envelope['tag'] as String);
      tag[0] ^= 1;
      envelope['tag'] = base64Encode(tag);
      final tampered = jsonEncode(envelope);
      store.values[key] = tampered;
      final v = vault(store);
      await expectLater(v.list(), throwsA(code('corrupt_or_wrong_key')));
      expect(store.values[key], tampered);
      v.lock();
      final other = vault(store, user: '10000000-0000-4000-8000-000000000002');
      store.values[other.storageKey] = seed;
      await expectLater(other.list(), throwsA(code('corrupt_or_wrong_key')));
      expect(store.values[key], tampered);
      other.lock();
    },
  );
  test(
    'same nonce is immutable and unordered equivalent input is replayed',
    () async {
      final store = seeded(), v = vault(seeded());
      v.lock();
      final opened = vault(store);
      final before = store.values[key];
      final replay = await opened.enqueue(
        request: Map.fromEntries(request(1).entries.toList().reversed),
        branch: branch,
      );
      expect(replay['request'], request(1));
      expect(store.values[key], before);
      await expectLater(
        opened.enqueue(
          request: {
            ...request(1),
            'p_reason': 'A changed reason must be rejected',
          },
          branch: branch,
        ),
        throwsA(code('nonce_mismatch')),
      );
      (replay['request'] as Map)['p_reason'] = 'External mutation';
      expect((await opened.list()).single['request'], request(1));
      opened.lock();
    },
  );
  test('two simultaneous journal writers retain both drafts', () async {
    final store = seeded();
    final a = vault(store), b = vault(store);
    await Future.wait([
      a.enqueue(request: request(2), branch: branch),
      b.enqueue(request: request(3), branch: branch),
    ]);
    expect((await a.list()).map((r) => r['request']['p_request']).toSet(), {
      id(1),
      id(2),
      id(3),
    });
    a.lock();
    b.lock();
  });
  test(
    'unsent cancellation retains history and sent draft cannot be discarded',
    () async {
      final store = seeded();
      final v = vault(store);
      await v.cancelUnsent(id(1));
      expect((await v.list()).single['state'], 'cancelled');
      await expectLater(v.beginDispatch(id(1)), throwsA(code('closed_draft')));
      await v.enqueue(request: request(2), branch: branch);
      await v.beginDispatch(id(2));
      await expectLater(
        v.cancelUnsent(id(2)),
        throwsA(code('resolution_required')),
      );
      await v.failure(id(2), definitive: true);
      expect((await v.list()).last['state'], 'conflict');
      expect((await v.list()).last['request'], request(2));
      v.lock();
    },
  );
  test(
    'receipt must match booking branch priority and exact revision',
    () async {
      final store = seeded();
      final v = vault(store);
      await v.beginDispatch(id(1));
      final before = store.values[key];
      final receipt = {
        'booking_id': booking,
        'branch_id': branch,
        'priority': 'normal',
        'revision': 1,
        'arrived_at': '2026-11-15T10:00:00Z',
      };
      await expectLater(
        v.confirm(id(1), {
          ...receipt,
          'branch_id': '20000000-0000-4000-8000-000000000002',
        }),
        throwsA(code('receipt_mismatch')),
      );
      expect(store.values[key], before);
      final row = await v.confirm(id(1), receipt);
      expect(row['state'], 'confirmed');
      expect(row['request'], request(1));
      expect(row['receipt'], receipt);
      v.lock();
    },
  );
  test('failed persistence cannot claim a new draft was saved', () async {
    final store = seeded()..fail = true;
    final v = vault(store);
    await expectLater(
      v.enqueue(request: request(2), branch: branch),
      throwsStateError,
    );
    expect(store.values[key], seed);
    store.fail = false;
    expect((await v.list()).length, 1);
    v.lock();
  });
  test(
    'account loss while storage is awaited prevents creating a journal',
    () async {
      var active = true;
      final store = Store()..readGate = Completer<void>();
      final v = vault(store, current: () => active);
      final operation = v.list();
      final expectation = expectLater(operation, throwsA(code('locked')));
      active = false;
      store.readGate!.complete();
      await expectation;
      expect(store.values, isEmpty);
      v.lock();
    },
  );
  test('corrupt or weaker encryption headers never overwrite data', () async {
    final store = seeded();
    final envelope = jsonDecode(seed) as Map<String, dynamic>;
    envelope['iterations'] = 1;
    final bad = jsonEncode(envelope);
    store.values[key] = bad;
    final v = vault(store);
    await expectLater(v.list(), throwsA(code('corrupt_or_wrong_key')));
    expect(store.values[key], bad);
    v.lock();
  });
  test('actual encrypted draft retains the real booking reference without changing RPC fields', () async {
    final store = Store();
    final opened = vault(store);
    final saved = await opened.enqueue(request: request(42), branch: branch, reference: 'SH-BKG-000042');
    expect(saved['reference'], 'SH-BKG-000042');
    expect(saved['request'], request(42));
    expect((await opened.list()).single['reference'], 'SH-BKG-000042');
    final before = store.values[opened.storageKey];
    await expectLater(opened.enqueue(request: request(43), branch: branch, reference: ''), throwsA(code('invalid_draft')));
    expect(store.values[opened.storageKey], before);
    opened.lock();
  });

}
