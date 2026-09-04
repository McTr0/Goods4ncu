import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/admin_page.dart';
import 'package:goods4ncu_mobile/services/admin_impersonation_service.dart';
import 'package:goods4ncu_mobile/services/admin_service.dart';
import 'package:goods4ncu_mobile/services/auth_service.dart';

class _FakeAdminService extends AdminService {
  bool unlocked = false;

  @override
  Future<Map<String, dynamic>> getCapabilities() async {
    return <String, dynamic>{
      'is_platform_admin': true,
      'can_read': true,
      'can_review': true,
      'recent_authentication_required': !unlocked,
      'recent_authentication_valid': unlocked,
      'recent_authentication_expires_at': unlocked
          ? DateTime.now().add(const Duration(minutes: 10)).toIso8601String()
          : null,
    };
  }

  @override
  Future<Map<String, dynamic>> getAdminStats() async {
    return <String, dynamic>{
      'total_listings': 0,
      'active_listings': 0,
      'total_users': 0,
      'total_orders': 0,
      'categories': <dynamic>[],
    };
  }
}

class _FakeAuthService extends AuthService {
  final _FakeAdminService adminService;
  final List<String> reauthenticateCalls = <String>[];

  _FakeAuthService(this.adminService);

  @override
  Future<DateTime?> reauthenticate(String password, {String? totpCode}) async {
    reauthenticateCalls.add(password);
    adminService.unlocked = true;
    return DateTime.now().add(const Duration(minutes: 10));
  }
}

class _UnusedImpersonationGateway implements AdminImpersonationGateway {
  @override
  Future<String> fetchImpersonationToken(String userId) {
    throw StateError('Impersonation is not used by this test.');
  }
}

Widget _buildApp(_FakeAdminService adminService, _FakeAuthService authService) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AdminPage(
      adminService: adminService,
      authService: authService,
      impersonationService: AdminImpersonationService(
        gateway: _UnusedImpersonationGateway(),
      ),
    ),
  );
}

void main() {
  testWidgets('sensitive admin actions unlock after password verification', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adminService = _FakeAdminService();
    final authService = _FakeAuthService(adminService);
    await tester.pumpWidget(_buildApp(adminService, authService));
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(AdminPage)))!;
    expect(find.text(l.adminSensitiveActionsLocked), findsOneWidget);
    expect(find.text(l.adminUnlockActions), findsOneWidget);

    await tester.tap(find.text(l.adminUnlockActions));
    await tester.pumpAndSettle();
    expect(find.text(l.adminReauthenticateTitle), findsOneWidget);

    // The unlock dialog now has two fields: password and optional TOTP code.
    await tester.enterText(find.byType(TextField).first, 'admin-password');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.adminUnlockActions),
      ),
    );
    await tester.pumpAndSettle();

    expect(authService.reauthenticateCalls, <String>['admin-password']);
    expect(find.text(l.adminSensitiveActionsLocked), findsNothing);
    expect(find.text(l.adminReauthenticateSuccess), findsOneWidget);
  });
}
