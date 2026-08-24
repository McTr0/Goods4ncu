import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/pages/post_detail_page.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakePostService extends PostService {
  _FakePostService({this.paginate = false});

  final bool paginate;
  bool getPostCalled = false;
  bool getPostByListingCalled = false;
  String? requestedListingId;
  bool getRepliesCalled = false;
  final List<int> replyOffsets = [];
  final initialPost = CampusPost.fromJson({
    'id': 'post-1',
    'title': 'Where can I print tonight?',
    'body': 'Looking for a printer near campus.',
    'cover_image_url': 'https://cdn.test/printing.jpg',
    'tags': ['printing'],
    'author': {'id': 'u-1', 'username': 'mira'},
    'reply_count': 1,
    'status': 'active',
    'is_locked': false,
    'created_at': '2026-08-15T10:00:00Z',
  });

  @override
  Future<CampusPost> getPost(String id) async {
    getPostCalled = true;
    return initialPost;
  }

  @override
  Future<CampusPost> getPostByListing(String listingId) async {
    getPostByListingCalled = true;
    requestedListingId = listingId;
    return initialPost;
  }

  @override
  Future<PostRepliesResponse> getReplies(
    String postId, {
    int limit = 50,
    int offset = 0,
  }) async {
    getRepliesCalled = true;
    replyOffsets.add(offset);
    if (paginate) {
      final start = offset;
      final count = offset == 0 ? 50 : 1;
      return PostRepliesResponse(
        items: List.generate(
          count,
          (index) => PostReply(
            id: 'reply-${start + index + 1}',
            postId: postId,
            body: 'Reply ${start + index + 1}',
            author: const PostAuthor(id: 'u-2', username: 'lee'),
            createdAt: DateTime.utc(2026, 8, 15, 10, start + index),
            updatedAt: DateTime.utc(2026, 8, 15, 10, start + index),
          ),
        ),
        total: 51,
        limit: limit,
        offset: offset,
      );
    }
    return PostRepliesResponse(
      items: [
        PostReply.fromJson({
          'id': 'reply-1',
          'post_id': postId,
          'body': 'The east gate has one.',
          'author': {'id': 'u-2', 'username': 'lee'},
          'created_at': '2026-08-15T10:10:00Z',
        }),
      ],
      total: 1,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<PostReply> createReply(
    String postId, {
    required String body,
    String? replyToId,
  }) async {
    return PostReply(
      id: 'reply-2',
      postId: postId,
      body: body,
      author: const PostAuthor(id: 'u-3', username: 'you'),
      createdAt: DateTime.utc(2026, 8, 15, 10, 20),
      updatedAt: DateTime.utc(2026, 8, 15, 10, 20),
      replyToId: replyToId,
    );
  }
}

class _FakeListingService extends ListingService {}

class _ListingPostService extends _FakePostService {
  final listingPost = CampusPost.fromJson({
    'id': 'listing-post-1',
    'category': 'offer',
    'listing_id': 'listing-1',
    'title': 'Desk lamp',
    'body': 'Warm light, pickup on campus.',
    'author': {'id': 'u-1', 'username': 'mira'},
    'reply_count': 1,
    'status': 'active',
    'is_locked': false,
    'created_at': '2026-08-15T10:00:00Z',
  });

  @override
  Future<CampusPost> getPost(String id) async => listingPost;

  @override
  Future<CampusPost> getPostByListing(String listingId) async => listingPost;
}

void main() {
  testWidgets('renders a LinuxDO-style thread and sends a reply', (
    tester,
  ) async {
    final postService = _FakePostService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PostDetailPage(
          postId: 'post-1',
          postService: postService,
          listingService: _FakeListingService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Where can I print tonight?'), findsOneWidget);
    expect(find.byKey(const ValueKey('post-detail-cover')), findsOneWidget);
    expect(find.text('The east gate has one.'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('post-reply-field')),
      'Thanks for the tip!',
    );
    await tester.tap(find.byKey(const ValueKey('post-reply-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Thanks for the tip!'), findsOneWidget);
  });

  testWidgets('resolves a listing through its special post projection', (
    tester,
  ) async {
    final postService = _FakePostService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PostDetailPage(
          listingId: 'listing-1',
          postService: postService,
          listingService: _FakeListingService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(postService.getPostByListingCalled, isTrue);
    expect(postService.requestedListingId, 'listing-1');
    expect(postService.getPostCalled, isFalse);
    expect(find.text('Where can I print tonight?'), findsOneWidget);
  });

  testWidgets('ask assistant navigates with the discussion post id', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/posts/post-1',
      routes: [
        GoRoute(
          path: '/posts/:id',
          builder: (context, state) => PostDetailPage(
            postId: state.pathParameters['id'],
            postService: _FakePostService(),
            listingService: _FakeListingService(),
          ),
        ),
        GoRoute(
          path: '/agent',
          builder: (context, state) =>
              Text('assistant ${state.uri.queryParameters['postId']}'),
        ),
      ],
    );
    addTearDown(router.dispose);

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

    await tester.tap(find.byKey(const Key('post-ask-assistant')));
    await tester.pumpAndSettle();

    expect(find.text('assistant post-1'), findsOneWidget);
  });

  testWidgets('renders a listing-bound post as a normal thread', (tester) async {
    final postService = _ListingPostService();
    final router = GoRouter(
      initialLocation: '/posts/listing-post-1',
      routes: [
        GoRoute(
          path: '/posts/:id',
          builder: (context, state) => PostDetailPage(
            postId: state.pathParameters['id'],
            postService: postService,
          ),
        ),
        GoRoute(
          path: '/listing/:id',
          builder: (context, state) => Text(
            'Canonical listing ${state.pathParameters['id']}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

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

    // The thread renders inline; no redirect to the marketplace page.
    expect(find.text('Desk lamp'), findsOneWidget);
    expect(router.state.uri.path, '/posts/listing-post-1');
  });

  testWidgets('loads replies in stable pages instead of dropping floor 51', (
    tester,
  ) async {
    final postService = _FakePostService(paginate: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PostDetailPage(
          postId: 'post-1',
          postService: postService,
          listingService: _FakeListingService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(postService.replyOffsets, [0]);
    expect(
      find.byKey(const ValueKey('post-replies-load-more')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('post-replies-load-more')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-replies-load-more')));
    await tester.pumpAndSettle();

    expect(postService.replyOffsets, [0, 50]);
    expect(find.text('Reply 51'), findsOneWidget);
    expect(find.byKey(const ValueKey('post-replies-load-more')), findsNothing);
  });
}
