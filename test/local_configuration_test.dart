import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_config.dart';
import 'package:sabiha_hub/workflow.dart';

void main() {
  test('local app never accepts a hosted database URL', () {
    expect(
      AppConfig.validate(url: 'https://production.supabase.co', key: 'public'),
      isNotNull,
    );
    expect(
      AppConfig.validate(url: 'http://127.0.0.1:54321', key: 'local-anon'),
      isNull,
    );
    expect(
      AppConfig.validate(url: 'http://10.0.2.2:54321', key: 'local-anon'),
      isNull,
    );
    expect(
      AppConfig.validate(url: 'http://localhost.evil.example', key: 'public'),
      isNotNull,
    );
    expect(
      AppConfig.validate(url: 'http://localhost:54321', key: 'sb_secret_test'),
      isNotNull,
    );
    expect(
      AppConfig.validate(url: 'http://localhost:54321', key: ''),
      isNotNull,
    );
    final secretClaims = base64Url
        .encode(utf8.encode('{"role":"service_role"}'))
        .replaceAll('=', '');
    expect(
      AppConfig.validate(
        url: 'http://localhost:54321',
        key: 'header.$secretClaims.signature',
      ),
      isNotNull,
    );
  });
  test('staging requires explicit opt-in and a hosted QA URL', () {
    expect(
      AppConfig.validate(
        url: 'https://qa-project.supabase.co',
        key: 'sb_publishable_qa',
        appEnvironment: 'staging',
      ),
      isNotNull,
    );
    expect(
      AppConfig.validate(
        url: 'https://qa-project.supabase.co',
        key: 'sb_publishable_qa',
        appEnvironment: 'staging',
        remoteStagingAllowed: true,
      ),
      isNull,
    );
    expect(
      AppConfig.validate(
        url: 'https://qa-project.supabase.co.evil.example',
        key: 'sb_publishable_qa',
        appEnvironment: 'staging',
        remoteStagingAllowed: true,
      ),
      isNotNull,
    );
    expect(
      AppConfig.validate(
        url: 'http://qa-project.supabase.co',
        key: 'sb_publishable_qa',
        appEnvironment: 'staging',
        remoteStagingAllowed: true,
      ),
      isNotNull,
    );
    expect(
      AppConfig.validate(
        url: 'https://qa-project.supabase.co',
        key: 'sb_secret_do_not_use',
        appEnvironment: 'staging',
        remoteStagingAllowed: true,
      ),
      isNotNull,
    );
    expect(
      AppConfig.validate(
        url: 'https://qa-project.supabase.co',
        key: 'server-key',
        appEnvironment: 'staging',
        remoteStagingAllowed: true,
      ),
      isNotNull,
    );
  });
  test('past appointments are rejected but later appointments accepted', () {
    final now = DateTime(2026, 11, 12, 15, 30);
    expect(isFutureBooking(now, 15, 29, now), isFalse);
    expect(isFutureBooking(now, 15, 30, now), isFalse);
    expect(isFutureBooking(now, 15, 31, now), isTrue);
    expect(isFutureBooking(DateTime(2026, 11, 13), 10, 0, now), isTrue);
  });
  test('document expiry compares calendar dates including DST boundaries', () {
    expect(
      documentDaysRemaining('2026-11-12', DateTime(2026, 11, 12, 23, 59)),
      0,
    );
    expect(documentDaysRemaining('2026-11-11', DateTime(2026, 11, 12)), -1);
    expect(documentDaysRemaining('2026-11-19', DateTime(2026, 11, 12)), 7);
    expect(documentDaysRemaining(null, DateTime(2026, 11, 12)), isNull);
  });
  test('completed and cancelled bookings cannot be reopened', () {
    expect(bookingTransitions['completed'], isEmpty);
    expect(bookingTransitions['cancelled'], isEmpty);
    expect(bookingTransitions['pending'], isNot(contains('completed')));
  });
  test('email OTP validation supports local six-digit and existing eight-digit codes', () {
    expect(isValidEmailOtp('123456'), isTrue);
    expect(isValidEmailOtp('12345678'), isTrue);
    expect(isValidEmailOtp('12345'), isFalse);
    expect(isValidEmailOtp('12ab56'), isFalse);
  });
}
