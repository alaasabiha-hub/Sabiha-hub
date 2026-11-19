import 'package:flutter/material.dart';

/// Web reload uses the same verified destination as native, without a delay.
class SabihaWebStartup extends StatefulWidget {
  const SabihaWebStartup({
    super.key,
    required this.destination,
    required this.fallbackHome,
    this.onReady,
  });
  final Future<Widget> destination;
  final Widget fallbackHome;
  final VoidCallback? onReady;
  @override
  State<SabihaWebStartup> createState() => _SabihaWebStartupState();
}

class _SabihaWebStartupState extends State<SabihaWebStartup> {
  bool notified = false;
  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    future: widget.destination,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(
          key: ValueKey('web-startup-pending'),
          backgroundColor: Color(0xff071a36),
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        );
      }
      if (!notified) {
        notified = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onReady?.call();
        });
      }
      return snapshot.hasError
          ? widget.fallbackHome
          : snapshot.data ?? widget.fallbackHome;
    },
  );
}
