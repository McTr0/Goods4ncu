import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
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
  SocialPersona? persona;
  String? switchedCampusId;
  int verificationRequests = 0;
  String? confirmedCode;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => profile;

  @override
  Future<SocialPersona?> getSocialPersona() async => persona;

  @override
  Future<SocialPersonaCatalog> getSocialPersonaCatalog() async =>
      const SocialPersonaCatalog(
        styleVersion: 'v1',
        representationModes: ['trait_mapped', 'role_character'],
        appearance: {
          'palette': ['teal', 'plum', 'sun', 'slate'],
          'silhouette': ['soft', 'round', 'sharp'],
          'accessory': ['none', 'glasses', 'headphones', 'leaf'],
          'outfit': ['campus', 'workwear', 'casual', 'lab'],
        },
        selfDescriptions: [
          'slow_to_warm',
          'business_only',
          'meetup_friendly',
          'casual_chat',
          'reply_later',
          'tech_enthusiast',
        ],
        contactPostures: [
          'leave_message',
          'connection_allowed',
          'busy',
          'later',
        ],
      );

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
  });
}
