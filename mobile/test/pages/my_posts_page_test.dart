import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/my_posts_page.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakePostService extends PostService {
  final List<String> deletedIds = [];

  @override
  Future<void> deletePost(String id) async {
    deletedIds.add(id);
  }

  @override
  Future<Map<String, dynamic>> getUserPosts({
    String status = 'all',
    int limit = 100,
  }) async {
    return {
      'items': [
        _discussionFixture(),
        _listingFixture(),
      ],
    };
  }
}

class _FakeListingService extends ListingService {
  final List<String> deletedListingIds = [];

  @override
  Future<void> deleteListing(
    String id, {
    int? expectedContentRevision,
  }) async {
    deletedListingIds.add(id);
  }
}

Map<String, dynamic> _discussionFixture() => {
  'id': 'discussion-1',
  'category': 'discussion',
  'title': '毕业搬家攻略',
  'author': {'id': 'u-1', 'username': 'mira'},
  'reply_count': 0,
  'status': 'active',
  'is_locked': false,
};

Map<String, dynamic> _listingFixture() => {
  'id': 'offer-1',
  'category': 'offer',
  'title': '出二手显示器',
  'listing_id': 'listing-123',
  'author': {'id': 'u-1', 'username': 'mira'},
  'reply_count': 0,
  'status': 'active',
  'is_locked': false,
};

Widget _app({
  required PostService postService,
  required ListingService listingService,
}) {
  final router = GoRouter(
    initialLocation: '/my-posts',
    routes: [
      GoRoute(
        path: '/my-posts',
        builder: (_, _) => MyPostsPage(
          postService: postService,
          listingService: listingService,
        ),
      ),
      GoRoute(path: '/posts/:id', builder: (_, _) => const Text('detail')),
    ],
  );
  return MaterialApp.router(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

Future<void> _confirmDelete(WidgetTester tester, String postId) async {
  await tester.tap(find.byKey(Key('my-post-delete-$postId')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('listing post delete routes to the listing API', (
    tester,
  ) async {
    final postService = _FakePostService();
    final listingService = _FakeListingService();
    await tester.pumpWidget(
      _app(postService: postService, listingService: listingService),
    );
    await tester.pumpAndSettle();

    expect(find.text('出二手显示器'), findsOneWidget);
    await _confirmDelete(tester, 'offer-1');

    expect(listingService.deletedListingIds, ['listing-123']);
    expect(postService.deletedIds, isEmpty);
  });

  testWidgets('discussion post delete still uses the post API', (
    tester,
  ) async {
    final postService = _FakePostService();
    final listingService = _FakeListingService();
    await tester.pumpWidget(
      _app(postService: postService, listingService: listingService),
    );
    await tester.pumpAndSettle();

    expect(find.text('毕业搬家攻略'), findsOneWidget);
    await _confirmDelete(tester, 'discussion-1');

    expect(postService.deletedIds, ['discussion-1']);
    expect(listingService.deletedListingIds, isEmpty);
  });
}
