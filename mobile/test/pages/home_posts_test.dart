import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/pages/home_page.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakePostService extends PostService {
  _FakePostService(this.response);

  final PostsResponse response;
  int calls = 0;

  @override
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,
    String postType = 'all',
    String? category,
    String? search,
    String sort = 'latest',
  }) async {
    calls += 1;
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
    String postType = 'all',
    String? category,
    String? search,
    String sort = 'latest',
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

class _UnexpectedRecommendationService extends RecommendationService {
  bool called = false;

  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async {
    called = true;
    return const [];
  }
}

class _EmptyIntentService extends IntentService {
  @override
  Future<List<UserIntent>> campusFeed({
    IntentKind? kind,
    int limit = 30,
  }) async => const [];
}

Widget _app({
  required PostService posts,
  required RecommendationService legacy,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HomePage(
      postService: posts,
      recommendationService: legacy,
      intentService: _EmptyIntentService(),
      feedbackService: FeedFeedbackService(),
    ),
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
    final legacy = _UnexpectedRecommendationService();

    await tester.pumpWidget(_app(posts: posts, legacy: legacy));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('post-card-post-1')), findsOneWidget);
    expect(find.text('Where can I print tonight?'), findsOneWidget);
    expect(legacy.called, isFalse);
  });

  testWidgets('keeps an empty successful response in unified post mode', (
    tester,
  ) async {
    final posts = _FakePostService(
      const PostsResponse(items: [], total: 0, limit: 20, offset: 0),
    );
    final legacy = _UnexpectedRecommendationService();

    await tester.pumpWidget(_app(posts: posts, legacy: legacy));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('post-filter-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-create-post')), findsOneWidget);
    expect(posts.calls, 1);
    expect(legacy.called, isFalse);
  });

  testWidgets('shows price from a server listing preview in a post card', (
    tester,
  ) async {
    final posts = _FakePostService(
      PostsResponse(
        items: [
          CampusPost.fromJson({
            'id': 'post-listing-1',
            'post_type': 'listing',
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

    await tester.pumpWidget(
      _app(posts: posts, legacy: _UnexpectedRecommendationService()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('25.00'), findsOneWidget);
    expect(find.text('Listing'), findsOneWidget);
  });

  testWidgets('keeps waterfall results and retries a failed next page', (
    tester,
  ) async {
    final posts = _PagingPostService();
    final legacy = _UnexpectedRecommendationService();

    await tester.pumpWidget(_app(posts: posts, legacy: legacy));
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
    expect(legacy.called, isFalse);

    await tester.tap(find.byKey(const ValueKey('post-feed-retry')));
    await tester.pumpAndSettle();

    expect(posts.offsets, [0, 20, 20]);
    expect(find.byKey(const ValueKey('post-card-post-20')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-feed-retry')), findsNothing);
  });
}
