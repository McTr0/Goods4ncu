import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/admin_role_cache.dart';

void main() {
  group('AdminRoleCache', () {
    setUp(() {
      AdminRoleCache.instance.invalidate();
    });

    test('returns null when token not cached', () {
      final cached = AdminRoleCache.instance.getCached('token-a');

      expect(cached, isNull);
    });

    test('returns cached value for same token', () {
      AdminRoleCache.instance.save('token-a', true);

      final cached = AdminRoleCache.instance.getCached('token-a');

      expect(cached, isTrue);
    });

    test('returns null for different token', () {
      AdminRoleCache.instance.save('token-a', false);

      final cached = AdminRoleCache.instance.getCached('token-b');

      expect(cached, isNull);
    });

    test('invalidate clears cache', () {
      AdminRoleCache.instance.save('token-a', true);

      AdminRoleCache.instance.invalidate();
      final cached = AdminRoleCache.instance.getCached('token-a');

      expect(cached, isNull);
    });
  });
}
