import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'invoices.dart' show matchesInitialAuthReplay;

bool isAppInboxChangedHint(Map<String, dynamic> envelope) {
  // The pinned SDK delivers the broadcast envelope; binary/managed transports
  // may deliver the inner map. Neither form carries authoritative inbox facts.
  final inner = envelope['payload'];
  final body = inner is Map ? inner : envelope;
  return body['kind'] == 'inbox_changed';
}

/// Broadcast is only a wake-up hint. The current authorized RPC is authoritative.
abstract class AppInboxLiveTransport {
  Future<int> readUnread();
  Future<void> subscribe({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  });
  Future<void> unsubscribe();
  Future<void> reauthenticate();
}

class SupabaseAppInboxLiveTransport implements AppInboxLiveTransport {
  SupabaseAppInboxLiveTransport(this.client)
    : actor = client.auth.currentUser?.id;
  final SupabaseClient client;
  final String? actor;
  RealtimeChannel? channel;
  Future<void> leaving = Future<void>.value();
  int subscriptionEpoch = 0;
  bool get current => actor != null && client.auth.currentUser?.id == actor;
  @override
  Future<int> readUnread() async {
    if (!current) throw StateError('Session changed');
    final value = await client.rpc(
      'list_my_app_inbox',
      params: {
        'p_before_created_at': null,
        'p_before_event': null,
        'p_limit': 25,
      },
    );
    if (!current) throw StateError('Session changed');
    final count = (value as Map)['unread_count'];
    if (count is! num ||
        !count.isFinite ||
        count < 0 ||
        count != count.toInt()) {
      throw StateError('Invalid count');
    }
    return count.toInt(); // No event body is retained.
  }

  @override
  Future<void> reauthenticate() async {
    final session = client.auth.currentSession;
    if (!current || session == null || session.user.id != actor) {
      throw StateError('Session changed');
    }
    await client.realtime.setAuth(session.accessToken);
  }

  @override
  Future<void> subscribe({
    required VoidCallback onHint,
    required VoidCallback onReconnect,
  }) async {
    if (!current) throw StateError('Session changed');
    final generation = subscriptionEpoch;
    await leaving;
    if (generation != subscriptionEpoch || !current) return;
    if (channel != null) return;
    await reauthenticate();
    if (generation != subscriptionEpoch || !current) return;
    final next = client.channel(
      'app-inbox:$actor',
      opts: const RealtimeChannelConfig(private: true),
    );
    channel = next;
    next
        .onBroadcast(
          event: 'inbox_changed',
          callback: (payload) {
            if (current &&
                identical(channel, next) &&
                isAppInboxChangedHint(payload)) {
              onHint();
            }
          },
        )
        .subscribe((status, error) {
          if (current &&
              identical(channel, next) &&
              status == RealtimeSubscribeStatus.subscribed) {
            onReconnect();
          }
        });
  }

  @override
  Future<void> unsubscribe() async {
    subscriptionEpoch++;
    final old = channel;
    channel = null;
    if (old != null) {
      leaving = client
          .removeChannel(old)
          .then<void>((_) {})
          .catchError((Object _) {});
    }
    await leaving;
  }
}

class AppInboxLiveController extends ChangeNotifier {
  AppInboxLiveController({
    required this.transport,
    this.debounce = const Duration(milliseconds: 150),
    this.fallback = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 15),
  });
  final AppInboxLiveTransport transport;
  final Duration debounce, fallback, readTimeout;
  int unread = 0;
  bool known = false, failed = false, busy = false, invalid = false;
  bool _visible = false, _foreground = true, _dirty = true, _disposed = false;
  int _epoch = 0, _activity = 0;
  Timer? _debounce, _poll;
  bool get active => !_disposed && !invalid && _visible && _foreground;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void visibility({required bool visible, required bool foreground}) {
    final was = active;
    _visible = visible;
    _foreground = foreground;
    if (active == was) return;
    _activity++;
    _dirty = true;
    if (!active) {
      _poll?.cancel();
      _poll = null;
      _debounce?.cancel();
      _debounce = null;
      unawaited(transport.unsubscribe());
      return;
    }
    _poll = Timer.periodic(fallback, (_) => hint());
    final epoch = _epoch;
    unawaited(
      transport.subscribe(onHint: hint, onReconnect: hint).catchError((
        Object _,
      ) {
        if (!_disposed && !invalid && epoch == _epoch) hint();
      }),
    );
    hint(immediate: true);
  }

  void hint({bool immediate = false}) {
    if (_disposed || invalid) return;
    _dirty = true;
    if (!active || busy) return;
    if (immediate) {
      _debounce?.cancel();
      _debounce = null;
      unawaited(_refresh());
    } else {
      _debounce ??= Timer(debounce, () {
        _debounce = null;
        unawaited(_refresh());
      });
    }
  }

  Future<void> _refresh() async {
    if (!active || busy || !_dirty) return;
    final epoch = _epoch, activity = _activity;
    _dirty = false;
    busy = true;
    known = false;
    unread = 0;
    failed = false;
    changed();
    try {
      final value = await transport.readUnread().timeout(readTimeout);
      if (_disposed || invalid || epoch != _epoch) return;
      if (!active || activity != _activity) {
        _dirty = true;
        return;
      }
      if (value < 0) throw StateError('Invalid count');
      unread = value;
      known = true;
    } catch (_) {
      if (!_disposed &&
          !invalid &&
          epoch == _epoch &&
          active &&
          activity == _activity) {
        unread = 0;
        known = false;
        failed = true;
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        changed();
        if (_dirty && active) hint();
      }
    }
  }

  Future<void> reauthenticate() async {
    invalidate();
    final generation = _epoch;
    try {
      await transport.unsubscribe();
      if (_disposed || generation != _epoch) return;
      await transport.reauthenticate();
      if (_disposed || generation != _epoch) return;
      final visible = _visible, foreground = _foreground;
      invalid = false;
      _visible = false;
      failed = false;
      _dirty = true;
      visibility(visible: visible, foreground: foreground);
      changed();
    } catch (_) {
      if (!_disposed && generation == _epoch) {
        failed = true;
        changed();
      }
    }
  }

  void invalidate() {
    if (_disposed) return;
    _epoch++;
    _activity++;
    invalid = true;
    unread = 0;
    known = false;
    failed = false;
    busy = false;
    _dirty = false;
    _poll?.cancel();
    _debounce?.cancel();
    unawaited(transport.unsubscribe());
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _poll?.cancel();
    _debounce?.cancel();
    unawaited(transport.unsubscribe());
    super.dispose();
  }
}

class AppInboxButton extends StatefulWidget {
  const AppInboxButton({
    super.key,
    required this.client,
    required this.onOpen,
    this.color,
    this.transport,
    this.controller,
  });
  final SupabaseClient client;
  final Future<void> Function() onOpen;
  final Color? color;
  final AppInboxLiveTransport? transport;
  final AppInboxLiveController? controller;
  @override
  State<AppInboxButton> createState() => _AppInboxButtonState();
}

class _AppInboxButtonState extends State<AppInboxButton>
    with WidgetsBindingObserver {
  late final AppInboxLiveController flow;
  StreamSubscription<AuthState>? auth;
  bool opening = false;
  bool identityLost = false;
  bool foreground = true;
  String t(String ar, String en) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;
  @override
  void initState() {
    super.initState();
    flow =
        widget.controller ??
        AppInboxLiveController(
          transport:
              widget.transport ?? SupabaseAppInboxLiveTransport(widget.client),
        );
    WidgetsBinding.instance.addObserver(this);
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final boundActor = widget.client.auth.currentUser?.id;
    final initial = widget.client.auth.currentSession;
    var first = true;
    auth = widget.client.auth.onAuthStateChange.listen((event) {
      final same = first && matchesInitialAuthReplay(event, initial);
      first = false;
      if (same) return;
      if (event.event != AuthChangeEvent.initialSession) {
        final session = widget.client.auth.currentSession;
        if (!identityLost &&
            boundActor != null &&
            session != null &&
            session.user.id == boundActor &&
            widget.client.auth.currentUser?.id == boundActor &&
            event.session?.user.id == boundActor &&
            event.session?.accessToken == session.accessToken) {
          unawaited(flow.reauthenticate());
        } else {
          identityLost = true;
          flow.invalidate();
        }
      }
    });
    if (widget.client.auth.currentUser == null) {
      identityLost = true;
      flow.invalidate();
    }
  }

  void syncVisibility() {
    flow.visibility(
      visible: !opening && (ModalRoute.isCurrentOf(context) ?? true),
      foreground: foreground,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    syncVisibility();
  }

  @override
  void didUpdateWidget(covariant AppInboxButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      identityLost = true;
      flow.invalidate();
    }
  }

  @override
  void dispose() {
    auth?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    flow.dispose();
    super.dispose();
  }

  Future<void> open() async {
    if (opening || flow.invalid) return;
    setState(() => opening = true);
    syncVisibility();
    try {
      await widget.onOpen();
    } finally {
      if (mounted) {
        setState(() => opening = false);
        syncVisibility();
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: flow,
    builder: (context, _) {
      final label = flow.invalid
          ? t(
              'أعد فتح التنبيهات بالحساب الحالي',
              'Reopen inbox with the current account',
            )
          : flow.failed
          ? t('التنبيهات · تعذر التحقق', 'Inbox · check unavailable')
          : flow.known
          ? t(
              'التنبيهات · ${flow.unread} غير مقروءة',
              'Inbox · ${flow.unread} unread',
            )
          : t('التنبيهات · جارٍ التحقق', 'Inbox · checking');
      return Semantics(
        liveRegion: true,
        label: label,
        button: true,
        excludeSemantics: true,
        child: IconButton(
          key: const ValueKey('app_inbox_live_button'),
          tooltip: label,
          color: widget.color ?? const Color(0xff174b83),
          onPressed: flow.invalid || opening ? null : open,
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.notifications_none),
              if (flow.known && flow.unread > 0)
                Positioned(
                  right: -9,
                  top: -9,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xff071a36),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      flow.unread > 99 ? '99+' : '${flow.unread}',
                      key: const ValueKey('app_inbox_unread'),
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              if (flow.failed)
                const Positioned(
                  right: -3,
                  top: -3,
                  child: Icon(Icons.info_outline, size: 12),
                ),
            ],
          ),
        ),
      );
    },
  );
}
