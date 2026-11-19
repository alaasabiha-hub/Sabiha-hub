import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiha_hub/app_language_controller.dart';

class MemoryLanguageStore implements AppLanguageStore {
  String? value;
  final List<String> writes = [];
  Completer<String?>? pendingRead;
  Completer<void>? firstWrite;

  @override
  Future<String?> read() => pendingRead?.future ?? Future.value(value);

  @override
  Future<void> write(String languageCode) async {
    writes.add(languageCode);
    if (writes.length == 1 && firstWrite != null) await firstWrite!.future;
    value = languageCode;
  }
}

void main() {
  test(
    'applies repeated language toggles immediately and persists latest',
    () async {
      final store = MemoryLanguageStore();
      final controller = AppLanguageController(store: store);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final first = controller.setLanguage('en');
      final second = controller.setLanguage('ar');
      final third = controller.setLanguage('en');
      expect(controller.languageCode, 'en');
      await Future.wait([first, second, third]);

      expect(controller.languageCode, 'en');
      expect(store.value, 'en');
      expect(notifications, 3);
      controller.dispose();
    },
  );

  test(
    'a delayed old preference cannot overwrite a user language change',
    () async {
      final store = MemoryLanguageStore()..pendingRead = Completer<String?>();
      final controller = AppLanguageController(store: store);
      final loading = controller.load();
      await controller.setLanguage('en');
      store.pendingRead!.complete('ar');
      await loading;

      expect(controller.languageCode, 'en');
      expect(store.value, 'en');
      controller.dispose();
    },
  );

  test('unsupported locale is ignored', () async {
    final store = MemoryLanguageStore();
    final controller = AppLanguageController(store: store);
    await controller.setLanguage('fr');
    expect(controller.languageCode, 'ar');
    expect(store.writes, isEmpty);
    controller.dispose();
  });

  test('a pending preference read is ignored after the root is disposed', () async {
    final store = MemoryLanguageStore()..pendingRead = Completer<String?>();
    final controller = AppLanguageController(store: store);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final loading = controller.load();
    controller.dispose();
    store.pendingRead!.complete('en');
    await loading;

    expect(notifications, 0);
    expect(controller.languageCode, 'ar');
  });
}
