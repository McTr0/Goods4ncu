import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocaleService {
  static const _localeKey = 'locale';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static Locale getStoredLocale() {
    final code = _prefs?.getString(_localeKey);
    if (code == null || code.isEmpty || (code != 'zh' && code != 'en')) {
      return const Locale('zh');
    }
    return Locale(code);
  }

  static Future<void> setLocale(Locale locale) async {
    await _prefs?.setString(_localeKey, locale.languageCode);
  }
}

class LocaleNotifier extends ChangeNotifier {
  Locale _locale;

  LocaleNotifier() : _locale = LocaleService.getStoredLocale();

  Locale get locale => _locale;

  Future<void> setLocale(Locale locale) async {
    if (_locale != locale) {
      _locale = locale;
      await LocaleService.setLocale(locale);
      notifyListeners();
    }
  }
}

class LocaleProvider extends InheritedWidget {
  final LocaleNotifier notifier;

  const LocaleProvider({
    super.key,
    required this.notifier,
    required super.child,
  });

  @override
  bool updateShouldNotify(LocaleProvider oldWidget) {
    return notifier.locale != oldWidget.notifier.locale;
  }
}

extension LocaleBuildContext on BuildContext {
  LocaleNotifier localeNotifier() {
    final provider = dependOnInheritedWidgetOfExactType<LocaleProvider>();
    return provider!.notifier;
  }
}
