import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/cubism/cubism_body.dart';

/// Owns the user's companion character choice.
///
/// The selection persists in shared preferences and is applied to the Cubism
/// runtime immediately, so an open chat stage re-renders with the new model
/// on the next frame. Only characters present in
/// [availableCompanionCharacters] (i.e. with a shipped model) are accepted.
class CompanionCharacterService extends ChangeNotifier {
  CompanionCharacterService._();

  static CompanionCharacterService _instance = CompanionCharacterService._();
  static CompanionCharacterService get instance => _instance;

  /// Swaps in a fresh instance for test isolation.
  @visibleForTesting
  static void resetForTest() => _instance = CompanionCharacterService._();

  static const String _prefsKey = 'companion.character';

  /// Characters the user may pick from (mirrors the shipped-model catalog).
  List<String> get availableCharacters => availableCompanionCharacters;

  String _character = kCompanionCharacter;
  bool _loaded = false;

  String get character => _character;

  /// Loads the persisted selection once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      if (stored != null &&
          availableCompanionCharacters.contains(stored) &&
          stored != _character) {
        _character = stored;
        setRuntimeCompanionCharacter(_character);
        notifyListeners();
      }
    } catch (_) {
      // Persistence failures never block the default character.
    }
  }

  /// Selects a character, applies it to the runtime, and persists it.
  Future<void> select(String character) async {
    if (!availableCompanionCharacters.contains(character)) return;
    if (character == _character) return;
    _character = character;
    setRuntimeCompanionCharacter(character);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, character);
    } catch (_) {}
  }
}
