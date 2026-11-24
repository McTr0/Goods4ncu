import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/profile_page.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

class _FakeUserService extends UserService {
  _FakeUserService(
    this.profile, {
    this.memberships = const [],
    String? activeCampusId,
  }) : activeCampusId =
           activeCampusId ??
           (memberships.isEmpty ? null : memberships.first.campusId);

  final Map<String, dynamic> profile;
  List<CampusMembership> memberships;
  String? activeCampusId;
  SocialPersona? persona;
  String? switchedCampusId;
  int verificationRequests = 0;
  String? confirmedCode;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => profile;

  @override
  Future<SocialPersona?> getSocialPersona() async => persona;

  @override
  Future<CampusMembershipState> getCampusMembershipState() async =>
      CampusMembershipState(items: memberships, activeCampusId: activeCampusId);

  @override
  Future<void> requestCampusVerification(String membershipId) async {
    verificationRequests += 1;
  }

  @override
  Future<CampusMembership> confirmCampusVerification(
    String membershipId,
    String code,
  ) async {
    confirmedCode = code;
    memberships = [
      for (final m in memberships)
        m.id == membershipId ? _membership(status: 'verified', id: m.id) : m,
    ];
    return memberships.firstWhere((m) => m.id == membershipId);
  }
}

CampusMembership _membership({required String status, String id = 'm1'}) {
  return CampusMembership(
    id: id,
    campusId: 'c0000000-0000-0000-0000-000000000001',
    campusSlug: 'ncu',
    campusNameZh: '南昌大学',
    campusNameEn: 'Nanchang University',
    status: status,
    role: 'member',
  );
}

const _studentProfile = {
  'username': 'fresh_student',
  'role': 'user',
  'created_at': '2026-11-24T08:00:00Z',
};

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
            userService: _FakeUserService({
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
            userService: _FakeUserService({
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

    testWidgets('pending membership shows the campus verification entry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestApp(
          ProfilePage(
            userService: _FakeUserService(
              _studentProfile,
              memberships: [_membership(status: 'pending')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('profile-campus-verification')),
        findsOneWidget,
      );
    });

    testWidgets('verified membership hides the campus verification entry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestApp(
          ProfilePage(
            userService: _FakeUserService(
              _studentProfile,
              memberships: [_membership(status: 'verified')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('profile-campus-verification')),
        findsNothing,
      );
    });

    testWidgets('verification flow sends a code, confirms it and refreshes', (
      tester,
    ) async {
      final service = _FakeUserService(
        _studentProfile,
        memberships: [_membership(status: 'pending')],
      );
      await tester.pumpWidget(_buildTestApp(ProfilePage(userService: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile-campus-verification')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('campus-verification-send')));
      await tester.pumpAndSettle();
      expect(service.verificationRequests, 1);

      await tester.enterText(
        find.byKey(const Key('campus-verification-code')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('campus-verification-confirm')));
      await tester.pumpAndSettle();

      expect(service.confirmedCode, '123456');
      expect(
        find.byKey(const Key('profile-campus-verification')),
        findsNothing,
      );
    });
  });
}
