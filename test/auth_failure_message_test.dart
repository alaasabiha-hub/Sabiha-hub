import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/main.dart';

void main() {
  test('invalid credentials are distinguished from connection failures', () {
    expect(
      authFailureMessage(
        languageCode: 'en',
        message: 'Invalid login credentials',
        statusCode: '400',
      ),
      'The email or password is incorrect.',
    );
    expect(
      authFailureMessage(
        languageCode: 'ar',
        message: 'Failed to resolve host: name resolution failed',
      ),
      contains('تعذر الاتصال بخدمة تسجيل الدخول'),
    );
  });

  test('profile errors are not mislabeled as network failures', () {
    expect(
      authFailureMessage(
        languageCode: 'en',
        message: 'Exception: Customer profile was not found. Please contact support.',
      ),
      'Customer profile was not found. Please contact support.',
    );
  });

  test('email delivery errors are specific and localized', () {
    expect(
      authEmailFailureMessage(
        languageCode: 'en',
        message: 'email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ),
      contains('reached its email sending limit'),
    );
    expect(
      authEmailFailureMessage(
        languageCode: 'ar',
        message: 'email rate limit exceeded',
        statusCode: '429',
        code: 'over_email_send_rate_limit',
      ),
      contains('بلغ إرسال البريد الحد الحالي'),
    );
    expect(
      authEmailFailureMessage(
        languageCode: 'en',
        message: 'Email address not authorized',
        statusCode: '403',
        code: 'email_address_not_authorized',
      ),
      contains('custom SMTP provider'),
    );
    expect(
      authEmailFailureMessage(
        languageCode: 'en',
        message: 'Too many requests',
        statusCode: '429',
        code: 'over_request_rate_limit',
      ),
      contains('Wait one minute'),
    );
  });
}
