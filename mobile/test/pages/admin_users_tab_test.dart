import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/admin_page.dart';
import 'package:goods4ncu_mobile/services/admin_impersonation_service.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';

class _FakeApiService extends ApiService {
  _FakeApiService({required this.users});

  final List<Map<String, dynamic>> users;
  final List<String> banCalls = <String>[];
  final List<String> unbanCalls = <String>[];

  @override
  Future<Map<String, dynamic>> getAdminUsers({
    String? q,
    int limit = 20,
    int offset = 0,
  }) async {
    return <String, dynamic>{'users': users};
  }

  @override
  Future<void> banUser(String userId) async {
    banCalls.add(userId);
  }

  @override
  Future<void> unbanUser(String userId) async {
    unbanCalls.add(userId);
  }
}

class _FakeAdminImpersonationService extends AdminImpersonationService {
  _FakeAdminImpersonationService({this.shouldThrow = false})
    : super(gateway: _UnusedAdminImpersonationGateway());

  final bool shouldThrow;
  final List<String> calls = <String>[];

  @override
  Future<void> impersonate(String userId) async {
    calls.add(userId);
    if (shouldThrow) {
      throw Exception('impersonate failed');
    }
  }
}

class _UnusedAdminImpersonationGateway implements AdminImpersonationGateway {
  @override
  Future<String> fetchImpersonationToken(String userId) {
    throw StateError('Test fake overrides impersonate directly.');
  }
}

class _DelayedApiService extends ApiService {
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> getAdminUsers({
    String? q,
    int limit = 20,
    int offset = 0,
  }) {
    return completer.future;
  }
}

Widget _buildRouterApp(Widget child) {
  final router = GoRouter(
    initialLocation: '/admin-users',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('home-root'))),
      ),
      GoRoute(
        path: '/admin-users',
        builder: (context, state) => Scaffold(body: child),
      ),
    ],
  );

  return MaterialApp.router(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

Future<void> _searchUsers(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  group('AdminUsersTab', () {
    testWidgets('missing user id shows error and skips impersonation', (
      tester,
    ) async {
      final apiService = _FakeApiService(
        users: <Map<String, dynamic>>[
          <String, dynamic>{
            'username': 'Alice',
            'role': 'user',
            'status': 'active',
            'listing_count': 1,
            'created_at': '2026-03-01T08:00:00Z',
          },
        ],
      );
      final impersonationService = _FakeAdminImpersonationService();

      await tester.pumpWidget(
        _buildRouterApp(
          AdminUsersTab(
            apiService: apiService,
            impersonationService: impersonationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _searchUsers(tester, 'alice');
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      final l = AppLocalizations.of(
        tester.element(find.byType(Scaffold).first),
      )!;
      await tester.tap(find.widgetWithText(OutlinedButton, l.adminLoginAs));
      await tester.pumpAndSettle();

      expect(impersonationService.calls, isEmpty);
      expect(find.text(l.adminLoginAsFailed), findsOneWidget);
    });

    testWidgets('canceling impersonation dialog does not call service', (
      tester,
    ) async {
      final apiService = _FakeApiService(
        users: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'user-1',
            'username': 'Alice',
            'role': 'user',
            'status': 'active',
            'listing_count': 1,
            'created_at': '2026-03-01T08:00:00Z',
          },
        ],
      );
      final impersonationService = _FakeAdminImpersonationService();

      await tester.pumpWidget(
        _buildRouterApp(
          AdminUsersTab(
            apiService: apiService,
            impersonationService: impersonationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _searchUsers(tester, 'alice');
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      final l = AppLocalizations.of(
        tester.element(find.byType(Scaffold).first),
      )!;
      await tester.tap(find.widgetWithText(OutlinedButton, l.adminLoginAs));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, l.cancel));
      await tester.pumpAndSettle();

      expect(impersonationService.calls, isEmpty);
    });

    testWidgets('confirmed impersonation calls service and navigates home', (
      tester,
    ) async {
      final apiService = _FakeApiService(
        users: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'user-1',
            'username': 'Alice',
            'role': 'user',
            'status': 'active',
            'listing_count': 1,
            'created_at': '2026-03-01T08:00:00Z',
          },
        ],
      );
      final impersonationService = _FakeAdminImpersonationService();

      await tester.pumpWidget(
        _buildRouterApp(
          AdminUsersTab(
            apiService: apiService,
            impersonationService: impersonationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _searchUsers(tester, 'alice');
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      final l = AppLocalizations.of(
        tester.element(find.byType(Scaffold).first),
      )!;
      await tester.tap(find.widgetWithText(OutlinedButton, l.adminLoginAs));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, l.adminLoginAsConfirm),
        ),
      );
      await tester.pumpAndSettle();

      expect(impersonationService.calls, <String>['user-1']);
      expect(find.text('home-root'), findsOneWidget);
    });

    testWidgets('impersonation failure shows error snackbar', (tester) async {
      final apiService = _FakeApiService(
        users: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'user-2',
            'username': 'Bob',
            'role': 'user',
            'status': 'active',
            'listing_count': 0,
            'created_at': '2026-03-02T08:00:00Z',
          },
        ],
      );
      final impersonationService = _FakeAdminImpersonationService(
        shouldThrow: true,
      );

      await tester.pumpWidget(
        _buildRouterApp(
          AdminUsersTab(
            apiService: apiService,
            impersonationService: impersonationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _searchUsers(tester, 'bob');
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();

      final l = AppLocalizations.of(
        tester.element(find.byType(Scaffold).first),
      )!;
      await tester.tap(find.widgetWithText(OutlinedButton, l.adminLoginAs));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, l.adminLoginAsConfirm),
        ),
      );
      await tester.pumpAndSettle();

      expect(impersonationService.calls, <String>['user-2']);
      expect(find.textContaining('Impersonation failed'), findsOneWidget);
      expect(find.text('home-root'), findsNothing);
    });

    testWidgets('disposing tab during pending search does not throw', (
      tester,
    ) async {
      final apiService = _DelayedApiService();

      await tester.pumpWidget(
        _buildRouterApp(
          AdminUsersTab(
            apiService: apiService,
            impersonationService: _FakeAdminImpersonationService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'alice');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      apiService.completer.complete(<String, dynamic>{'users': <dynamic>[]});
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
