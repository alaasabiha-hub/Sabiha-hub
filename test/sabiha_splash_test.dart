import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/sabiha_splash.dart';

void main() {
  testWidgets('Shows the cinematic full-screen artwork while session loads', (
    t,
  ) async {
    final destination = Completer<Widget>();
    await t.pumpWidget(
      MaterialApp(home: SabihaSplashScreen(destination: destination.future)),
    );
    await t.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('sabiha-animated-splash')),
      findsOneWidget,
    );
    final artwork = t.widget<Image>(
      find.byKey(const ValueKey('splash-cinematic-artwork')),
    );
    expect(
      (artwork.image as AssetImage).assetName,
      'assets/sabiha_cinematic_splash_reference.png',
    );
    expect(artwork.fit, BoxFit.contain);
    expect(
      find.byKey(const ValueKey('splash-metal-light-sweep')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cinematic-sparkle-0')), findsOneWidget);

    await t.pump(const Duration(milliseconds: 2400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    destination.complete(const Scaffold(body: Text('Verified home')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Verified home'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('Cold start shows the animation even when verification is fast', (
    t,
  ) async {
    var entered = 0;
    await t.pumpWidget(
      MaterialApp(
        home: SabihaSplashScreen(
          destination: Future.value(const Scaffold(body: Text('Ready'))),
          onReady: () => entered++,
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('sabiha-animated-splash')),
      findsOneWidget,
    );
    await t.pump(const Duration(milliseconds: 350));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Ready'), findsOneWidget);
    expect(entered, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('Reduced motion shows a still splash and hands off promptly', (
    t,
  ) async {
    final destination = Completer<Widget>();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: SabihaSplashScreen(destination: destination.future),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('sabiha-animated-splash')),
      findsOneWidget,
    );
    destination.complete(const Scaffold(body: Text('Reduced motion ready')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Reduced motion ready'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 768.0, 1440.0]) {
    testWidgets('Splash remains visible and safe at width $width', (t) async {
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final destination = Completer<Widget>();
      await t.pumpWidget(
        MaterialApp(home: SabihaSplashScreen(destination: destination.future)),
      );
      await t.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('splash-cinematic-artwork')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      destination.complete(const Scaffold(body: Text('Home')));
      await t.pump();
      expect(
        find.byKey(const ValueKey('sabiha-animated-splash')),
        findsOneWidget,
      );
      await t.pump(const Duration(milliseconds: 2300));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Home'), findsOneWidget);
    });
  }
}
