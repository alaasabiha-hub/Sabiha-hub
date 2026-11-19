// Encrypted LOCAL operational drafts. These never authorize a server operation.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute, mapEquals;
import 'package:shared_preferences/shared_preferences.dart';

import 'emergency_vault_lock.dart'
    if (dart.library.js_interop) 'emergency_vault_lock_web.dart';

const emergencyVaultIterations = 600000;
const _maxPending = 100, _maxRecords = 1000, _maxBytes = 1024 * 1024;
final _uuid = RegExp(
  r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
);

String emergencyVaultStorageKey(String actor) {
  if (!_uuid.hasMatch(actor)) {
    throw const EmergencyVaultException('invalid_unlock');
  }
  return 'sabiha_emergency_v1_${sha256.convert(utf8.encode(actor.toLowerCase()))}';
}

class EmergencyVaultException implements Exception {
  final String code;
  const EmergencyVaultException(this.code);
  @override
  String toString() => 'EmergencyVaultException($code)';
}

abstract class EmergencyVaultStore {
  Future<String?> read(String key);
  Future<void> write(String key, String ciphertext);
}

class PreferencesEmergencyVaultStore implements EmergencyVaultStore {
  final SharedPreferencesAsync preferences;
  PreferencesEmergencyVaultStore({SharedPreferencesAsync? preferences})
    : preferences = preferences ?? SharedPreferencesAsync();
  @override
  Future<String?> read(String key) => preferences.getString(key);
  @override
  Future<void> write(String key, String ciphertext) =>
      preferences.setString(key, ciphertext);
}

Future<Uint8List> _deriveEmergencyKey(Map<String, Uint8List> values) async {
  final input = SecretKeyData(
    values['password']!,
    overwriteWhenDestroyed: true,
  );
  SecretKey? derived;
  try {
    derived = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: emergencyVaultIterations,
      bits: 256,
    ).deriveKey(secretKey: input, nonce: values['salt']!);
    return Uint8List.fromList(await derived.extractBytes());
  } finally {
    input.destroy();
    derived?.destroy();
    values['password']!.fillRange(0, values['password']!.length, 0);
  }
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

abstract class EmergencyReceptionJournal {
  Future<List<Map<String, dynamic>>> list();
  Future<Map<String, dynamic>> enqueue({
    required Map<String, dynamic> request,
    required String branch,
    DateTime? deviceTime,
    String? reference,
  });
  Future<Map<String, dynamic>> beginDispatch(String id);
  Future<Map<String, dynamic>> failure(String id, {required bool definitive});
  Future<Map<String, dynamic>> cancelUnsent(String id);
  Future<Map<String, dynamic>> confirm(String id, Map<String, dynamic> receipt);
  void lock();
}

class EmergencyReceptionVault implements EmergencyReceptionJournal {
  final EmergencyVaultStore store;
  final String actor;
  final bool Function() current;
  String? _password, _salt;
  SecretKeyData? _key;
  EmergencyReceptionVault({
    required this.store,
    required this.actor,
    required String password,
    required this.current,
  }) : _password = password {
    if (!_uuid.hasMatch(actor) ||
        password.trim().runes.length < 12 ||
        utf8.encode(password).length > 1024) {
      throw const EmergencyVaultException('invalid_unlock');
    }
  }
  String get storageKey => emergencyVaultStorageKey(actor);
  void check() {
    if (_password == null || !current()) {
      throw const EmergencyVaultException('locked');
    }
  }

  @override
  void lock() {
    _password = null;
    _key?.destroy();
    _key = null;
    _salt = null;
  }

  Future<T> _locked<T>(Future<T> Function() action) =>
      withEmergencyVaultLock(storageKey, () async {
        check();
        return await action();
      });
  List<int> _aad(String salt) => utf8.encode(
    jsonEncode([
      'sabiha_emergency_v1',
      actor.toLowerCase(),
      emergencyVaultIterations,
      salt,
    ]),
  );
  Future<SecretKeyData> _secret(String salt) async {
    check();
    if (_key != null && _salt == salt) return _key!;
    final password = Uint8List.fromList(utf8.encode(_password!));
    final material = await compute(_deriveEmergencyKey, {
      'password': password,
      'salt': Uint8List.fromList(base64Decode(salt)),
    });
    password.fillRange(0, password.length, 0);
    try {
      check();
      _key?.destroy();
      _key = SecretKeyData(
        Uint8List.fromList(material),
        overwriteWhenDestroyed: true,
      );
      _salt = salt;
      return _key!;
    } finally {
      material.fillRange(0, material.length, 0);
    }
  }

  List<int> _bytes(dynamic value, [int? exact]) {
    if (value is! String || value.length > _maxBytes * 2) {
      throw const EmergencyVaultException('corrupt_or_wrong_key');
    }
    final decoded = base64Decode(value);
    if (exact != null && decoded.length != exact) {
      throw const EmergencyVaultException('corrupt_or_wrong_key');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _read() async {
    check();
    final raw = await store.read(storageKey);
    check();
    if (raw == null) {
      final random = Random.secure();
      final salt = base64Encode(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final data = <String, dynamic>{
        'version': 1,
        'actor': actor.toLowerCase(),
        'drafts': <dynamic>[],
      };
      await _persist(data, salt);
      return data;
    }
    try {
      if (raw.length > _maxBytes * 2) {
        throw const EmergencyVaultException('corrupt_or_wrong_key');
      }
      final envelope = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (envelope.length != 8 ||
          envelope['version'] != 1 ||
          envelope['algorithm'] != 'AES-256-GCM' ||
          envelope['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          envelope['iterations'] != emergencyVaultIterations) {
        throw const EmergencyVaultException('corrupt_or_wrong_key');
      }
      _bytes(envelope['salt'], 16);
      final salt = envelope['salt'] as String;
      final secret = await _secret(salt);
      check();
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          _bytes(envelope['ciphertext']),
          nonce: _bytes(envelope['nonce'], 12),
          mac: Mac(_bytes(envelope['tag'], 16)),
        ),
        secretKey: secret,
        aad: _aad(salt),
      );
      check();
      try {
        if (plain.length > _maxBytes) {
          throw const EmergencyVaultException('capacity');
        }
        final data = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(plain)) as Map,
        );
        _validate(data);
        return data;
      } finally {
        if (plain is Uint8List) plain.fillRange(0, plain.length, 0);
      }
    } on EmergencyVaultException {
      rethrow;
    } catch (_) {
      throw const EmergencyVaultException('corrupt_or_wrong_key');
    }
  }

  void _validateRequest(Map<String, dynamic> request) {
    if (request.length != 6 ||
        !request.keys.toSet().containsAll({
          'p_request',
          'p_booking',
          'p_action',
          'p_priority',
          'p_expected_revision',
          'p_reason',
        }) ||
        request['p_request'] is! String ||
        !_uuid.hasMatch(request['p_request']) ||
        request['p_booking'] is! String ||
        !_uuid.hasMatch(request['p_booking']) ||
        !['arrive', 'priority'].contains(request['p_action']) ||
        !['normal', 'vip'].contains(request['p_priority']) ||
        request['p_expected_revision'] is! int ||
        (request['p_expected_revision'] as int) < 0 ||
        request['p_reason'] is! String ||
        (request['p_reason'] as String).trim().length < 5 ||
        (request['p_reason'] as String).length > 300) {
      throw const EmergencyVaultException('invalid_draft');
    }
  }

  void _validate(Map<String, dynamic> data) {
    if (data.length != 3 ||
        data['version'] != 1 ||
        data['actor'] != actor.toLowerCase() ||
        data['drafts'] is! List ||
        (data['drafts'] as List).length > _maxRecords) {
      throw const EmergencyVaultException('corrupt_or_wrong_key');
    }
    final seen = <String>{};
    for (final raw in data['drafts'] as List) {
      if (raw is! Map ||
          raw['request'] is! Map ||
          raw['branch_id'] is! String ||
          !_uuid.hasMatch(raw['branch_id']) ||
          raw['created_at'] is! String ||
          DateTime.tryParse(raw['created_at']) == null ||
          raw['dispatch_started'] is! bool ||
          ![
            'pending',
            'uncertain',
            'conflict',
            'confirmed',
            'cancelled',
          ].contains(raw['state'])) {
        throw const EmergencyVaultException('corrupt_or_wrong_key');
      }
      final request = Map<String, dynamic>.from(raw['request'] as Map);
      _validateRequest(request);
      if (!seen.add(request['p_request'] as String)) {
        throw const EmergencyVaultException('corrupt_or_wrong_key');
      }
      if (raw['state'] == 'cancelled' && raw['dispatch_started'] == true) {
        throw const EmergencyVaultException('corrupt_or_wrong_key');
      }
    }
  }

  Future<void> _persist(Map<String, dynamic> data, String salt) async {
    check();
    _validate(data);
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    if (clear.length > _maxBytes) {
      throw const EmergencyVaultException('capacity');
    }
    final secret = await _secret(salt);
    check();
    late SecretBox box;
    try {
      box = await AesGcm.with256bits().encrypt(
        clear,
        secretKey: secret,
        aad: _aad(salt),
      );
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
    check();
    final encoded = jsonEncode({
      'version': 1,
      'algorithm': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': emergencyVaultIterations,
      'salt': salt,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
    await store.write(storageKey, encoded);
    check();
    if (await store.read(storageKey) != encoded) {
      throw const EmergencyVaultException('save_failed');
    }
    check();
  }

  @override
  Future<List<Map<String, dynamic>>> list() => _locked(() async {
    final data = await _read();
    return (data['drafts'] as List)
        .map((e) => _copy(Map<String, dynamic>.from(e as Map)))
        .toList();
  });
  @override
  Future<Map<String, dynamic>> enqueue({
    required Map<String, dynamic> request,
    required String branch,
    DateTime? deviceTime,
    String? reference,
  }) => _locked(() async {
    _validateRequest(request);
    if (reference != null && (reference.isEmpty || reference.length > 60)) {
      throw const EmergencyVaultException('invalid_draft');
    }
    if (!_uuid.hasMatch(branch)) {
      throw const EmergencyVaultException('invalid_draft');
    }
    final data = await _read();
    final rows = data['drafts'] as List;
    for (final row in rows) {
      if (row['request']['p_request'] == request['p_request']) {
        if (!mapEquals(
              Map<String, dynamic>.from(row['request'] as Map),
              request,
            ) ||
            row['branch_id'] != branch) {
          throw const EmergencyVaultException('nonce_mismatch');
        }
        return _copy(Map<String, dynamic>.from(row));
      }
    }
    if (rows.length >= _maxRecords ||
        rows
                .where((r) => !['confirmed', 'cancelled'].contains(r['state']))
                .length >=
            _maxPending) {
      throw const EmergencyVaultException('capacity');
    }
    final row = <String, dynamic>{
      'request': _copy(request),
      'branch_id': branch,
      'reference': reference,
      'created_at': (deviceTime ?? DateTime.now()).toUtc().toIso8601String(),
      'dispatch_started': false,
      'state': 'pending',
      'error': null,
      'receipt': null,
    };
    rows.add(row);
    await _persist(data, _salt!);
    return _copy(row);
  });
  Future<Map<String, dynamic>> _change(
    String id,
    void Function(Map<String, dynamic>) update,
  ) => _locked(() async {
    final data = await _read();
    final row = (data['drafts'] as List)
        .cast<Map>()
        .where((r) => r['request']['p_request'] == id)
        .singleOrNull;
    if (row == null) throw const EmergencyVaultException('missing_draft');
    final target = Map<String, dynamic>.from(row);
    update(target);
    final rows = data['drafts'] as List;
    rows[rows.indexOf(row)] = target;
    await _persist(data, _salt!);
    return _copy(target);
  });
  @override
  Future<Map<String, dynamic>> beginDispatch(String id) => _change(id, (row) {
    if (['confirmed', 'cancelled'].contains(row['state'])) {
      throw const EmergencyVaultException('closed_draft');
    }
    row['dispatch_started'] = true;
    row['state'] = 'uncertain';
    row['error'] = null;
  });
  @override
  Future<Map<String, dynamic>> failure(String id, {required bool definitive}) =>
      _change(id, (row) {
        if (['confirmed', 'cancelled'].contains(row['state'])) {
          throw const EmergencyVaultException('closed_draft');
        }
        row['state'] = definitive ? 'conflict' : 'uncertain';
        row['error'] = definitive ? 'review_required' : 'unconfirmed';
      });
  @override
  Future<Map<String, dynamic>> cancelUnsent(String id) => _change(id, (row) {
    if (row['dispatch_started'] == true || row['state'] == 'confirmed') {
      throw const EmergencyVaultException('resolution_required');
    }
    row['state'] = 'cancelled';
  });
  @override
  Future<Map<String, dynamic>> confirm(
    String id,
    Map<String, dynamic> receipt,
  ) => _change(id, (row) {
    final request = row['request'] as Map;
    if (row['dispatch_started'] != true ||
        receipt['booking_id'] != request['p_booking'] ||
        receipt['branch_id'] != row['branch_id'] ||
        receipt['priority'] != request['p_priority'] ||
        receipt['revision'] != (request['p_expected_revision'] as int) + 1 ||
        receipt['arrived_at'] is! String ||
        DateTime.tryParse(receipt['arrived_at']) == null) {
      throw const EmergencyVaultException('receipt_mismatch');
    }
    row['state'] = 'confirmed';
    row['error'] = null;
    row['receipt'] = {
      for (final field in [
        'booking_id',
        'branch_id',
        'priority',
        'revision',
        'arrived_at',
      ])
        field: receipt[field],
    };
  });
}
