import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/admin/admin_listings_tab.dart';
import 'package:goods4ncu_mobile/services/admin_service.dart';

class _AdminListingsApi extends AdminService {
  _AdminListingsApi(this.items, {this.failAction = false});

  final List<Map<String, dynamic>> items;
  final bool failAction;
  int loadCalls = 0;
  final List<String> takedownCalls = [];
  final List<String> restoreCalls = [];
  final List<String> restoreReasons = [];

  @override
  Future<Map<String, dynamic>> getAdminListings({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    loadCalls += 1;
    return {'listings': items, 'total': items.length};
  }

  @override
  Future<void> takedownListing(String listingId) async {
    takedownCalls.add(listingId);
    if (failAction) throw Exception('offline');
  }

  @override
  Future<void> restoreListing(
    String listingId, {
    required String reason,
  }) async {
    restoreCalls.add(listingId);
    restoreReasons.add(reason);
    if (failAction) throw Exception('offline');
  }
}

Map<String, dynamic> _listing({
  required String id,
  String status = 'active',
  String restrictionState = 'clear',
  List<String>? adminActions,
}) => {
  'id': id,
  'title': 'Listing $id',
  'category': 'other',
  'brand': 'NCU',
  'direction': 'offer',
  'condition_score': 8,
  'suggested_price_cny': 20,
  'status': status,
  'owner_id': 'owner-1',
  'restricted': restrictionState == 'restricted',
  if (restrictionState == 'restricted') 'restriction_reason': 'policy',
  'available_admin_actions': ?adminActions,
};

Widget _app(_AdminListingsApi api, {bool canManage = true}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: AdminListingsTab(adminService: api, canManage: canManage),
  ),
);

void main() {
  testWidgets(
    'restricted listing remains inspectable and restores explicitly',
    (tester) async {
      final api = _AdminListingsApi([
        _listing(
          id: 'restricted-1',
          restrictionState: 'restricted',
          adminActions: const ['restore'],
        ),
      ]);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      expect(find.textContaining('已被审核限制'), findsOneWidget);
      await tester.tap(find.text('Listing restricted-1'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('admin-listing-restore-action')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin-listing-takedown-action')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('admin-listing-restore-action')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-listing-restore-reason')),
        'appeal approved',
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, '恢复发布'),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.restoreCalls, ['restricted-1']);
      expect(api.restoreReasons, ['appeal approved']);
      expect(api.takedownCalls, isEmpty);
      expect(api.loadCalls, 2);
    },
  );

  testWidgets('active listing uses authoritative takedown action', (
    tester,
  ) async {
    final api = _AdminListingsApi([
      _listing(id: 'active-1', adminActions: const ['takedown']),
    ]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listing active-1'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin-listing-takedown-action')),
      findsOneWidget,
    );
    expect(find.text('解封用户 (Unban)'), findsNothing);
  });

  testWidgets('missing or malformed admin actions fail closed', (tester) async {
    final api = _AdminListingsApi([_listing(id: 'legacy-1')]);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listing legacy-1'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin-listing-takedown-action')),
      findsNothing,
    );
    expect(find.byKey(const Key('admin-listing-restore-action')), findsNothing);
    expect(find.text('当前没有可执行的管理操作。'), findsOneWidget);
  });

  testWidgets('failed enforcement stays open with an actionable error', (
    tester,
  ) async {
    final api = _AdminListingsApi([
      _listing(id: 'active-fail', adminActions: const ['takedown']),
    ], failAction: true);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listing active-fail'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin-listing-takedown-action')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '强制下架 (Takedown)'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.takedownCalls, ['active-fail']);
    expect(find.byKey(const Key('admin-listing-action-error')), findsOneWidget);
    expect(
      find.byKey(const Key('admin-listing-takedown-action')),
      findsOneWidget,
    );
  });
}
