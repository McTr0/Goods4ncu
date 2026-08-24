import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/my_listings_page.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _RecordingUserService extends UserService {
  _RecordingUserService(this.items);

  final List<Map<String, dynamic>> items;
  String? requestedStatus;
  int? requestedLimit;
  int? requestedOffset;

  @override
  Future<Map<String, dynamic>> getUserListings({
    int limit = 20,
    int offset = 0,
    String? status,
  }) async {
    requestedStatus = status;
    requestedLimit = limit;
    requestedOffset = offset;
    return {
      'items': items,
      'total': items.length,
      'limit': limit,
      'offset': offset,
    };
  }
}

Map<String, dynamic> _listing({
  required String id,
  required String title,
  required String status,
  String direction = 'offer',
  String? restrictionState,
  List<String>? availableActions,
}) {
  return {
    'id': id,
    'title': title,
    'category': 'other',
    'brand': 'NCU',
    'direction': direction,
    'condition_score': 8,
    'suggested_price_cny': 25,
    'status': status,
    'restriction_state': ?restrictionState,
    'available_actions': ?availableActions,
  };
}

Widget _app(_RecordingUserService service) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => MyListingsPage(userService: service),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Scaffold(body: Text('detail-${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/my-listings/new',
        builder: (context, state) =>
            const Scaffold(body: Text('structured-create')),
      ),
    ],
  );
  return MaterialApp.router(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

void main() {
  testWidgets('requests all listings and keeps fulfilled wanted reopenable', (
    tester,
  ) async {
    final service = _RecordingUserService([
      _listing(
        id: 'wanted-fulfilled',
        title: '想收一辆自行车',
        status: 'fulfilled',
        direction: 'wanted',
      ),
      _listing(id: 'offer-active', title: '高数教材', status: 'active'),
    ]);

    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(service.requestedStatus, 'all');
    expect(service.requestedLimit, 100);
    expect(service.requestedOffset, 0);
    expect(find.text('想收一辆自行车'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('listing-status-wanted-fulfilled')),
      findsOneWidget,
    );
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('重新开启需求'), findsNothing);

    await tester.tap(find.text('想收一辆自行车'));
    await tester.pumpAndSettle();
    expect(find.text('detail-wanted-fulfilled'), findsOneWidget);
  });

  testWidgets('empty CTA opens the structured listing form', (tester) async {
    final service = _RecordingUserService([]);

    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    final action = find.byKey(
      const ValueKey('my-listings-empty-create-action'),
    );
    expect(action, findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('structured-create'), findsOneWidget);
  });

  testWidgets('renders lifecycle and moderation as separate badges', (
    tester,
  ) async {
    final service = _RecordingUserService([
      _listing(
        id: 'restricted-deleted',
        title: '受限发布',
        status: 'deleted',
        restrictionState: 'restricted',
        availableActions: const [],
      ),
    ]);

    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('listing-status-restricted-deleted')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('listing-restriction-restricted-deleted')),
      findsOneWidget,
    );
    expect(find.text('已由你删除'), findsOneWidget);
    expect(find.text('已被审核限制'), findsOneWidget);
    expect(find.textContaining('重新'), findsNothing);
  });

  testWidgets('app bar always exposes the structured listing form', (
    tester,
  ) async {
    final service = _RecordingUserService([
      _listing(id: 'offer-1', title: '台灯', status: 'active'),
    ]);

    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('my-listings-create-action'));
    expect(action, findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('structured-create'), findsOneWidget);
  });
}
