import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_config.dart';

void main() {
  group('QA password recovery redirect', () {
    test('is enabled only for the explicit QA staging project', () {
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'staging',
          recoveryUrl: 'https://sabiha-hub-qa-password-reset.pages.dev/',
        ).toString(),
        'https://sabiha-hub-qa-password-reset.pages.dev/',
      );
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://cujfeqsuanwxobtupxaz.supabase.co',
          appEnvironment: 'staging',
          recoveryUrl: 'https://sabiha-hub-qa-password-reset.pages.dev/',
        ),
        isNull,
      );
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'production',
          recoveryUrl: 'https://sabiha-hub-qa-password-reset.pages.dev/',
        ),
        isNull,
      );
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'staging',
          recoveryUrl: 'http://localhost:8790',
        ),
        isNull,
      );
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'staging',
          recoveryUrl: 'https://attacker.pages.dev/',
        ),
        isNull,
      );
      expect(
        AppConfig.passwordRecoveryPageFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'staging',
          recoveryUrl:
              'https://sabiha-hub-qa-password-reset.pages.dev/untrusted-path',
        ),
        isNull,
      );
      expect(
        AppConfig.isQaStagingFor(
          url: 'https://aspijgoujajgyfgvdcav.supabase.co',
          appEnvironment: 'staging',
        ),
        isTrue,
      );
      expect(
        AppConfig.isQaStagingFor(
          url: 'https://cujfeqsuanwxobtupxaz.supabase.co',
          appEnvironment: 'staging',
        ),
        isFalse,
      );
    });
  });
}
