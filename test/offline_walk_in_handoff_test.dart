import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sabiha_hub/offline_customer_registration.dart';
import 'package:sabiha_hub/offline_walk_in.dart';

import 'offline_customer_registration_test.dart' as registration;
import 'offline_walk_in_test.dart' as work;

const registrationId = work.registrationId;
const commandId = work.savedId;
const customerReceipt = '44444444-4444-4444-8444-444444444444';
const otherId = '55555555-5555-4555-8555-555555555555';

class IntakeGateway extends registration.FakeRegistrationGateway {
  @override
  Map<String, dynamic> result(
    String id, {
    String status = 'created_unverified',
  }) => {
    ...super.result(id, status: status),
    'enrollment_receipt_id': customerReceipt,
    'enrollment_secret_issued': [
      'created_unverified',
      'reused_unverified',
    ].contains(status),
  };
}

class IntakeStore extends registration.MemoryRegistrationStore {
  bool failClear = false;
  @override
  Future<void> clear() async {
    if (failClear) throw StateError('Storage unavailable');
    await super.clear();
  }
}

class CommandStore extends work.MemoryStore {
  CommandStore(this.events);
  final List<String> events;
  bool failClear = false, failWrite = false;
  @override
  Future<void> write(String id) async {
    if (failWrite) throw StateError('Storage unavailable');
    events.add('command.write');
    await super.write(id);
  }

  @override
  Future<void> clear() async {
    events.add('command.clear');
    if (failClear) throw StateError('Storage unavailable');
    await super.clear();
  }
}

class Handoff implements OfflineWalkInHandoffStore {
  Handoff({
    this.source,
    this.associated,
    this.pending,
    this.readOriginal,
    List<String>? events,
  }) : events = events ?? [];
  String? source, associated, pending;
  final String? Function()? readOriginal;
  final List<String> events;
  bool failStage = false,
      failConsume = false,
      failFinish = false,
      failAssociateAfterWrite = false;
  @override
  String get branchId => 'branch';
  @override
  Future<OfflineWalkInHandoffState> read() async => OfflineWalkInHandoffState(
    registration: source,
    command: associated,
    pendingRegistration: readOriginal == null ? pending : readOriginal!(),
  );
  @override
  Future<void> stage(String id) async {
    events.add('handoff.stage');
    final s = await read();
    if (failStage ||
        s.pendingRegistration != id ||
        associated != null ||
        (source != null && source != id)) {
      throw StateError('Stage unavailable');
    }
    source = id;
  }

  @override
  Future<void> associate(String reg, String cmd) async {
    final s = await read();
    if (s.pendingRegistration != null ||
        source != reg ||
        (associated != null && associated != cmd)) {
      throw StateError('References differ');
    }
    associated = cmd;
    events.add('handoff.associate');
    if (failAssociateAfterWrite) throw StateError('Lost storage response');
  }

  @override
  Future<void> consumeSource(String reg, String cmd) async {
    events.add('handoff.consume');
    if (failConsume || associated != cmd || (source != null && source != reg)) {
      throw StateError('Cannot clear source');
    }
    source = null;
  }

  @override
  Future<void> discardSource(String reg) async {
    final state = await read();
    if (source == null) return;
    if (source != reg ||
        (state.pendingRegistration != null && state.pendingRegistration != reg)) {
      throw StateError('Mismatch');
    }
    if (associated != null) return;
    source = null;
  }

  @override
  Future<void> finishCommand(String cmd, String? reg) async {
    events.add('handoff.finish');
    final s = await read();
    if (failFinish ||
        s.pendingRegistration != null ||
        (associated != null && associated != cmd)) {
      throw StateError('Cannot finish');
    }
    if (associated == cmd) {
      if (source != null && reg != null && source != reg) {
        throw StateError('References differ');
      }
      source = null;
      associated = null;
    } else if (source == reg && reg != null) {
      source = null;
    }
  }
}

class WorkGateway extends work.Gateway {
  final contexts = <String>[];
  bool losePreparationBeforeCommit = false;
  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> body) async {
    final response = await super.prepare(body);
    if (losePreparationBeforeCommit) {
      losePreparationBeforeCommit = false;
      current = null;
      throw StateError('Uncommitted preparation response lost');
    }
    return response;
  }

  @override
  Future<Map<String, dynamic>> context(String reg) async {
    contexts.add(reg);
    return {...contextResult(), 'registration_request_id': reg};
  }

  @override
  Future<Map<String, dynamic>> acknowledge(String id) async {
    final response = await super.acknowledge(id);
    if (response['acknowledged'] == true) current = response;
    return response;
  }

  @override
  Future<Map<String, dynamic>> recover(String? id) async {
    if (id == null && current?['acknowledged'] == true) {
      recoveries.add(id);
      return {'status': 'absent', 'definitive_failure': false};
    }
    return super.recover(id);
  }
}

class StaffAuth extends GoTrueClient {
  StaffAuth(String id)
    : current = staff(id),
      super(url: 'http://127.0.0.1:54321/auth/v1', autoRefreshToken: false);
  User? current;
  static User staff(String id) => User(
    id: id,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-11-14T00:00:00Z',
  );
  @override
  User? get currentUser => current;
}

class StaffClient extends SupabaseClient {
  StaffClient(this.staffAuth)
    : super(
        'http://127.0.0.1:54321',
        'mock',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final StaffAuth staffAuth;
  @override
  GoTrueClient get auth => staffAuth;
}

Future<OfflineWalkInController> control(
  WorkGateway api,
  CommandStore store,
  Handoff handoff,
) async {
  final c = OfflineWalkInController(
    gateway: api,
    store: store,
    handoff: handoff,
  );
  addTearDown(c.dispose);
  await c.initialize();
  return c;
}

Future<void> intake(
  WidgetTester t,
  IntakeGateway api,
  IntakeStore store,
  Handoff h, {
  bool arabic = false,
  double width = 1440,
  ValueChanged<String>? received,
}) async {
  t.view.physicalSize = Size(width, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(arabic ? 'ar' : 'en'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: OfflineCustomerRegistrationScreen(
        client: registration.testClient(),
        branchId: 'branch',
        role: 'owner',
        gateway: api,
        store: store,
        onStageReceiveWork: h.stage,
        onDiscardReceiveWork: h.discardSource,
        onReceiveWork: received ?? (_) {},
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> reception(
  WidgetTester t,
  WorkGateway api,
  CommandStore store,
  Handoff h, {
  VoidCallback? resume,
  String? initial = registrationId,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: OfflineWalkInScreen(
        client: registration.testClient(),
        role: 'owner',
        initialRegistrationRequestId: initial,
        gateway: api,
        store: store,
        handoff: h,
        onResumeRegistration: resume,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'discard recovery: failed clear then Done releases only staged registration',
    (t) async {
      final api = IntakeGateway();
      final store = IntakeStore();
      final h = Handoff(readOriginal: () => store.value);
      await intake(t, api, store, h);
      await registration.fill(t);
      await registration.press(t, 'submit_registration');
      await registration.press(t, 'receipt_acknowledged');
      store.failClear = true;
      await registration.press(t, 'registration_receive_work');
      expect(h.source, store.value);
      store.failClear = false;
      await registration.press(t, 'registration_done');
      expect(h.source, isNull);
      expect(store.value, isNull);
      store.value = otherId;
      await h.stage(otherId);
      expect(h.source, otherId);
      h.associated = commandId;
      await h.discardSource(otherId);
      expect(h.source, otherId);
      expect(h.associated, commandId);
      await expectLater(h.discardSource(registrationId), throwsStateError);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'discard recovery: restored context explicitly clears without any command API',
    (t) async {
      final api = WorkGateway();
      final store = CommandStore([]);
      final h = Handoff()..source = registrationId;
      await reception(t, api, store, h);
      expect(
        find.byKey(const ValueKey('discard_walk_in_context')),
        findsOneWidget,
      );
      await registration.press(t, 'discard_walk_in_context');
      expect(h.source, isNull);
      expect(store.value, isNull);
      expect(api.preparations, isEmpty);
      expect(api.places, isEmpty);
      expect(api.closes, isEmpty);
      expect(find.byKey(const ValueKey('prepare_walk_in')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  test('real handoff preferences contain UUIDs only and isolate staff/branch/original pending receipt', () async {
    const actor = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const branch = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const otherBranch = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    SharedPreferences.setMockInitialValues({
      'offline_registration_uuid_${actor}_$branch': registrationId,
    });
    final auth = StaffAuth(actor);
    final client = StaffClient(auth);
    addTearDown(() async {
      await client.dispose();
      auth.dispose();
    });
    final handoff = SharedOfflineWalkInHandoffStore(client, branch);
    await expectLater(
      handoff.stage('not-a-UUID-private-code'),
      throwsStateError,
    );
    await handoff.stage(registrationId);
    await expectLater(
      handoff.associate(registrationId, commandId),
      throwsStateError,
    );
    expect((await handoff.read()).pendingRegistration, registrationId);
    await SharedOfflineRegistrationStore(client, branch).clear();
    await expectLater(handoff.associate(otherId, commandId), throwsStateError);
    await handoff.associate(registrationId, commandId);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), hasLength(2));
    expect(
      preferences.getKeys().every(
        (key) => key.contains(actor) && key.contains(branch),
      ),
      isTrue,
    );
    expect(
      preferences.getKeys().map(preferences.get),
      unorderedEquals([registrationId, commandId]),
    );
    expect(
      (await SharedOfflineWalkInHandoffStore(
        client,
        otherBranch,
      ).read()).registration,
      isNull,
    );
    auth.current = StaffAuth.staff(otherId);
    await expectLater(handoff.read(), throwsStateError);
    expect(
      (await SharedOfflineWalkInHandoffStore(
        client,
        branch,
      ).read()).registration,
      isNull,
    );
    auth.current = StaffAuth.staff(actor);
    await expectLater(
      handoff.finishCommand(otherId, registrationId),
      throwsStateError,
    );
    expect((await handoff.read()).command, commandId);
    await handoff.consumeSource(registrationId, commandId);
    expect((await handoff.read()).registration, isNull);
    expect((await handoff.read()).command, commandId);
    await handoff.finishCommand(commandId, registrationId);
    expect(preferences.getKeys(), isEmpty);
  });

  for (final (ar, width) in [(true, 390.0), (false, 1440.0)]) {
    testWidgets(
      'explicit receipt acknowledgement clears visible code before UUID-only handoff ${ar ? 'AR390' : 'EN1440'}',
      (t) async {
        final api = IntakeGateway();
        final store = IntakeStore();
        final h = Handoff(readOriginal: () => store.value);
        String? handed;
        bool? codeRemoved;
        await intake(
          t,
          api,
          store,
          h,
          arabic: ar,
          width: width,
          received: (id) {
            handed = id;
            codeRemoved = find
                .byKey(const ValueKey('enrollment_secret'))
                .evaluate()
                .isEmpty;
            expect(store.value, isNull);
          },
        );
        await registration.fill(t);
        await registration.press(t, 'submit_registration');
        final original = store.value!;
        expect(
          t
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('registration_receive_work')),
              )
              .onPressed,
          isNull,
        );
        expect(h.source, isNull);
        await registration.press(t, 'receipt_acknowledged');
        await registration.press(t, 'registration_receive_work');
        expect(handed, original);
        expect(handed, isNot(customerReceipt));
        expect(codeRemoved, isTrue);
        expect(h.source, original);
        expect(h.associated, isNull);
        expect(api.calls, hasLength(1));
        expect(store.value, isNull);
        expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'stage and registration clear failures preserve receipt and never navigate',
    (t) async {
      final api = IntakeGateway();
      final store = IntakeStore();
      final h = Handoff(readOriginal: () => store.value)..failStage = true;
      final passed = <String>[];
      await intake(t, api, store, h, received: passed.add);
      await registration.fill(t);
      await registration.press(t, 'submit_registration');
      final id = store.value;
      await registration.press(t, 'receipt_acknowledged');
      await registration.press(t, 'registration_receive_work');
      expect(store.value, id);
      expect(store.clears, 0);
      expect(passed, isEmpty);
      expect(h.source, isNull);
      expect(find.byKey(const ValueKey('enrollment_secret')), findsOneWidget);
      h.failStage = false;
      store.failClear = true;
      await registration.press(t, 'registration_receive_work');
      expect(h.source, id);
      expect(store.value, id);
      expect(passed, isEmpty);
      expect(find.byKey(const ValueKey('enrollment_secret')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'recovered reused receipt requires missing-code acknowledgement and passes staff nonce',
    (t) async {
      final api = IntakeGateway();
      api.recovered = api.result(registrationId, status: 'reused_unverified');
      final store = IntakeStore()..value = registrationId;
      final h = Handoff(readOriginal: () => store.value);
      final passed = <String>[];
      await intake(t, api, store, h, received: passed.add);
      expect(find.byKey(const ValueKey('enrollment_secret')), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('registration_receive_work')),
            )
            .onPressed,
        isNull,
      );
      await registration.press(t, 'receipt_acknowledged');
      await registration.press(t, 'registration_receive_work');
      expect(passed, [registrationId]);
      expect(passed.single, isNot(customerReceipt));
      expect(api.calls, isEmpty);
      expect(store.value, isNull);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('closed and review-required receipts never offer handoff', (
    t,
  ) async {
    for (final status in ['closed', 'review_required']) {
      final api = IntakeGateway();
      api.recovered = status == 'closed'
          ? {
              'request_id': registrationId,
              'status': 'closed',
              'branch_id': 'branch',
              'registration_created': false,
              'may_retry_same_request': false,
              'definitive_failure': true,
            }
          : api.result(registrationId, status: status);
      final store = IntakeStore()..value = registrationId;
      final h = Handoff(readOriginal: () => store.value);
      await intake(t, api, store, h);
      expect(
        find.byKey(const ValueKey('registration_receive_work')),
        findsNothing,
      );
      expect(h.events, isEmpty);
      expect(store.value, registrationId);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'reload before clear resumes registration; after clear restores context only',
    (t) async {
      final original = IntakeStore()..value = registrationId;
      final h = Handoff(
        source: registrationId,
        readOriginal: () => original.value,
      );
      final api = WorkGateway();
      final store = CommandStore([]);
      var resumed = 0;
      await reception(t, api, store, h, resume: () => resumed++);
      expect(api.contexts, isEmpty);
      expect(api.preparations, isEmpty);
      expect(find.byKey(const ValueKey('walk_in_registration')), findsNothing);
      await work.press(t, 'walk_in_resume_registration');
      expect(resumed, 1);
      await original.clear();
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      await reception(t, api, store, h, initial: null);
      expect(api.contexts, [registrationId]);
      expect(api.preparations, isEmpty);
      expect(api.places, isEmpty);
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('prepare_walk_in')))
            .onPressed,
        isNull,
      );
      expect(h.source, registrationId);
      expect(t.takeException(), isNull);
    },
  );
  test('lost association response recovers exact C, never auto-prepares, close/ack clears H-C before nonce', () async {
    final events = <String>[];
    final h = Handoff(source: registrationId, events: events)
      ..failAssociateAfterWrite = true;
    final api = WorkGateway();
    final store = CommandStore(events);
    final c = await control(api, store, h);
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['worker'], '');
    expect(api.preparations, isEmpty);
    expect(c.locked, isTrue);
    final id = h.associated!;
    expect(store.value, isNull);
    h.failAssociateAfterWrite = false;
    final restored = await control(api, store, h);
    expect(store.value, id);
    expect(restored.status, 'absent');
    expect(restored.locked, isTrue);
    expect(api.preparations, isEmpty);
    await restored.close();
    await restored.acknowledge();
    expect(h.source, isNull);
    expect(h.associated, isNull);
    expect(store.value, isNull);
    expect(
      events.indexOf('handoff.finish'),
      lessThan(events.indexOf('command.clear')),
    );
  });
  test('server preparation consumes matching H; failed actual ack/cleanup retains command and stale H never creates again', () async {
    final events = <String>[];
    final h = Handoff(source: registrationId, events: events);
    final api = WorkGateway();
    final store = CommandStore(events);
    final c = await control(api, store, h);
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['worker'], '');
    final id = store.value!;
    expect(h.associated, id);
    expect(h.source, isNull);
    await c.place();
    api.ackConfirmed = false;
    await c.acknowledge();
    expect(store.value, id);
    expect(h.associated, id);
    expect(store.clears, 0);
    api.ackConfirmed = true;
    h.failFinish = true;
    await c.acknowledge();
    expect(store.value, id);
    expect(h.associated, id);
    expect(store.clears, 0);
    h.failFinish = false;
    store.failClear = true;
    await c.acknowledge();
    expect(store.value, id);
    expect(h.associated, isNull);
    expect(c.locked, isTrue);
    store.failClear = false;
    await c.acknowledge();
    expect(store.value, isNull);
    expect(h.source, isNull);
    expect(h.associated, isNull);
    final reopened = await control(api, store, h);
    expect(reopened.restorableRegistration, isNull);
    expect(api.preparations, hasLength(1));
    expect(api.places, hasLength(1));
    expect(
      events.indexOf('handoff.finish'),
      lessThan(events.indexOf('command.clear')),
    );
  });
  test(
    'known C mismatch never overwrites references or dispatches a new command',
    () async {
      final h = Handoff(source: registrationId, associated: otherId);
      final api = WorkGateway();
      final store = CommandStore([])..value = commandId;
      final c = await control(api, store, h);
      expect(c.locked, isTrue);
      expect(c.errorCode, 'unconfirmed');
      expect(store.value, commandId);
      expect(h.associated, otherId);
      expect(api.recoveries, isEmpty);
      await c.prepareSelection('service', ['worker'], '');
      expect(api.preparations, isEmpty);
      expect(store.clears, 0);
    },
  );
  test('pending original receipt blocks even an exact retry after absent preparation', () async {
    final api = WorkGateway()..losePreparationBeforeCommit = true;
    final h = Handoff(source: registrationId);
    final store = CommandStore([]);
    final c = await control(api, store, h);
    await c.loadContext(registrationId);
    await c.prepareSelection('service', ['worker'], 'Exact saved note');
    final exact = api.preparations.single;
    final id = store.value;
    h.pending = otherId;
    await c.retryPreparation();
    expect(c.errorCode, 'registration_pending');
    expect(c.locked, isTrue);
    expect(api.preparations, hasLength(1));
    expect(store.value, id);
    h.pending = null;
    await c.retryPreparation();
    expect(api.preparations, [exact, exact]);
    expect(store.value, id);
    expect(api.places, isEmpty);
    expect(h.source, isNull);
  });
}
