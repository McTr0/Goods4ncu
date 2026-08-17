import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/campus_errands_page.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

UserIntent _errand(
  String id,
  String subject, {
  String serviceDirection = 'wanted',
}) => UserIntent.fromJson({
  'id': id,
  'kind': 'help',
  'raw_input': subject,
  'slots': {
    'subject': subject,
    'service_direction': serviceDirection,
    'service_mode': 'pickup',
    'pickup_place': '前湖校区图书馆',
    'dropoff_place': '修贤广场',
  },
  'status': 'active',
  'valid_until': '2026-08-17T12:00:00Z',
});

class _FakeIntentService extends IntentService {
  String? completedId;
  String? withdrawnId;

  @override
  Future<List<UserIntent>> campusFeed({
    IntentKind? kind,
    int limit = 30,
  }) async => [
    _errand('campus-1', '帮我取打印材料'),
    _errand('campus-2', '今晚可以帮忙取快递', serviceDirection: 'offer'),
  ];

  @override
  Future<List<UserIntent>> myIntents() async => [_errand('mine-1', '帮我去驿站取件')];

  @override
  Future<void> fulfilIntent(String id) async {
    completedId = id;
  }

  @override
  Future<void> withdrawIntent(String id) async {
    withdrawnId = id;
  }
}

void main() {
  testWidgets('shows campus errands and manages my active errands', (
    tester,
  ) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CampusErrandsPage(intentService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('errand-board-card-campus-1')),
      findsOneWidget,
    );
    expect(find.text('帮我取打印材料'), findsOneWidget);
    expect(find.text('收服务'), findsOneWidget);
    expect(find.text('出服务'), findsOneWidget);
    expect(find.text('我需要这项服务'), findsOneWidget);

    await tester.tap(find.text('我的待办'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('errand-board-card-mine-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('errand-board-complete-mine-1')),
    );
    await tester.pumpAndSettle();
    expect(service.completedId, 'mine-1');

    await tester.tap(
      find.byKey(const ValueKey('errand-board-withdraw-mine-1')),
    );
    await tester.pumpAndSettle();
    expect(service.withdrawnId, 'mine-1');
  });
}
