import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/recruitment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeRecruitment extends RecruitmentGateway {
  final calls = <String>[];
  final uploadedTokens = <String>[];
  bool failUploadOnce = false;
  @override
  Future<void> uploadCv(String id, String token, Uint8List bytes) async {
    uploadedTokens.add(token);
    if (failUploadOnce) {
      failUploadOnce = false;
      throw Exception('Connection lost');
    }
  }

  final payloads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> action(
    String action,
    Map<String, dynamic> data,
  ) async {
    calls.add(action);
    payloads.add(Map<String, dynamic>.from(data));
    if (action == 'submit') {
      return {'application_id': 'application-reference', 'status': 'received'};
    }
    return {
      'jobs': [
        {
          'id': 'job1',
          'title_en': 'Service technician',
          'title_ar': 'فني خدمات',
          'details_en': 'Relevant practical experience',
          'details_ar': 'خبرة عملية مناسبة',
          'branch_id': 'branch1',
          'published': true,
        },
      ],
      'branches': [
        {'id': 'branch1', 'name_en': 'Main branch', 'name_ar': 'الفرع الرئيسي'},
      ],
      'applications': [
        {
          'id': 'application1',
          'name': 'Candidate',
          'email': 'candidate@example.invalid',
          'phone': null,
          'message': 'Practical experience',
          'title_en': 'Service technician',
          'title_ar': 'فني خدمات',
          'status': 'submitted',
          'owner_note': '',
          'verified_accounts': [],
        },
      ],
    };
  }
}

SupabaseClient client() => SupabaseClient(
  'http://localhost:54321',
  'test',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);
void main() {
  testWidgets(
    'public application submits actual fields without account or owner controls',
    (tester) async {
      final fake = FakeRecruitment();
      await tester.pumpWidget(
        MaterialApp(
          home: RecruitmentScreen(client: client(), gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, ['jobs']);
      expect(find.text('Publish vacancy'), findsNothing);
      expect(find.text('Candidate'), findsNothing);
      await tester.tap(find.text('Apply without an account'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Applicant');
      await tester.enterText(fields.at(1), 'applicant@example.invalid');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      final i = fake.calls.indexOf('submit');
      expect(i, greaterThan(-1));
      expect(fake.payloads[i]['job_id'], 'job1');
      expect(fake.payloads[i]['email'], 'applicant@example.invalid');
      expect(fake.payloads[i]['request_id'], isNotEmpty);
      expect(find.textContaining('application-reference'), findsOneWidget);
    },
  );
  for (final scenario in [('ar', 390.0), ('en', 1440.0)]) {
    testWidgets(
      'public application remains available without login ${scenario.$1} ${scenario.$2}',
      (tester) async {
        tester.view.physicalSize = Size(scenario.$2, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fake = FakeRecruitment();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(scenario.$1),
            supportedLocales: const [Locale('ar'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: RecruitmentScreen(client: client(), gateway: fake),
          ),
        );
        await tester.pumpAndSettle();
        expect(fake.calls, ['jobs']);
        await tester.tap(
          find.text(
            scenario.$1 == 'ar'
                ? 'التقديم دون حساب'
                : 'Apply without an account',
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), 'QA Applicant');
        await tester.enterText(find.byType(TextField).at(2), '+201000000000');
        await tester.tap(find.text(scenario.$1 == 'ar' ? 'تأكيد' : 'Confirm'));
        await tester.pumpAndSettle();
        expect(fake.calls.where((v) => v == 'submit'), hasLength(1));
        expect(fake.payloads.any((p) => p['job_id'] == 'job1'), isTrue);
        expect(fake.payloads.any((p) => p['phone'] == '+201000000000'), isTrue);
        expect(fake.payloads.any((p) => p['email'] == ''), isTrue);
        expect(find.textContaining('application-reference'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'optional CV retry keeps one application and the same upload capability',
    (tester) async {
      final fake = FakeRecruitment()..failUploadOnce = true;
      final bytes = Uint8List.fromList(
        utf8.encode('%PDF-1.4\nSynthetic CV only\n%%EOF\n'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecruitmentScreen(
            client: client(),
            gateway: fake,
            cvPicker: () async => RecruitmentCvFile(
              name: 'synthetic.pdf',
              size: bytes.length,
              stream: Stream.value(bytes),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply without an account'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'Synthetic Applicant',
      );
      await tester.enterText(
        find.byType(TextField).at(1),
        'synthetic@example.invalid',
      );
      final attach = find.text('Attach optional PDF CV · up to 2 MiB');
      await tester.ensureVisible(attach);
      await tester.tap(attach);
      await tester.pumpAndSettle();
      expect(find.text('synthetic.pdf'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text('Retry CV upload'), findsOneWidget);
      await tester.tap(find.text('Retry CV upload'));
      await tester.pumpAndSettle();
      expect(fake.uploadedTokens.length, 2);
      expect(fake.uploadedTokens.first, fake.uploadedTokens.last);
      expect(fake.calls.where((v) => v == 'submit').length, 1);
      expect(
        find.textContaining('private unscanned attachment'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'owner acceptance is separate from employee preparation and activation',
    (tester) async {
      final fake = FakeRecruitment();
      await tester.pumpWidget(
        MaterialApp(
          home: RecruitmentScreen(client: client(), owner: true, gateway: fake),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, ['owner_read']);
      await tester.ensureVisible(find.text('Accept candidate'));
      await tester.tap(find.text('Accept candidate'));
      await tester.pumpAndSettle();
      expect(fake.calls, ['owner_read', 'review', 'owner_read']);
      expect(fake.payloads[1]['status'], 'accepted');
      expect(fake.calls.contains('prepare_employee'), isFalse);
      expect(fake.calls.contains('activate_employee'), isFalse);
    },
  );
  testWidgets('Arabic careers stays readable in narrow RTL layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: RecruitmentScreen(client: client(), gateway: FakeRecruitment()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('فرص العمل'), findsOneWidget);
    expect(find.text('التقديم دون حساب'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('فرص العمل'))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
  });
}
