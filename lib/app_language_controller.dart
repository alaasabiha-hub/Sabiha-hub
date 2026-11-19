import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class AppLanguageStore {
  Future<String?> read();
  Future<void> write(String languageCode);
}

class SharedPreferencesAppLanguageStore implements AppLanguageStore {
  const SharedPreferencesAppLanguageStore();

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString('app_language');

  @override
  Future<void> write(String languageCode) async =>
      (await SharedPreferences.getInstance()).setString(
        'app_language',
        languageCode,
      );
}

/// Applies language changes immediately and serializes persistence so rapid
/// taps cannot leave an older locale as the saved preference.
class AppLanguageController extends ChangeNotifier {
  AppLanguageController({AppLanguageStore? store})
    : _store = store ?? const SharedPreferencesAppLanguageStore();

  final AppLanguageStore _store;
  Locale _locale = const Locale('ar');
  int _generation = 0;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  Locale get locale => _locale;
  String get languageCode => _locale.languageCode;

  Future<void> load() async {
    final generation = _generation;
    try {
      final saved = await _store.read();
      if (_disposed ||
          generation != _generation ||
          (saved != 'ar' && saved != 'en')) {
        return;
      }
      if (_locale.languageCode != saved) {
        _locale = Locale(saved!);
        notifyListeners();
      }
    } catch (_) {
      // Arabic is the default; a preference read failure must not block startup.
    }
  }

  Future<void> setLanguage(String languageCode) {
    if (_disposed || (languageCode != 'ar' && languageCode != 'en')) {
      return Future<void>.value();
    }
    final generation = ++_generation;
    if (_locale.languageCode != languageCode) {
      _locale = Locale(languageCode);
      notifyListeners();
    }
    _writes = _writes.then((_) async {
      if (!_disposed && generation == _generation) {
        try {
          await _store.write(languageCode);
        } catch (_) {
          // Keep the live locale usable even if local persistence is unavailable.
        }
      }
    });
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
