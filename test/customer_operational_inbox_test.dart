import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_inbox.dart';

class OperationalInboxFake implements CustomerOperationalInboxGateway {
  @override
  String? actorId = 'qa-customer';
  int reads = 0, marks = 0;
  String? marked;
  Completer<Map<String, dynamic>>? pending;
  Map<String, dynamic> response = {
    'unread_count': 1,
    'items': [
      {
        'notification_id': 'op-1',
        'event_type': 'vehicle_ready',
        'source_kind': 'order',
        'source_id': 'order-1',
        'payload': {'status': 'completed'},
        'created_at': '2026-11-18T10:00:00Z',
        'read': false,
        'deep_link': '/orders',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> list() async {
    reads++;
    return pending?.future ?? response;
  }

  @override
  Future<Map<String, dynamic>> markRead(String notificationId) async {
    marks++;
    marked = notificationId;
    return {
      'notification_id': notificationId,
      'read': true,
      'changed': true,
      'read_at': '2026-11-18T10:01:00Z',
    };
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final size in [const Size(390, 844), const Size(1440, 900)]) {
      testWidgets('operational inbox $language at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = OperationalInboxFake();
        String? opened;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: ListView(
                children: [
                  CustomerOperationalInboxSection(
                    gateway: gateway,
                    onOpen: (link) async => opened = link,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'ar' ? 'سيارتك جاهزة' : 'Your vehicle is ready',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'ar' ? 'غير المقروءة: 1' : 'Unread: 1'),
          findsOneWidget,
        );
        await tester.tap(find.byType(ListTile));
        await tester.pumpAndSettle();
        expect(gateway.marked, 'op-1');
        expect(gateway.marks, 1);
        expect(opened, '/orders');
        expect(
          find.text(language == 'ar' ? 'غير المقروءة: 0' : 'Unread: 0'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('operational inbox clears pending response on account change', (
    tester,
  ) async {
    final gateway = OperationalInboxFake()..pending = Completer();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: ListView(
            children: [CustomerOperationalInboxSection(gateway: gateway)],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(gateway.reads, 1);
    gateway.actorId = 'another-customer';
    gateway.pending!.complete(gateway.response);
    await tester.pumpAndSettle();
    expect(find.text('Your vehicle is ready'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('operational inbox refuses unexpected destinations', (
    tester,
  ) async {
    final gateway = OperationalInboxFake()
      ..response = {
        'unread_count': 0,
        'items': [
          {
            'notification_id': 'op-admin',
            'event_type': 'booking_confirmed',
            'created_at': '2026-11-18T10:00:00Z',
            'read': false,
            'deep_link': '/admin',
          },
        ],
      };
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: ListView(
            children: [
              CustomerOperationalInboxSection(
                gateway: gateway,
                onOpen: (_) async => opened = true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(gateway.marks, 0);
  });
}
