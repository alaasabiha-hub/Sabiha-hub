import 'dart:async';

import 'package:flutter/widgets.dart';

/// Customers re-fetch the existing published-only API. They never subscribe to
/// staff-only catalogue revisions or receive private catalogue definitions.
class CatalogRefresh extends WidgetsBindingObserver {
  CatalogRefresh({
    required this.refresh,
    required this.allowed,
    this.interval = const Duration(seconds: 30),
  }) {
    WidgetsBinding.instance.addObserver(this);
    _start();
  }
  final Future<void> Function() refresh;
  final bool Function() allowed;
  final Duration interval;
  Timer? _timer;
  bool _disposed = false, _running = false;
  void _start() {
    _timer?.cancel();
    if (!_disposed) _timer = Timer.periodic(interval, (_) => request());
  }

  Future<void> request() async {
    if (_disposed || _running || !allowed()) return;
    _running = true;
    try {
      await refresh();
    } catch (_) {
      /* The reader owns its error state. */
    } finally {
      _running = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
      unawaited(request());
    } else {
      _timer?.cancel();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
