import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/handoff_prompt.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/user_home_page.dart';
import 'package:provider/provider.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/content_report_service.dart';
import 'package:goods4ncu_mobile/services/reputation_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

/// Whether a record kept is a record shown.
///
/// Phase F recorded handoffs faithfully and displayed them nowhere, which makes
/// it bookkeeping rather than trust. The place it has to appear is the profile
/// someone opens while deciding whether to deal with this person.

class _StubUserService extends UserService {
  _StubUserService({this.currentUserId = 'user-me'});

  final String? currentUserId;

  @override
  Future<String?> getToken() async => currentUserId == null ? null : 'token';

  @override
  Future<Map<String, dynamic>> getUserProfile() async {
    final id = currentUserId;
    if (id == null) throw Exception('not authenticated');
    return {'user_id': id, 'username': '当前用户'};
  }

  @override
  Future<Map<String, dynamic>> getPublicUserProfile(String userId) async => {
    'user_id': userId,
    'username': '同学A',
  };

  @override
  Future<Map<String, dynamic>> getPublicUserListings(
    String userId, {
    int limit = 20,
    int offset = 0,
  }) async => {'items': <dynamic>[]};
}

class _RecordingContentReportService extends ContentReportService {
  int userCalls = 0;
  String? userId;
  String? reason;
  String? details;

  @override
  Future<String> reportUser(
    String userId, {
    required String reason,
    String? details,
  }) async {
    userCalls += 1;
    this.userId = userId;
    this.reason = reason;
    this.details = details;
    return 'report-user-1';
  }
}

class _StubReputationService extends ReputationService {
  _StubReputationService(this.record);
  final Reputation? record;

  @override
  Future<Reputation> of(String userId) async {
    final value = record;
    if (value == null) throw Exception('unavailable');
    return value;
  }
}

Widget _app(
  Reputation? record, {
  String targetUserId = 'user-other',
  String? currentUserId = 'user-me',
  ContentReportService? contentReportService,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  // UserHomePage takes most collaborators as parameters; ChatService is the one
  // it still reads from context.
  home: Provider<ChatService>(
    create: (_) => ChatService(),
    child: UserHomePage(
      userId: targetUserId,
      userService: _StubUserService(currentUserId: currentUserId),
      reputationService: _StubReputationService(record),
      contentReportService:
          contentReportService ?? _RecordingContentReportService(),
    ),
  ),
);

void main() {
  testWidgets('a track record is shown where the decision is made', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Reputation(
          completed: 12,
          onTime: 11,
          missed: 0,
          hasTrackRecord: true,
          matchingWeight: 1.0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(UserHomePage)))!;
    expect(find.text(l.reputationSummary(12, 11)), findsOneWidget);
  });

  testWidgets('a newcomer reads as unmeasured rather than as a warning', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Reputation(
          completed: 0,
          onTime: 0,
          missed: 0,
          hasTrackRecord: false,
          matchingWeight: 0.5,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(UserHomePage)))!;
    expect(find.text(l.reputationNewcomer), findsOneWidget);
  });

  testWidgets('a failed lookup costs the line, not the profile', (
    tester,
  ) async {
    // A profile that will not open because a reputation call failed is a much
    // worse outcome than a profile without the line.
    await tester.pumpWidget(_app(null));
    await tester.pumpAndSettle();

    expect(find.text('同学A'), findsWidgets);
    expect(find.byType(ReputationLine), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another user can be reported from the public profile', (
    tester,
  ) async {
    final reports = _RecordingContentReportService();
    await tester.pumpWidget(
      _app(
        null,
        targetUserId: 'user-other',
        currentUserId: 'user-me',
        contentReportService: reports,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user-report-action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('user-report-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('举报此用户'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('content-report-reason')),
      '疑似冒充他人',
    );
    await tester.tap(find.byKey(const Key('content-report-submit')));
    await tester.pumpAndSettle();

    expect(reports.userCalls, 1);
    expect(reports.userId, 'user-other');
    expect(reports.reason, '疑似冒充他人');
    expect(reports.details, isNull);
    expect(find.text('已提交举报'), findsOneWidget);
  });

  testWidgets('the public profile never offers self-reporting', (tester) async {
    await tester.pumpWidget(
      _app(null, targetUserId: 'user-me', currentUserId: 'user-me'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user-report-action')), findsNothing);
  });

  testWidgets(
    'a guest can browse without being redirected for identity lookup',
    (tester) async {
      await tester.pumpWidget(
        _app(null, targetUserId: 'user-other', currentUserId: null),
      );
      await tester.pumpAndSettle();

      expect(find.text('同学A'), findsWidgets);
      expect(find.byKey(const Key('user-report-action')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
