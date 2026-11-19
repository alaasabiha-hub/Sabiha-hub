import 'dart:convert';

class AppConfig {
  static const environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'local',
  );
  static const allowRemoteStaging = bool.fromEnvironment(
    'ALLOW_REMOTE_STAGING',
    defaultValue: false,
  );
  static const multiBranchEnabled = bool.fromEnvironment(
    'ENABLE_MULTI_BRANCH',
    defaultValue: false,
  );
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  static const _qaProjectHost = 'aspijgoujajgyfgvdcav.supabase.co';
  static const _qaPasswordRecoveryHost =
      'sabiha-hub-qa-password-reset.pages.dev';
  static const qaPasswordRecoveryUrl = String.fromEnvironment(
    'QA_PASSWORD_RECOVERY_URL',
    defaultValue: 'https://sabiha-hub-qa-password-reset.pages.dev/',
  );

  /// The QA recovery page is used only by builds explicitly targeting the
  /// dedicated QA project. Production and local Supabase builds keep their
  /// existing recovery flow.
  static Uri? passwordRecoveryPageFor({
    String url = supabaseUrl,
    String appEnvironment = environment,
    String recoveryUrl = qaPasswordRecoveryUrl,
  }) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    final recovery = Uri.tryParse(recoveryUrl);
    if (appEnvironment != 'staging' ||
        host != _qaProjectHost ||
        recovery == null ||
        recovery.scheme != 'https' ||
        recovery.host.toLowerCase() != _qaPasswordRecoveryHost ||
        (recovery.path.isNotEmpty && recovery.path != '/') ||
        recovery.hasPort ||
        recovery.userInfo.isNotEmpty ||
        recovery.hasQuery ||
        recovery.hasFragment) {
      return null;
    }
    return recovery;
  }

  static bool isQaStagingFor({
    String url = supabaseUrl,
    String appEnvironment = environment,
  }) =>
      appEnvironment == 'staging' &&
      Uri.tryParse(url)?.host.toLowerCase() == _qaProjectHost;

  static bool get isQaStaging => isQaStagingFor();

  static Uri? get qaPasswordRecoveryPage => passwordRecoveryPageFor();

  static String? validate({
    String url = supabaseUrl,
    String key = supabasePublishableKey,
    String appEnvironment = environment,
    bool remoteStagingAllowed = allowRemoteStaging,
  }) {
    final uri = Uri.tryParse(url);
    const localHosts = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.host.isEmpty) {
      return 'هذه نسخة تطوير محلية. استخدم عنوان Supabase المحلي.';
    }
    if (appEnvironment == 'local') {
      if (!localHosts.contains(uri.host)) {
        return 'هذه نسخة تطوير محلية. استخدم عنوان Supabase المحلي.';
      }
    } else if (appEnvironment == 'staging') {
      if (!remoteStagingAllowed ||
          uri.scheme != 'https' ||
          !uri.host.endsWith('.supabase.co') ||
          localHosts.contains(uri.host)) {
        return 'نسخة Staging تتطلب عنوان QA بعيدًا ومصرحًا به.';
      }
    } else {
      return 'بيئة التطبيق غير معروفة؛ تم إيقاف الاتصال بقاعدة البيانات.';
    }
    if (key.trim().isEmpty) {
      return appEnvironment == 'staging'
          ? 'أضف مفتاح Supabase Publishable الخاص ببيئة QA.'
          : 'أضف مفتاح Supabase المحلي إلى إعدادات التشغيل.';
    }
    if (appEnvironment == 'staging' && !_isPublishableClientKey(key)) {
      return 'استخدم مفتاح QA العام فقط؛ مفاتيح الخدمة مرفوضة.';
    }
    final segments = key.split('.');
    if (segments.length == 3) {
      try {
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
        );
        if (claims is Map && claims['role'] == 'service_role') {
          return 'استخدم مفتاح العميل العام فقط في التطبيق.';
        }
      } catch (_) {
        return 'مفتاح Supabase المحلي غير صالح.';
      }
    }
    if (key.startsWith('sb_secret_')) {
      return 'استخدم مفتاح العميل العام فقط في التطبيق.';
    }
    return null;
  }

  static bool _isPublishableClientKey(String key) {
    if (key.startsWith('sb_publishable_')) return true;
    if (key.startsWith('sb_secret_')) return false;
    final segments = key.split('.');
    if (segments.length != 3) return false;
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      return claims is Map && claims['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }
}
