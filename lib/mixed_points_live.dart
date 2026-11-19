import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

bool isMixedPointsHint(Map<String, dynamic> envelope) {
  final inner = envelope['payload'];
  final body = inner is Map ? inner : envelope;
  final id = body['id'];
  return body['kind'] == 'mixed_points_changed' &&
      body.keys.every((key) => key == 'kind' || key == 'id') &&
      (id == null ||
          id is String &&
              RegExp(
                r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
              ).hasMatch(id));
}

abstract class MixedPointsHintTransport {
  Future<void> connect({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  });
  Future<void> reauthenticate();
  Future<void> close();
}

/// Share one personal channel across multiple views of the same account.
class SupabaseMixedPointsHints implements MixedPointsHintTransport {
  SupabaseMixedPointsHints(this.client) : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  final Object listener = Object();
  _PointsChannel? _hub;
  static final Expando<_PointsChannel> _hubs = Expando<_PointsChannel>();
  @override
  Future<void> connect({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  }) async {
    if (actor == null ||
        client.auth.currentUser?.id != actor ||
        client.auth.currentSession == null) {
      return;
    }
    var shared = _hubs[client];
    if (shared == null || shared.actor != actor) {
      shared = _PointsChannel(client, actor!);
      _hubs[client] = shared;
    }
    _hub = shared;
    await shared.add(listener, onHint, onReconnect);
  }

  @override
  Future<void> reauthenticate() async {
    await _hub?.reauthenticate();
  }

  @override
  Future<void> close() async {
    final old = _hub;
    _hub = null;
    await old?.remove(listener);
  }
}

class _PointsChannel {
  _PointsChannel(this.client, this.actor);
  final SupabaseClient client;
  final String actor;
  final listeners = <Object, ({VoidCallback hint, VoidCallback reconnect})>{};
  RealtimeChannel? channel;
  Future<void>? starting;
  Future<void> leaving = Future<void>.value();
  bool joined = false;
  int epoch = 0;
  bool get current =>
      client.auth.currentUser?.id == actor &&
      client.auth.currentSession != null;
  Future<void> add(
    Object key,
    VoidCallback hint,
    VoidCallback reconnect,
  ) async {
    final added = !listeners.containsKey(key);
    listeners[key] = (hint: hint, reconnect: reconnect);
    if (channel != null) {
      if (added && joined && current) {
        scheduleMicrotask(() {
          if (listeners.containsKey(key) && current) reconnect();
        });
      }
      return;
    }
    while (channel == null && listeners.containsKey(key) && current) {
      final task = starting ??= start();
      try {
        await task;
      } finally {
        if (identical(starting, task)) starting = null;
      }
    }
  }

  Future<void> reauthenticate() async {
    final session = client.auth.currentSession;
    if (!current || session == null) return;
    await client.realtime.setAuth(session.accessToken);
  }

  Future<void> start() async {
    final generation = epoch;
    await leaving;
    if (!current || listeners.isEmpty || generation != epoch) return;
    await reauthenticate();
    if (!current || listeners.isEmpty || generation != epoch) return;
    final next = client.channel(
      'mixed-points:$actor',
      opts: const RealtimeChannelConfig(private: true),
    );
    channel = next;
    next
        .onBroadcast(
          event: 'mixed_points_changed',
          callback: (body) {
            if (current &&
                identical(channel, next) &&
                isMixedPointsHint(body)) {
              for (final callback in List.of(listeners.values)) {
                callback.hint();
              }
            }
          },
        )
        .subscribe((status, error) {
          if (!current || !identical(channel, next)) return;
          joined = status == RealtimeSubscribeStatus.subscribed;
          if (joined) {
            for (final callback in List.of(listeners.values)) {
              callback.reconnect();
            }
          }
        });
  }

  Future<void> remove(Object key) async {
    listeners.remove(key);
    if (listeners.isNotEmpty) return;
    epoch++;
    joined = false;
    final old = channel;
    channel = null;
    if (old != null) {
      leaving = client
          .removeChannel(old)
          .then<void>((_) {})
          .catchError((Object _) {});
      await leaving;
    }
  }
}
