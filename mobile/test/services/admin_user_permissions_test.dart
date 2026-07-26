import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/admin_user_permissions.dart';

void main() {
  group('canAdminImpersonateUser', () {
    test('returns true for active non-admin user', () {
      final allowed = canAdminImpersonateUser({
        'role': 'user',
        'status': 'active',
      });

      expect(allowed, isTrue);
    });

    test('returns false for admin user', () {
      final allowed = canAdminImpersonateUser({
        'role': 'admin',
        'status': 'active',
      });

      expect(allowed, isFalse);
    });

    test('returns false for banned status', () {
      final allowed = canAdminImpersonateUser({
        'role': 'user',
        'status': 'banned',
      });

      expect(allowed, isFalse);
    });

    test('returns false when legacy is_banned flag is true', () {
      final allowed = canAdminImpersonateUser({
        'role': 'user',
        'status': 'active',
        'is_banned': true,
      });

      expect(allowed, isFalse);
    });

    test('normalizes role and status case-insensitively', () {
      final allowed = canAdminImpersonateUser({
        'role': 'USER',
        'status': 'ACTIVE',
      });

      expect(allowed, isTrue);
    });

    test('returns false when role is missing', () {
      final allowed = canAdminImpersonateUser({'status': 'active'});

      expect(allowed, isFalse);
    });

    test('returns false when status is missing', () {
      final allowed = canAdminImpersonateUser({'role': 'user'});

      expect(allowed, isFalse);
    });

    test('returns false for non-active status', () {
      final allowed = canAdminImpersonateUser({
        'role': 'user',
        'status': 'pending',
      });

      expect(allowed, isFalse);
    });
  });
}
