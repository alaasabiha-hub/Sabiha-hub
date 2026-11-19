import 'dart:math' as math;

import 'package:flutter/material.dart';

const _splashArt = 'assets/sabiha_cinematic_splash_reference.png';
const _splashNavy = Color(0xFF071A36);

/// Cold-start-only cinematic brand transition. Session/profile verification
/// runs concurrently, but a fast response never skips the 2.4s presentation.
/// Reduced-motion settings bypass the animation and hand off when ready.
class SabihaSplashScreen extends StatefulWidget {
  final Future<Widget> destination;
  final VoidCallback? onReady;

  const SabihaSplashScreen({
    super.key,
    required this.destination,
    this.onReady,
  });

  @override
  State<SabihaSplashScreen> createState() => _SabihaSplashScreenState();
}

class _SabihaSplashScreenState extends State<SabihaSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  Widget? _destination;
  bool _entered = false;
  bool _reduceMotion = false;
  Object? _startupError;

  @override
  void initState() {
    super.initState();
    _animation.addStatusListener(_handleAnimationStatus);
    _animation.forward();
    widget.destination.then(
      (destination) {
        if (!mounted) return;
        _destination = destination;
        _enterWhenReady();
      },
      onError: (Object error, StackTrace _) {
        if (!mounted) return;
        setState(() => _startupError = error);
      },
    );
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _enterWhenReady();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced != _reduceMotion) {
      _reduceMotion = reduced;
      if (reduced) _animation.value = 1;
      _enterWhenReady();
    }
  }

  void _enterWhenReady() {
    if (_entered ||
        _destination == null ||
        (!_reduceMotion && !_animation.isCompleted) ||
        !mounted) {
      return;
    }
    setState(() => _entered = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady?.call();
    });
  }

  Widget _sparkle(Rect imageRect, double x, double y, int phase) {
    final size = (imageRect.width * .034).clamp(13.0, 23.0);
    final angle = _animation.value * math.pi * 4 + phase * math.pi / 2;
    final pulse = (math.sin(angle) + 1) / 2;
    final drift = math.sin(angle) * size * .15;
    return Positioned(
      key: ValueKey('cinematic-sparkle-$phase'),
      left: imageRect.left + imageRect.width * x - size / 2 + drift,
      top: imageRect.top + imageRect.height * y - size / 2 - drift,
      child: IgnorePointer(
        child: Opacity(
          opacity: _reduceMotion ? 0 : .28 + pulse * .68,
          child: Transform.rotate(
            angle: phase.isEven ? 0 : math.pi / 4,
            child: Icon(
              Icons.auto_awesome,
              size: size,
              color: phase.isEven
                  ? const Color(0xFFE8F5FF)
                  : const Color(0xFF58B8FF),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headlightGlow(Rect imageRect, double x, double y, int phase) {
    final pulse = (math.sin(_animation.value * math.pi * 3 + phase) + 1) / 2;
    final diameter = imageRect.width * .12;
    return Positioned(
      left: imageRect.left + imageRect.width * x - diameter / 2,
      top: imageRect.top + imageRect.height * y - diameter / 2,
      child: IgnorePointer(
        child: Opacity(
          opacity: _reduceMotion ? .14 : .08 + pulse * .22,
          child: SizedBox.square(
            dimension: diameter,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0xFFF0FAFF),
                    Color(0x6652B8FF),
                    Colors.transparent,
                  ],
                  stops: [0, .28, 1],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _loaderAt(Rect imageRect) {
    // The reference contains a still loading glyph. Hide only that small
    // background patch and replace it with a live Flutter indicator.
    final center = Offset(
      imageRect.left + imageRect.width * .5,
      imageRect.top + imageRect.height * .676,
    );
    final diameter = imageRect.width * .071;
    final patch = diameter * 1.9;
    return Positioned(
      left: center.dx - patch / 2,
      top: center.dy - patch / 2,
      child: SizedBox.square(
        dimension: patch,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color(0xFF071A36),
                      Color(0xF2071A36),
                      Color(0x00071A36),
                    ],
                    stops: [0, .56, 1],
                  ),
                ),
              ),
            ),
            if (_destination == null)
              SizedBox.square(
                dimension: diameter,
                child: const CircularProgressIndicator(
                  strokeWidth: 2.6,
                  color: Color(0xFFC5CBD5),
                  backgroundColor: Color(0x553B9BFF),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _splashBody(BuildContext context) {
    return Stack(
      key: const ValueKey('sabiha-animated-splash'),
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: _splashNavy),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0A2450), Color(0xFF071A36), _splashNavy],
              ),
            ),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -.28),
                radius: .8,
                colors: [Color(0x333B86FF), Colors.transparent],
              ),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            const source = Size(864, 1536);
            final fitted = applyBoxFit(BoxFit.contain, source, viewport);
            final imageRect = Alignment.center.inscribe(
              fitted.destination,
              Offset.zero & viewport,
            );
            return AnimatedBuilder(
              animation: _animation,
              builder: (context, _) {
                final progress = _animation.value;
                final fade = _reduceMotion
                    ? 1.0
                    : Curves.easeOutCubic.transform(
                        (progress / .42).clamp(0.0, 1.0),
                      );
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fromRect(
                      rect: imageRect,
                      child: Opacity(
                        opacity: fade,
                        child: Transform.scale(
                          alignment: Alignment.center,
                          scale: .985 + .015 * fade,
                          child: Image.asset(
                            _splashArt,
                            key: const ValueKey('splash-cinematic-artwork'),
                            fit: BoxFit.contain,
                            semanticLabel: 'Sabiha Hub cinematic splash',
                          ),
                        ),
                      ),
                    ),
                    if (!_reduceMotion && progress > .08 && progress < .94)
                      CustomPaint(
                        key: const ValueKey('splash-metal-light-sweep'),
                        size: viewport,
                        painter: _MetalSweepPainter(
                          imageRect: imageRect,
                          progress: progress,
                        ),
                      ),
                    if (!_reduceMotion) ...[
                      _sparkle(imageRect, .287, .282, 0),
                      _sparkle(imageRect, .602, .235, 1),
                      _sparkle(imageRect, .704, .393, 2),
                      _sparkle(imageRect, .493, .472, 3),
                    ],
                    _headlightGlow(imageRect, .648, .754, 0),
                    _headlightGlow(imageRect, .86, .745, 1),
                    if (_destination == null) _loaderAt(imageRect),
                    if (_startupError != null)
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 8,
                        child: Text(
                          Localizations.localeOf(context).languageCode == 'ar'
                              ? 'تعذر إكمال التهيئة. أعد فتح التطبيق أو تحقق من الاتصال.'
                              : 'Startup could not finish. Reopen the app or check the connection.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFC5CBD5),
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _splashNavy,
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: _entered
          ? KeyedSubtree(
              key: const ValueKey('startup-ready'),
              child: _destination!,
            )
          : _splashBody(context),
    ),
  );

  @override
  void dispose() {
    _animation.removeStatusListener(_handleAnimationStatus);
    _animation.dispose();
    super.dispose();
  }
}

class _MetalSweepPainter extends CustomPainter {
  final Rect imageRect;
  final double progress;

  const _MetalSweepPainter({required this.imageRect, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final logo = Rect.fromLTRB(
      imageRect.left + imageRect.width * .19,
      imageRect.top + imageRect.height * .19,
      imageRect.left + imageRect.width * .81,
      imageRect.top + imageRect.height * .49,
    );
    final t = Curves.easeInOutCubic.transform(
      ((progress - .08) / .78).clamp(0.0, 1.0),
    );
    final bandWidth = logo.width * .075;
    final sweepX = logo.left - bandWidth + t * (logo.width + bandWidth);
    final skew = logo.height * .12;
    final path = Path()
      ..moveTo(sweepX, logo.top)
      ..lineTo(sweepX + bandWidth, logo.top)
      ..lineTo(sweepX + bandWidth + skew, logo.bottom)
      ..lineTo(sweepX + skew, logo.bottom)
      ..close();
    final band = Rect.fromLTWH(sweepX, logo.top, bandWidth + skew, logo.height);
    final paint = Paint()
      ..isAntiAlias = true
      ..blendMode = BlendMode.screen
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0x003E9EFF),
          Color(0x42EFF9FF),
          Color(0x384AB7FF),
          Color(0x00EFF9FF),
        ],
        stops: [0, .38, .57, 1],
      ).createShader(band);
    canvas.save();
    canvas.clipRect(logo);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MetalSweepPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.imageRect != imageRect;
}
