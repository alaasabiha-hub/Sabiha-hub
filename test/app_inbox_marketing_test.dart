import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_inbox.dart';

class MarketingInboxFake implements CustomerMarketingInboxGateway {
  @override
  String? actorId = 'qa-customer';
  int reads = 0, marks = 0;
  Completer<Map<String, dynamic>>? pending;
  String? lastMarked;
  Map<String, dynamic> result = {
    'unread_count': 1,
    'items': [
      {
        'recipient_id': 'recipient-1',
        'title_ar': 'عرض خاص',
        'body_ar': 'خصم للعملاء الموافقين',
        'title_en': 'Special offer',
        'body_en': 'An offer for opted-in customers',
        'deep_link': '/offers',
        'created_at': '2026-11-18T10:00:00Z',
        'read': false,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> list() async {
    reads++;
    if (pending != null) return pending!.future;
    return result;
  }

  @override
  Future<Map<String, dynamic>> markRead(String recipientId) async {
    marks++;
    lastMarked = recipientId;
    return {'recipient_id': recipientId, 'read': true, 'changed': true};
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final size in [const Size(390, 844), const Size(1440, 900)]) {
      testWidgets(
        'campaign inbox is localized and bounded at $language $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final gateway = MarketingInboxFake();
          String? opened;
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Scaffold(
                body: ListView(
                  children: [
                    CustomerMarketingInboxSection(
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
            find.text(language == 'ar' ? 'عرض خاص' : 'Special offer'),
            findsOneWidget,
          );
          expect(
            find.text(language == 'ar' ? 'غير المقروءة: 1' : 'Unread: 1'),
            findsOneWidget,
          );
          await tester.tap(find.text(language == 'ar' ? 'فتح' : 'Open'));
          await tester.pumpAndSettle();
          expect(gateway.lastMarked, 'recipient-1');
          expect(gateway.marks, 1);
          expect(opened, '/offers');
          expect(
            find.text(language == 'ar' ? 'غير المقروءة: 0' : 'Unread: 0'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'marketing inbox clears data when the customer identity changes',
    (tester) async {
      final gateway = MarketingInboxFake();
      gateway.pending = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: ListView(
              children: [CustomerMarketingInboxSection(gateway: gateway)],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(gateway.reads, 1);
      gateway.actorId = 'different-customer';
      gateway.pending!.complete(gateway.result);
      await tester.pumpAndSettle();
      expect(find.text('Special offer'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
