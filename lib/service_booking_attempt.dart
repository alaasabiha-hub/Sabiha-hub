import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'workflow.dart' show newOrderRequestId;

typedef BookingRpc = Future<dynamic> Function(String, Map<String, dynamic>);
Map<String, dynamic> _copy(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

/// Only the request UUID is persisted. Neither absence nor a network error closes it.
class ServiceBookingAttempt extends ChangeNotifier {
  ServiceBookingAttempt({
    required this.rpc,
    required this.readId,
    required this.writeId,
    required this.clearId,
  });
  factory ServiceBookingAttempt.forClient(SupabaseClient client) {
    final owner = client.auth.currentUser?.id;
    if (owner == null) {
      return ServiceBookingAttempt(
        rpc: (_, _) async => throw const PostgrestException(
          message: 'Sign in required',
          code: '42501',
        ),
        readId: () async => throw StateError('Sign in required'),
        writeId: (_) async => throw StateError('Sign in required'),
        clearId: () async {},
      );
    }
    final key = 'service_booking_attempt_uuid_$owner';
    return ServiceBookingAttempt(
      rpc: (name, args) => client.rpc(name, params: args),
      readId: () async =>
          (await SharedPreferences.getInstance()).getString(key),
      writeId: (id) async {
        if (!await (await SharedPreferences.getInstance()).setString(key, id)) {
          throw StateError('UUID persistence failed');
        }
      },
      clearId: () async {
        if (!await (await SharedPreferences.getInstance()).remove(key)) {
          throw StateError('UUID clear failed');
        }
      },
    );
  }
  final BookingRpc rpc;
  final Future<String?> Function() readId;
  final Future<void> Function(String) writeId;
  final Future<void> Function() clearId;
  String? requestId, mode, error;
  Map<String, dynamic> view = {'state': 'initializing'};
  Map<String, dynamic>? _proposed;
  String? _proposedMode;
  bool busy = false, initialized = false, _disposed = false;
  bool get locked =>
      !initialized ||
      busy ||
      requestId != null ||
      ['initializing', 'unknown'].contains(state);
  String get state => '${view['state']}';
  bool get succeeded => state == 'succeeded';
  bool get canRetry =>
      requestId != null &&
      !succeeded &&
      !['different_mode', 'manual_review_required'].contains(state) &&
      (view['payload'] is Map || _proposed != null);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _apply(Map<String, dynamic> next) async {
    view = _copy(next);
    final id = next['request_id'] as String?;
    if (id != null) requestId = id;
    mode = next['mode'] as String? ?? mode;
    if (state == 'closed') {
      await clearId();
      requestId = null;
      mode = null;
      _proposed = null;
      _proposedMode = null;
    } else if (requestId != null) {
      await writeId(requestId!);
    }
    initialized = true;
    _changed();
  }

  Future<void> _recover() async {
    requestId ??= await readId();
    var next = Map<String, dynamic>.from(
      await rpc('get_service_booking_attempt', {'p_request': requestId}) as Map,
    );
    if (next['state'] == 'absent' && requestId != null) {
      final own = Map<String, dynamic>.from(
        await rpc('get_service_booking_attempt', {'p_request': null}) as Map,
      );
      if (own['state'] != 'absent') next = own;
    }
    // With a saved UUID, absent is still locked until the server tombstones it.
    await _apply(next);
  }

  Future<void> _run(Future<void> Function() work) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      await work();
    } catch (_) {
      error = 'unconfirmed';
      if (requestId != null) {
        try {
          await _recover();
        } catch (_) {
          view = {'state': 'unknown'};
        }
      } else {
        view = {'state': 'unknown'};
      }
    } finally {
      initialized = true;
      busy = false;
      _changed();
    }
  }

  Future<void> initialize() => _run(_recover);
  Future<void> recover() => _run(_recover);
  Future<void> submit(String selectedMode, Map<String, dynamic> payload) async {
    if (locked) return;
    requestId = newOrderRequestId();
    mode = selectedMode;
    _proposedMode = selectedMode;
    _proposed = _copy(payload);
    await _run(() async {
      await writeId(requestId!); // Must precede preparation or placement.
      await _prepare();
      if (state == 'open') await _place();
    });
  }

  Future<void> _prepare() async {
    final next = Map<String, dynamic>.from(
      await rpc('prepare_service_booking_attempt', {
        'p_request': requestId,
        'p_mode': _proposedMode,
        'p_payload': _proposed,
      }) as Map,
    );
    await _apply(next);
  }

  Future<void> _place() async {
    if (state != 'open' || requestId == null || view['payload'] is! Map) return;
    final args = {'p_request': requestId, ..._copy(view['payload'] as Map)};
    await rpc(
      mode == 'reward'
          ? 'place_customer_reward_booking'
          : 'place_customer_service_booking',
      args,
    );
    await _recover(); // Canonical current receipt, not an inferred success.
  }

  Future<void> retry() => _run(() async {
    if (!canRetry) return;
    await _recover();
    if (state == 'absent' && _proposed != null) await _prepare();
    if (state == 'open') await _place();
  });
  Future<void> close() => _run(() async {
    if (requestId == null) return;
    await _apply(
      Map<String, dynamic>.from(
        await rpc('close_service_booking_attempt', {'p_request': requestId})
            as Map,
      ),
    );
  });
  Future<bool> acknowledge() async {
    var ok = false;
    await _run(() async {
      if (!succeeded || requestId == null) return;
      final response = await rpc('acknowledge_service_booking_attempt', {
        'p_request': requestId,
      }) as Map;
      if (response['state'] != 'acknowledged') {
        throw StateError('No acknowledgement');
      }
      await clearId();
      requestId = null;
      mode = null;
      _proposed = null;
      _proposedMode = null;
      view = {'state': 'acknowledged'};
      ok = true;
    });
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
