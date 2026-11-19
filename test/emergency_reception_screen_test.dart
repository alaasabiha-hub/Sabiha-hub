import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/emergency_reception.dart';
import 'package:sabiha_hub/emergency_reception_vault.dart';

const actor = '10000000-0000-4000-8000-000000000001',
    branch = '20000000-0000-4000-8000-000000000001',
    booking = '30000000-0000-4000-8000-000000000001',
    nonce = '40000000-0000-4000-8000-000000000001';
Map<String, dynamic> request() => {
  'p_request': nonce,
  'p_booking': booking,
  'p_action': 'arrive',
  'p_priority': 'normal',
  'p_expected_revision': 0,
  'p_reason': 'Isolated local arrival note',
};
Map<String, dynamic> candidate() => {
  'request': request(),
  'branch_id': branch,
  'reference': 'SH-BKG-000001',
  'device_time': '2026-11-15T09:00:00Z',
};

class Store implements EmergencyVaultStore {
  String? value;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

class Journal implements EmergencyReceptionJournal {
  final events = <String>[];
  final rows = <Map<String, dynamic>>[];
  bool locked = false;
  Map<String, dynamic> copy(Map<String, dynamic> v) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(v)) as Map);
  @override
  Future<List<Map<String, dynamic>>> list() async => rows.map(copy).toList();
  @override
  Future<Map<String, dynamic>> enqueue({
    required Map<String, dynamic> request,
    required String branch,
    DateTime? deviceTime,
    String? reference,
  }) async {
    final row = {
      'request': copy(request),
      'branch_id': branch,
      'reference': reference,
      'created_at': deviceTime!.toIso8601String(),
      'dispatch_started': false,
      'state': 'pending',
    };
    rows.add(row);
    events.add('saved_local');
    return copy(row);
  }

  @override
  Future<Map<String, dynamic>> beginDispatch(String id) async {
    rows.single['dispatch_started'] = true;
    rows.single['state'] = 'uncertain';
    events.add('durable_dispatch_fence');
    return copy(rows.single);
  }

  @override
  Future<Map<String, dynamic>> failure(
    String id, {
    required bool definitive,
  }) async {
    rows.single['state'] = definitive ? 'conflict' : 'uncertain';
    events.add('failure');
    return copy(rows.single);
  }

  @override
  Future<Map<String, dynamic>> cancelUnsent(String id) async {
    rows.single['state'] = 'cancelled';
    return copy(rows.single);
  }

  @override
  Future<Map<String, dynamic>> confirm(
    String id,
    Map<String, dynamic> receipt,
  ) async {
    rows.single['state'] = 'confirmed';
    events.add('confirmed');
    return copy(rows.single);
  }

  @override
  void lock() {
    locked = true;
  }
}

class Gateway implements EmergencyReceptionGateway {
  @override
  String? actor = '10000000-0000-4000-8000-000000000001';
  final changes = StreamController<void>.broadcast(sync: true);
  final Journal journal;
  Gateway(this.journal);
  final calls = <Map<String, dynamic>>[];
  bool offline = false, lose = false;
  Object? rejection;
  Completer<Map<String, dynamic>>? pending;
  @override
  Stream<void> get authChanges => changes.stream;
  @override
  Future<void> probe() async {
    if (offline) throw TimeoutException('Isolated offline');
  }

  @override
  Future<Map<String, dynamic>> submit(Map<String, dynamic> request) async {
    expect(journal.rows.single['dispatch_started'], isTrue);
    expect(journal.events, contains('durable_dispatch_fence'));
    calls.add(Map<String, dynamic>.from(request));
    if (pending != null) return pending!.future;
    if (rejection != null) throw rejection!;
    if (lose) {
      lose = false;
      throw TimeoutException('Isolated response lost');
    }
    return {
      'booking_id': booking,
      'branch_id': branch,
      'priority': 'normal',
      'revision': 1,
      'arrived_at': '2026-11-15T10:00:00Z',
    };
  }
}

Future<void> mount(
  WidgetTester tester,
  Gateway gateway,
  Journal journal, {
  String lang = 'en',
  double width = 390,
  Store? store,
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(gateway.changes.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: EmergencyReceptionScreen(
        gateway: gateway,
        store: store ?? Store(),
        journalFactory: (password, current) => journal,
        candidate: candidate(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> unlock(WidgetTester tester, String lang) async {
  await tester.enterText(
    find.byKey(const ValueKey('emergency-passphrase')),
    'isolated-local-passphrase',
  );
  await tester.enterText(
    find.byKey(const ValueKey('emergency-confirm-passphrase')),
    'isolated-local-passphrase',
  );
  final button = find.widgetWithText(
    FilledButton,
    lang == 'ar' ? 'فتح السجل المشفر' : 'Unlock encrypted journal',
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> sync(
  WidgetTester tester,
  String lang, {
  bool settle = true,
}) async {
  final button = find.widgetWithText(
    FilledButton,
    lang == 'ar' ? 'مزامنة مع تحقق الخادم' : 'Sync with server verification',
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('encrypted reception draft UI protocol $lang $width', (
        tester,
      ) async {
        final journal = Journal(), gateway = Gateway(Journal());
        final actual = Gateway(journal);
        gateway.changes.close();
        await mount(tester, actual, journal, lang: lang, width: width);
        await unlock(tester, lang);
        expect(journal.rows.length, 1);
        expect(journal.rows.single['request'], request());
        expect(actual.calls, isEmpty);
        expect(find.text('SH-BKG-000001'), findsOneWidget);
        await sync(tester, lang);
        expect(actual.calls.single, request());
        expect(journal.rows.single['state'], 'confirmed');
        expect(
          find.text(lang == 'ar' ? 'إقرار خادم محفوظ' : 'Server receipt saved'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('lost sync acknowledgement retries the exact frozen nonce', (
    tester,
  ) async {
    final journal = Journal();
    final gateway = Gateway(journal)..lose = true;
    await mount(tester, gateway, journal);
    await unlock(tester, 'en');
    await sync(tester, 'en');
    expect(journal.rows.single['state'], 'uncertain');
    expect(find.text('Cancel unsent draft'), findsNothing);
    await sync(tester, 'en');
    expect(gateway.calls.length, 2);
    expect(gateway.calls[0], gateway.calls[1]);
    expect(journal.rows.single['state'], 'confirmed');
  });
  testWidgets(
    'server conflict preserves the exact draft without private errors',
    (tester) async {
      final journal = Journal();
      final gateway = Gateway(journal)
        ..rejection = const PostgrestException(
          message: 'private server details',
          code: '40001',
        );
      await mount(tester, gateway, journal);
      await unlock(tester, 'en');
      await sync(tester, 'en');
      expect(journal.rows.single['state'], 'conflict');
      expect(journal.rows.single['request'], request());
      expect(find.textContaining('private server details'), findsNothing);
      expect(find.text('Conflict retained for review'), findsOneWidget);
    },
  );
  testWidgets('offline probe leaves an unsent draft cancellable', (
    tester,
  ) async {
    final journal = Journal();
    final gateway = Gateway(journal)..offline = true;
    await mount(tester, gateway, journal);
    await unlock(tester, 'en');
    await sync(tester, 'en');
    expect(gateway.calls, isEmpty);
    expect(journal.rows.single['dispatch_started'], isFalse);
    expect(journal.rows.single['state'], 'pending');
    expect(find.text('Cancel unsent draft'), findsOneWidget);
  });
  testWidgets('account change clears plaintext and ignores a late receipt', (
    tester,
  ) async {
    final journal = Journal();
    final gateway = Gateway(journal)
      ..pending = Completer<Map<String, dynamic>>();
    await mount(tester, gateway, journal);
    await unlock(tester, 'en');
    await sync(tester, 'en', settle: false);
    expect(gateway.calls.length, 1);
    gateway.actor = null;
    gateway.changes.add(null);
    await tester.pump();
    gateway.pending!.complete({'booking_id': booking});
    await tester.pumpAndSettle();
    expect(journal.locked, isTrue);
    expect(journal.events, isNot(contains('confirmed')));
    expect(find.text('Isolated local arrival note'), findsNothing);
    expect(find.textContaining('Session changed.'), findsOneWidget);
  });
  testWidgets('anonymous access cannot read local journals', (tester) async {
    final journal = Journal();
    final gateway = Gateway(journal)..actor = null;
    await mount(tester, gateway, journal);
    expect(find.textContaining('Session changed.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(gateway.calls, isEmpty);
  });
}
