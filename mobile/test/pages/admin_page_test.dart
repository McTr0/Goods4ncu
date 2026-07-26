import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/admin_page.dart';
import 'package:goods4ncu_mobile/services/admin_impersonation_service.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';

class _FakeApiService extends ApiService {
  bool unlocked = false;
  final List<String> reauthenticateCalls = <String>[];

  @override
  Future<Map<String, dynamic>> getAdminCapabilities() async {
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
  Future<DateTime?> reauthenticate(String password, {String? totpCode}) async {
    reauthenticateCalls.add(password);
    unlocked = true;
    return DateTime.now().add(const Duration(minutes: 10));
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

class _UnusedImpersonationGateway implements AdminImpersonationGateway {
  @override
  Future<String> fetchImpersonationToken(String userId) {
    throw StateError('Impersonation is not used by this test.');
  }
}

Widget _buildApp(_FakeApiService apiService) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AdminPage(
      apiService: apiService,
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
    final apiService = _FakeApiService();
    await tester.pumpWidget(_buildApp(apiService));
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

    expect(apiService.reauthenticateCalls, <String>['admin-password']);
    expect(find.text(l.adminSensitiveActionsLocked), findsNothing);
    expect(find.text(l.adminReauthenticateSuccess), findsOneWidget);
  });
}
