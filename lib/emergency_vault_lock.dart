import 'dart:async';

final _tails = <String, Future<void>>{};

/// Single UI-isolate writers. Background isolates must not write this journal.
Future<T> withEmergencyVaultLock<T>(
  String name,
  Future<T> Function() action,
) async {
  final previous = _tails[name] ?? Future<void>.value();
  final done = Completer<void>();
  final future = done.future;
  _tails[name] = future;
  await previous;
  try {
    return await action();
  } finally {
    done.complete();
    if (identical(_tails[name], future)) _tails.remove(name);
  }
}
