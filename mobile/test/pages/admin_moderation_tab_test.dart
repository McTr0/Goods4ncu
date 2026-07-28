import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/admin/admin_moderation_tab.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';

class _ModerationApiService extends ApiService {
  _ModerationApiService(this.moderationCase);

  final Map<String, dynamic> moderationCase;

  @override
  Future<Map<String, dynamic>> getAdminModerationCases({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async => {
    'cases': [moderationCase],
    'total': 1,
  };
}

Map<String, dynamic> _case({
  required String resourceType,
  required String status,
}) => {
  'id': 'case-$resourceType-$status',
  'resource_type': resourceType,
  'resource_id': 'resource-1',
  'source_type': 'user_report',
  'status': status,
  'public_reason': '等待审核',
  'created_at': '2026-07-28T12:00:00Z',
  'internal_details': <String, dynamic>{},
};

Widget _app(Map<String, dynamic> moderationCase, {Locale? locale}) =>
    MaterialApp(
      locale: locale ?? const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AdminModerationTab(
          apiService: _ModerationApiService(moderationCase),
          canReview: true,
        ),
      ),
    );

void main() {
  testWidgets(
    'listing report keeps review actions but routes enforcement away',
    (tester) async {
      await tester.pumpWidget(
        _app(_case(resourceType: 'listing', status: 'open')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('listing · user_report'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('moderation-managed-enforcement-hint')),
        findsOneWidget,
      );
      expect(
        find.text('如需下架商品或处置账号，请前往商品或用户管理标签页；这些操作会单独记录审计。'),
        findsOneWidget,
      );
      expect(find.text('开始复核'), findsOneWidget);
      expect(find.text('确认无违规'), findsOneWidget);
      expect(find.text('限制内容'), findsNothing);
      expect(find.text('恢复内容'), findsNothing);
    },
  );

  testWidgets(
    'user case never offers restore and explains the audited path in English',
    (tester) async {
      await tester.pumpWidget(
        _app(
          _case(resourceType: 'user', status: 'actioned'),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('user · user_report'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Use the Listings or Users management tab to take down a listing or act on an account. Those enforcement actions are audited separately.',
        ),
        findsOneWidget,
      );
      expect(find.text('Restrict content'), findsNothing);
      expect(find.text('Restore content'), findsNothing);
    },
  );
}
