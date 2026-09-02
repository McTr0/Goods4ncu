import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Conditional import: only pull in flutter_secure_storage on non-web.
import 'token_storage_secure_stub.dart'
    if (dart.library.io) 'token_storage_secure_io.dart';

/// Secure token storage.
///
/// - **iOS / Android**: uses `FlutterSecureStorage` (keychain / encrypted prefs).
/// - **Web**: falls back to `SharedPreferences` (localStorage) because
///   `flutter_secure_storage` plugin channels are unavailable on web.
class TokenStorage {
  TokenStorage._();

  static final TokenStorage instance = TokenStorage._();

  static const _jwtKey = 'jwt_token';
  static const _refreshKey = 'refresh_token';

  bool _migrationChecked = false;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> _ensureMigrated() async {
    if (kIsWeb || _migrationChecked) return;
    _migrationChecked = true;
    await _migrateLegacyKeyIfNeeded(_jwtKey);
    await _migrateLegacyKeyIfNeeded(_refreshKey);
  }

  Future<String?> getAccessToken() async {
    await _ensureMigrated();
    return _read(_jwtKey);
  }

  Future<String?> getRefreshToken() async {
    await _ensureMigrated();
    return _read(_refreshKey);
  }

  Future<void> setAccessToken(String token) async {
    await _write(_jwtKey, token);
  }

  Future<void> setRefreshToken(String token) async {
    await _write(_refreshKey, token);
  }

  Future<void> removeRefreshToken() async {
    await _delete(_refreshKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_refreshKey);
  }

  Future<void> clearTokens() async {
    await _delete(_jwtKey);
    await _delete(_refreshKey);

    // Cleanup any legacy plaintext leftovers.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_jwtKey);
    await prefs.remove(_refreshKey);
  }

  // ---------------------------------------------------------------------------
  // Platform-adaptive storage backend
  // ---------------------------------------------------------------------------

  Future<String?> _read(String key) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
    return secureRead(key);
  }

  Future<void> _write(String key, String value) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
      return;
    }
    await secureWrite(key, value);
  }

  Future<void> _delete(String key) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      return;
    }
    await secureDelete(key);
  }

  // ---------------------------------------------------------------------------
  // Migration: SharedPreferences → secure storage (native only)
  // ---------------------------------------------------------------------------

  Future<void> _migrateLegacyKeyIfNeeded(String key) async {
    if (kIsWeb) return; // No migration needed on web.

    final secureValue = await secureRead(key);
    if (secureValue != null && secureValue.isNotEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final legacyValue = prefs.getString(key);
    if (legacyValue == null || legacyValue.isEmpty) {
      return;
    }

    await secureWrite(key, legacyValue);
    await prefs.remove(key);
  }

  @visibleForTesting
  void resetMigrationCheckForTesting() {
    _migrationChecked = false;
  }
}
