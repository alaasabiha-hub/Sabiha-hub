import 'package:flutter/widgets.dart';

/// Performs a single route replacement without retaining a BuildContext from
/// the route that is about to be removed.
class SafeRouteReplacement {
  bool _started = false;

  bool replaceOnce(NavigatorState navigator, Route<void> route) {
    if (_started || !navigator.mounted) return false;
    _started = true;
    navigator.pushReplacement<void, void>(route);
    return true;
  }
}
