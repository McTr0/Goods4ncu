import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/pages/home_page.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakePostService extends PostService {
  _FakePostService(this.response);

  final PostsResponse response;
  int calls = 0;
  final List<String> categories = [];

  final List<String?> searches = [];

  @override
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,
    String category = 'all',
    String? spaceId,
    String? search,
    String sort = 'for_you',
  }) async {
    calls += 1;
    categories.add(category);
    searches.add(search);
    return response;
  }
}

class _PagingPostService extends PostService {
  final List<int> offsets = [];
  bool failNextPage = true;

  List<CampusPost> _items(int start, int count) {
    return List.generate(
      count,
      (index) => CampusPost.fromJson({
        'id': 'post-${start + index}',
        'post_type': 'discussion',
        'title': 'Campus discussion ${start + index}',
        'body_excerpt':
            'A useful campus thread with enough context to make the waterfall card readable.',
        'author': {'id': 'u-1', 'username': 'mira'},
        'reply_count': index,
        'status': 'active',
        'is_locked': false,
      }),
    );
  }

  @override
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,
    String category = 'all',
    String? spaceId,
    String? search,
    String sort = 'for_you',
  }) async {
    offsets.add(offset);
    if (offset == 20 && failNextPage) {
      failNextPage = false;
      throw Exception('temporary page failure');
    }
    return PostsResponse(
      items: offset == 0 ? _items(0, 20) : _items(20, 1),
      total: 21,
      limit: limit,
      offset: offset,
    );
  }
}

class _FailingPostService extends PostService {
  @override
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,
    String category = 'all',
    String? spaceId,
    String? search,
    String sort = 'for_you',
  }) async {
    throw Exception('posts_unavailable');
  }
}

Widget _app({required PostService posts}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HomePage(postService: posts, feedbackService: FeedFeedbackService()),
  );
}

void main() {
  testWidgets('renders successful unified post results as discovery cards', (
    tester,
  ) async {
    final posts = _FakePostService(
      PostsResponse(
        items: [
          CampusPost.fromJson({
            'id': 'post-1',
            'post_type': 'discussion',
            'title': 'Where can I print tonight?',
            'body_excerpt': 'Looking for a printer near campus.',
            'cover_image_url': 'https://cdn.test/printing.jpg',
            'author': {'id': 'u-1', 'username': 'mira'},
            'reply_count': 2,
            'status': 'active',
            'is_locked': false,
          }),
        ],
        total: 1,
        limit: 20,
        offset: 0,
      ),
    );
    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('post-card-post-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-cover-post-1')), findsOneWidget);
    expect(find.text('Where can I print tonight?'), findsOneWidget);
  });

  testWidgets('keeps an empty successful response in unified post mode', (
    tester,
  ) async {
    final posts = _FakePostService(
      const PostsResponse(items: [], total: 0, limit: 20, offset: 0),
    );
    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('post-filter-picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-create-post')), findsNothing);
    expect(posts.calls, 1);
  });

  testWidgets('shows a unified-feed error when posts fail', (tester) async {
    await tester.pumpWidget(_app(posts: _FailingPostService()));
    await tester.pumpAndSettle();

    expect(find.text('Could not load right now'), findsOneWidget);
  });

  testWidgets('shows price from a server listing preview in a post card', (
    tester,
  ) async {
    final posts = _FakePostService(
      PostsResponse(
        items: [
          CampusPost.fromJson({
            'id': 'post-listing-1',
            'category': 'offer',
            'title': 'Calculus textbook',
            'body_excerpt': 'Used for one semester',
            'listing_id': 'listing-1',
            'author': {'id': 'u-1', 'username': 'mira'},
            'reply_count': 0,
            'status': 'active',
            'is_locked': false,
            'listing': {
              'id': 'listing-1',
              'title': 'Calculus textbook',
              'category': 'books',
              'brand': 'Pearson',
              'direction': 'offer',
              'condition_score': 8,
              'suggested_price_cny': 25,
              'status': 'active',
            },
          }),
        ],
        total: 1,
        limit: 20,
        offset: 0,
      ),
    );

    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();

    expect(find.textContaining('25.00'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('post-card-post-listing-1')),
        matching: find.text('Offer'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('opens a listing-bound card in the unified thread view', (
    tester,
  ) async {
    final posts = _FakePostService(
      PostsResponse(
        items: [
          CampusPost.fromJson({
            'id': 'post-listing-route',
            'category': 'offer',
            'title': 'Calculus textbook',
            'listing_id': 'listing-route',
            'author': {'id': 'u-1', 'username': 'mira'},
            'reply_count': 0,
            'status': 'active',
            'is_locked': false,
          }),
        ],
        total: 1,
        limit: 20,
        offset: 0,
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => HomePage(
            postService: posts,
            feedbackService: FeedFeedbackService(),
          ),
        ),
        GoRoute(
          path: '/posts/:id',
          builder: (context, state) =>
              Text('thread ${state.pathParameters['id']}'),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('post-card-post-listing-route')),
    );
    await tester.pumpAndSettle();

    expect(find.text('thread post-listing-route'), findsOneWidget);
  });

  testWidgets('searches the unified post feed and can clear the query', (
    tester,
  ) async {
    final posts = _FakePostService(
      PostsResponse(
        items: [
          CampusPost.fromJson({
            'id': 'post-search-1',
            'post_type': 'discussion',
            'title': 'Late-night printing',
            'author': {'id': 'u-1', 'username': 'mira'},
            'reply_count': 0,
            'status': 'active',
            'is_locked': false,
          }),
        ],
        total: 1,
        limit: 20,
        offset: 0,
      ),
    );

    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('home-agent-prompt')),
      '  printer  ',
    );
    await tester.tap(find.byKey(const ValueKey('home-search-submit')));
    await tester.pumpAndSettle();

    expect(posts.searches, [null, 'printer']);
    expect(find.byKey(const ValueKey('home-search-clear')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-search-clear')));
    await tester.pumpAndSettle();

    expect(posts.searches, [null, 'printer', null]);
    expect(find.byKey(const ValueKey('home-search-clear')), findsNothing);
  });

  testWidgets('maps sell and wanted filters to server-side direction queries', (
    tester,
  ) async {
    final posts = _FakePostService(
      const PostsResponse(items: [], total: 0, limit: 20, offset: 0),
    );

    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();

    expect(find.text('For you'), findsOneWidget);

    Future<void> pickFilter(String key) async {
      await tester.tap(find.byKey(const ValueKey('post-filter-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('picker-$key')));
      await tester.pumpAndSettle();
    }

    await pickFilter('offer');
    await pickFilter('wanted');

    expect(posts.categories, ['all', 'offer', 'wanted']);
  });

  testWidgets('keeps waterfall results and retries a failed next page', (
    tester,
  ) async {
    final posts = _PagingPostService();
    await tester.pumpWidget(_app(posts: posts));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('post-card-post-0')), findsOneWidget);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -6000),
      4000,
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('post-feed-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-card-post-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('post-feed-retry')));
    await tester.pumpAndSettle();

    expect(posts.offsets, [0, 20, 20]);
    expect(find.byKey(const ValueKey('post-card-post-20')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-feed-retry')), findsNothing);
  });
}
