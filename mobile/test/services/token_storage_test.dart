import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TokenStorage', () {
    late TokenStorage storage;
    final secureValues = <String, String>{};

    setUp(() {
      secureValues.clear();
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (MethodCall methodCall) async {
          final args = methodCall.arguments as Map<dynamic, dynamic>?;
          if (methodCall.method == 'read') {
            return secureValues[args?['key']];
          } else if (methodCall.method == 'write') {
            if (args != null && args['key'] != null) {
              secureValues[args['key'].toString()] = args['value'].toString();
            }
            return null;
          } else if (methodCall.method == 'delete') {
            if (args != null && args['key'] != null) {
              secureValues.remove(args['key'].toString());
            }
            return null;
          } else if (methodCall.method == 'deleteAll') {
            secureValues.clear();
            return null;
          }
          return null;
        },
      );

      storage = TokenStorage.instance;
      storage.resetMigrationCheckForTesting();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
    });

    test('getAccessToken and setAccessToken work properly', () async {
      expect(await storage.getAccessToken(), isNull);

      await storage.setAccessToken('test_access_token');
      expect(await storage.getAccessToken(), 'test_access_token');
    });

    test('getRefreshToken and setRefreshToken work properly', () async {
      expect(await storage.getRefreshToken(), isNull);

      await storage.setRefreshToken('test_refresh_token');
      expect(await storage.getRefreshToken(), 'test_refresh_token');
    });

    test('removeRefreshToken removes only refresh token', () async {
      await storage.setAccessToken('access_123');
      await storage.setRefreshToken('refresh_456');

      await storage.removeRefreshToken();
      expect(await storage.getRefreshToken(), isNull);
      expect(await storage.getAccessToken(), 'access_123');
    });

    test('clearTokens removes both access and refresh tokens', () async {
      await storage.setAccessToken('access_123');
      await storage.setRefreshToken('refresh_456');

      await storage.clearTokens();
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
    });

    test('migration guard migrates legacy SharedPreferences on first read', () async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'legacy_jwt',
        'refresh_token': 'legacy_refresh',
      });
      storage.resetMigrationCheckForTesting();

      // First read triggers migration
      final token = await storage.getAccessToken();
      expect(token, 'legacy_jwt');
      expect(await storage.getRefreshToken(), 'legacy_refresh');

      // Secure storage now has the migrated values
      expect(secureValues['jwt_token'], 'legacy_jwt');
      expect(secureValues['refresh_token'], 'legacy_refresh');

      // SharedPreferences should have been cleaned up
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('jwt_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });
  });
}
