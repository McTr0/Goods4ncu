import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:good4ncu_mobile/l10n/app_localizations.dart';
import 'package:good4ncu_mobile/pages/profile_page.dart';
import 'package:good4ncu_mobile/services/api_service.dart';

class _FakeApiService extends ApiService {
  _FakeApiService(this.profile);

  final Map<String, dynamic> profile;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => profile;
}

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('ProfilePage', () {
    testWidgets('hides admin console for normal users', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          ProfilePage(
            apiService: _FakeApiService({
              'username': 'buyer1',
              'role': 'user',
              'created_at': '2026-03-01T08:00:00Z',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text(l.adminConsole), findsNothing);
      expect(find.text(l.myListings), findsOneWidget);
      expect(find.text(l.myOrders), findsNothing);
    });

    testWidgets('shows admin console for admin users', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          ProfilePage(
            apiService: _FakeApiService({
              'username': 'admin',
              'role': 'admin',
              'created_at': '2026-03-01T08:00:00Z',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text(l.adminConsole), findsOneWidget);
    });
  });
}
