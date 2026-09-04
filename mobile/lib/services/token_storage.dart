import 'package:flutter/foundation.dart' show kIsWeb;
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

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<String?> getAccessToken() async => _read(_jwtKey);

  Future<String?> getRefreshToken() async => _read(_refreshKey);

  Future<void> setAccessToken(String token) async {
    await _write(_jwtKey, token);
  }

  Future<void> setRefreshToken(String token) async {
    await _write(_refreshKey, token);
  }

  Future<void> removeRefreshToken() async {
    await _delete(_refreshKey);
  }

  Future<void> clearTokens() async {
    await _delete(_jwtKey);
    await _delete(_refreshKey);
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
}
