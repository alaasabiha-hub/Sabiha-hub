// SOURCE DRAFT: intended test/service_work_test.dart. Not run until root integrates.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/service_work.dart';

const workOrder = '22222222-2222-4222-8222-222222222222';
const savedRequest = '11111111-1111-4111-8111-111111111111';
const otherRequest = '33333333-3333-4333-8333-333333333333';
const otherOrder = '44444444-4444-4444-8444-444444444444';
Map<String, dynamic> clone(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

class WorkMemoryStore implements ServiceWorkStore {
  String? value;
  final writes = <String>[];
  int clears = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async {
    value = id;
    writes.add(id);
  }

  @override
  Future<void> clear() async {
    value = null;
    clears++;
  }
}

class WorkMockGateway implements ServiceWorkGateway {
  final records = <String, Map<String, dynamic>>{};
  final preparations = <Map<String, dynamic>>[];
  final places = <String>[];
  final recoveries = <String?>[];
  String workStatus = 'received';
  int effects = 0;
  bool failPrepareBeforeCommit = false,
      losePrepare = false,
      losePlace = false,
      loseClose = false,
      failRecovery = false,
      ackConfirmed = true,
      denyContext = false;
  String? placeError;
  Map<String, dynamic> contextValue(String order) => {
    'source_kind': 'walk_in',
    'order_id': order,
    'work_reference': 'SH-INV-000821',
    'service': {
      'name': 'Actual long service name / خدمة فعلية لفحص وضوح العرض',
      'duration_minutes': 30,
      'resource_key': 'wash',
    },
    'plate_number': 'QA 123',
    'work_status': workStatus,
    'assigned_staff': [
      {'id': 'staff', 'name': 'Actual assigned worker / الموظف المكلف فعلياً'},
    ],
    'next_status': {
      'received': 'in_progress',
      'in_progress': 'quality_check',
      'quality_check': 'completed',
      'completed': 'delivered',
    }[workStatus],
    'can_prepare': workStatus != 'delivered',
    'blockers': <String>[],
    'canonical_work_supported': true,
  };
  Map<String, dynamic> prepared(String id, {String order = workOrder}) => {
    'request_id': id,
    'status': 'prepared',
    'acknowledged': false,
    'payload': {
      'order_id': order,
      'expected_status': 'received',
      'next_status': 'in_progress',
      'reason': 'Original real work reason',
    },
    'result': {
      'order_id': order,
      'current_state_available': true,
      'current_work_status': workStatus,
    },
  };
  Map<String, dynamic> reply(Map<String, dynamic> record) {
    final result = clone(record);
    if (result['status'] != 'closed') {
      result['result'] = <String, dynamic>{
        ...?result['result'] as Map<String, dynamic>?,
        'current_state_available': true,
        'current_work_status': workStatus,
        'work_reference': 'SH-INV-000821',
        'physical_open': ['in_progress', 'quality_check'].contains(workStatus),
      };
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> context({String? order, String? booking}) async {
    if (denyContext) {
      throw const PostgrestException(message: 'Denied', code: '42501');
    }
    return contextValue(order ?? workOrder);
  }

  @override
  Future<Map<String, dynamic>> queue(String branch) async => {
    'branch_id': branch,
    'items': [contextValue(workOrder)],
    'more_available': false,
  };
  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> p) async {
    preparations.add(clone(p));
    if (failPrepareBeforeCommit) {
      failPrepareBeforeCommit = false;
      throw TimeoutException('No confirmed preparation');
    }
    final id = p['p_request'] as String;
    records.putIfAbsent(
      id,
      () => prepared(id, order: p['p_order'] as String)
        ..['payload'] = {
          'order_id': p['p_order'],
          'expected_status': p['p_expected_status'],
          'next_status': p['p_next_status'],
          'reason': p['p_reason'],
        },
    );
    if (losePrepare) {
      losePrepare = false;
      throw TimeoutException('Lost response');
    }
    return reply(records[id]!);
  }

  @override
  Future<Map<String, dynamic>> recover(String? request) async {
    recoveries.add(request);
    if (failRecovery) {
      throw TimeoutException('No discovery response');
    }
    final pending = records.values
        .where((v) => v['acknowledged'] != true)
        .toList();
    final record = request == null
        ? (pending.isEmpty ? null : pending.last)
        : records[request];
    return record == null
        ? {'status': 'absent', 'definitive_failure': false}
        : reply(record);
  }

  @override
  Future<Map<String, dynamic>> place(String request) async {
    places.add(request);
    if (placeError != null) {
      throw PostgrestException(
        message: 'Known server rejection',
        code: placeError,
      );
    }
    final record = records[request]!;
    if (record['status'] == 'prepared') {
      effects++;
      workStatus = (record['payload'] as Map)['next_status'] as String;
      record['status'] = 'succeeded';
      record['result'] = {
        'order_id': (record['payload'] as Map)['order_id'],
        'performed_status': workStatus,
      };
    }
    if (losePlace) {
      losePlace = false;
      throw TimeoutException('Lost committed response');
    }
    return reply(record);
  }

  @override
  Future<Map<String, dynamic>> close(String request) async {
    final record = records.putIfAbsent(request, () => prepared(request));
    if (record['status'] != 'succeeded') {
      record['status'] = 'closed';
      record['result'] = {'status': 'closed', 'current_state_available': false};
    }
    if (loseClose) {
      loseClose = false;
      throw TimeoutException('Lost close response');
    }
    return reply(record);
  }

  @override
  Future<Map<String, dynamic>> acknowledge(String request) async {
    final record = records[request]!;
    record['acknowledged'] = ackConfirmed;
    return reply(record);
  }
}

void main() {
  ServiceWorkController make(WorkMockGateway gateway, WorkMemoryStore store) =>
      ServiceWorkController(gateway: gateway, store: store, order: workOrder);
  test(
    'invalid reason never creates a durable identity or calls preparation',
    () async {
      final gateway = WorkMockGateway(), store = WorkMemoryStore();
      final c = make(gateway, store);
      addTearDown(c.dispose);
      await c.initialize();
      await c.prepare('no');
      expect(c.errorCode, 'invalid_reason');
      expect(store.writes, isEmpty);
      expect(gateway.preparations, isEmpty);
      expect(c.locked, isFalse);
    },
  );
  test('uncertain preparation retries exact UUID and payload despite context changes', () async {
    final gateway = WorkMockGateway()..failPrepareBeforeCommit = true,
        store = WorkMemoryStore();
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare('Original actual reason');
    final id = c.requestId;
    expect(c.locked, isTrue);
    c.contextData!['next_status'] = 'completed';
    await c.retryPreparation();
    expect(gateway.preparations[1], gateway.preparations[0]);
    expect(c.requestId, id);
    expect(store.writes, [id]);
    expect(gateway.effects, 0);
  });
  test(
    'committed place response lost: same request recovery executes once',
    () async {
      final gateway = WorkMockGateway()..losePlace = true,
          store = WorkMemoryStore();
      final c = make(gateway, store);
      addTearDown(c.dispose);
      await c.initialize();
      await c.prepare('Assigned worker checked job');
      final id = c.requestId!;
      await c.place();
      expect(c.uncertain, isTrue);
      await c.place();
      expect(gateway.effects, 1);
      expect(gateway.places, [id, id]);
      expect(c.status, 'succeeded');
      expect(store.value, id);
      await c.acknowledge();
      expect(store.value, isNull);
      expect(c.contextData!['next_status'], 'quality_check');
      expect(gateway.effects, 1);
    },
  );
  test('new device discovers unacknowledged success and persists UUID before clearing', () async {
    final gateway = WorkMockGateway(), store = WorkMemoryStore();
    gateway.records[savedRequest] = gateway.prepared(savedRequest)
      ..['status'] = 'succeeded'
      ..['result'] = {'order_id': workOrder, 'performed_status': 'in_progress'};
    gateway.workStatus = 'in_progress';
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    expect(store.writes, [savedRequest]);
    expect(c.status, 'succeeded');
    expect(c.locked, isTrue);
    expect(gateway.effects, 0);
    gateway.ackConfirmed = false;
    await c.acknowledge();
    expect(store.value, savedRequest);
    expect(store.clears, 0);
    gateway.ackConfirmed = true;
    await c.acknowledge();
    expect(store.value, isNull);
    expect(store.clears, 1);
  });
  test('restart prepared request uses server payload without local operational fields', () async {
    final gateway = WorkMockGateway(),
        store = WorkMemoryStore()..value = savedRequest;
    gateway.records[savedRequest] = gateway.prepared(savedRequest);
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.status, 'prepared');
    expect(c.canRetryPreparation, isFalse);
    await c.place();
    expect(gateway.places, [savedRequest]);
    expect(gateway.preparations, isEmpty);
    expect(gateway.effects, 1);
    expect(store.writes, isEmpty);
  });
  test(
    'absent local A stays frozen, can fence it then discover actual pending B',
    () async {
      final gateway = WorkMockGateway(),
          store = WorkMemoryStore()..value = savedRequest;
      gateway.records[otherRequest] = gateway.prepared(
        otherRequest,
        order: otherOrder,
      );
      final c = make(gateway, store);
      addTearDown(c.dispose);
      await c.initialize();
      expect(c.requestId, savedRequest);
      expect(c.uncertain, isTrue);
      expect(c.canPrepare, isFalse);
      await c.close();
      await c.acknowledge();
      expect(c.requestId, otherRequest);
      expect(store.value, otherRequest);
      expect(c.contextData!['order_id'], otherOrder);
      expect(gateway.effects, 0);
    },
  );
  test('known stale SQL result still requires authoritative close before a new identity', () async {
    final gateway = WorkMockGateway()..placeError = '40001',
        store = WorkMemoryStore();
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare('Actual prior dispatch');
    final id = c.requestId;
    await c.place();
    await c.prepare('Cannot rotate this request');
    expect(store.writes, [id]);
    expect(c.errorCode, 'stale');
    await c.close();
    await c.acknowledge();
    expect(c.canPrepare, isTrue);
    expect(gateway.effects, 0);
  });
  test('lost close response retains identity until actual closed receipt and acknowledgment', () async {
    final gateway = WorkMockGateway()..loseClose = true,
        store = WorkMemoryStore();
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    await c.prepare('Pending work note');
    final id = c.requestId;
    await c.close();
    expect(store.value, id);
    expect(c.uncertain, isTrue);
    await c.recover();
    expect(c.status, 'closed');
    expect(store.value, id);
    await c.acknowledge();
    expect(store.value, isNull);
    expect(gateway.effects, 0);
  });
  test('unknown discovery stays frozen; denied context after known absence permits leaving', () async {
    final gateway = WorkMockGateway()..failRecovery = true,
        store = WorkMemoryStore();
    final c = make(gateway, store);
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.locked, isTrue);
    expect(store.writes, isEmpty);
    gateway.failRecovery = false;
    gateway.denyContext = true;
    await c.recover();
    expect(c.requestId, isNull);
    expect(c.errorCode, 'access_denied');
    expect(c.locked, isFalse);
    expect(c.canPrepare, isFalse);
  });
  for (final entry in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      '${entry.$1} work screen preserves explicit quality step and has no overflow at ${entry.$2}',
      (tester) async {
        tester.view.physicalSize = Size(entry.$2, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = WorkMockGateway(),
            store = WorkMemoryStore(),
            c = make(gateway, store);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(entry.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            ),
            home: ServiceWorkScreen(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byType(TextField),
          'Actual assigned crew checked this work',
        );
        final start = entry.$1 == 'ar' ? 'بدء الخدمة' : 'Start service';
        await tester.ensureVisible(find.text(start));
        await tester.tap(find.text(start));
        await tester.pumpAndSettle();
        expect(gateway.effects, 0);
        final apply = entry.$1 == 'ar'
            ? 'تطبيق التغيير المحفوظ'
            : 'Apply saved change';
        await tester.ensureVisible(find.text(apply));
        await tester.tap(find.text(apply));
        await tester.pumpAndSettle();
        expect(gateway.effects, 1);
        final ack = entry.$1 == 'ar' ? 'تأكيد وتحديث' : 'Confirm and refresh';
        await tester.ensureVisible(find.text(ack));
        await tester.tap(find.text(ack));
        await tester.pumpAndSettle();
        expect(
          find.text(
            entry.$1 == 'ar'
                ? 'الانتقال لمراجعة الجودة'
                : 'Move to quality check',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            entry.$1 == 'ar' ? 'تأكيد اكتمال الخدمة' : 'Confirm completion',
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
