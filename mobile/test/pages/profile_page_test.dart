import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/profile_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

class _FakeApiService extends ApiService {
  _FakeApiService(
    this.profile, {
    this.memberships = const [],
    String? activeCampusId,
  }) : activeCampusId =
           activeCampusId ??
           (memberships.isEmpty ? null : memberships.first.campusId);

  final Map<String, dynamic> profile;
  List<CampusMembership> memberships;
  String? activeCampusId;
  String? switchedCampusId;
  int verificationRequests = 0;
  String? confirmedCode;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => profile;

  @override
  Future<List<CampusMembership>> getCampusMemberships() async => memberships;

  @override
  Future<CampusMembershipState> getCampusMembershipState() async =>
      CampusMembershipState(items: memberships, activeCampusId: activeCampusId);

  @override
  Future<String> switchActiveCampus(String campusId) async {
    switchedCampusId = campusId;
    activeCampusId = campusId;
    return 'new-access-token';
  }

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
    final current = memberships.first;
    final verified = CampusMembership(
      id: current.id,
      campusId: current.campusId,
      campusSlug: current.campusSlug,
      campusNameZh: current.campusNameZh,
      campusNameEn: current.campusNameEn,
      status: 'verified',
      role: current.role,
    );
    memberships = [verified];
    return verified;
  }
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

    testWidgets('shows the current campus membership state', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          ProfilePage(
            apiService: _FakeApiService(
              {
                'username': 'student',
                'role': 'user',
                'created_at': '2026-03-01T08:00:00Z',
              },
              memberships: const [
                CampusMembership(
                  id: 'membership-1',
                  campusId: 'campus-1',
                  campusSlug: 'ncu',
                  campusNameZh: '南昌大学',
                  campusNameEn: 'Nanchang University',
                  status: 'verified',
                  role: 'member',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      expect(find.text('南昌大学'), findsOneWidget);
      expect(find.text(l.campusMembershipVerified), findsOneWidget);
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
    });

    testWidgets('pending membership completes the verification dialog flow', (
      tester,
    ) async {
      final api = _FakeApiService(
        {
          'username': 'new-student',
          'role': 'user',
          'created_at': '2026-03-01T08:00:00Z',
        },
        memberships: const [
          CampusMembership(
            id: 'membership-pending',
            campusId: 'campus-1',
            campusSlug: 'ncu',
            campusNameZh: '南昌大学',
            campusNameEn: 'Nanchang University',
            status: 'pending',
            role: 'member',
          ),
        ],
      );
      await tester.pumpWidget(_buildTestApp(ProfilePage(apiService: api)));
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

      await tester.tap(find.text(l.campusMembershipPending));
      await tester.pumpAndSettle();
      expect(find.text(l.sendVerificationCode), findsOneWidget);

      await tester.tap(find.text(l.sendVerificationCode));
      await tester.pumpAndSettle();
      expect(api.verificationRequests, 1);
      expect(find.text(l.verificationCode), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text(l.confirmVerification));
      await tester.pumpAndSettle();

      expect(api.confirmedCode, '123456');
      expect(find.text(l.campusMembershipVerified), findsOneWidget);
    });

    testWidgets('switches the active campus when multiple memberships exist', (
      tester,
    ) async {
      final api = _FakeApiService(
        {
          'username': 'multi-campus-student',
          'role': 'user',
          'created_at': '2026-03-01T08:00:00Z',
        },
        activeCampusId: 'campus-1',
        memberships: const [
          CampusMembership(
            id: 'membership-1',
            campusId: 'campus-1',
            campusSlug: 'ncu',
            campusNameZh: '南昌大学',
            campusNameEn: 'Nanchang University',
            status: 'verified',
            role: 'member',
          ),
          CampusMembership(
            id: 'membership-2',
            campusId: 'campus-2',
            campusSlug: 'second',
            campusNameZh: '第二校园',
            campusNameEn: 'Second Campus',
            status: 'verified',
            role: 'member',
          ),
        ],
      );
      await tester.pumpWidget(_buildTestApp(ProfilePage(apiService: api)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('南昌大学'));
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
      expect(find.text(l.campusSwitchTitle), findsOneWidget);
      expect(find.text(l.campusActive), findsOneWidget);

      await tester.tap(find.text('第二校园'));
      await tester.pumpAndSettle();

      expect(api.switchedCampusId, 'campus-2');
      expect(find.text('第二校园'), findsOneWidget);
      expect(find.text(l.campusSwitchSuccess), findsOneWidget);
    });
  });
}
