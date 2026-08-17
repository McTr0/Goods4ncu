import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/home_page.dart';
import 'package:goods4ncu_mobile/router/publish_navigation.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// A campus where nobody has posted yet — day one, and the state every real
/// launch starts in.
class _EmptyRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async => const [];
}

class _FailingRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async {
    throw Exception('network_timeout');
  }
}

class _FakeRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async {
    return [
      Listing(
        id: 'listing-1',
        title: '程序设计教材',
        category: 'books',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 35,
        status: 'active',
        rankReason: 'same_category',
        source: 'intent_match',
      ),
    ];
  }
}

class _FakeListingService extends ListingService {
  _FakeListingService({this.listings = const []});

  final List<Listing> listings;
  String? lastQueriedDirection;

  @override
  Future<ListingsResponse> getListings({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
    List<String>? categories,
    double? minPriceCny,
    double? maxPriceCny,
    String sort = 'newest',
    String direction = 'offer',
    bool allowAnonymousFallback = true,
  }) async {
    lastQueriedDirection = direction;
    final filtered = listings.where((l) {
      if (direction != 'all') {
        return l.direction == direction;
      }
      return true;
    }).toList();
    return ListingsResponse(
      items: filtered,
      total: filtered.length,
      limit: limit,
      offset: offset,
    );
  }
}

class _FakeFailingListingService extends ListingService {
  @override
  Future<ListingsResponse> getListings({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
    List<String>? categories,
    double? minPriceCny,
    double? maxPriceCny,
    String sort = 'newest',
    String direction = 'offer',
    bool allowAnonymousFallback = true,
  }) async {
    throw Exception('listing_fallback_failed');
  }
}

class _FakeStrictListingService extends ListingService {
  bool allowAnonymousFallbackPassed = true;

  @override
  Future<ListingsResponse> getListings({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
    List<String>? categories,
    double? minPriceCny,
    double? maxPriceCny,
    String sort = 'newest',
    String direction = 'offer',
    bool allowAnonymousFallback = true,
  }) async {
    allowAnonymousFallbackPassed = allowAnonymousFallback;
    if (!allowAnonymousFallback) {
      throw Exception('401_unauthorized_strict');
    }
    return ListingsResponse(items: [], total: 0, limit: limit, offset: offset);
  }
}

class _FakeFeedFeedbackService extends FeedFeedbackService {
  bool fail = false;
  final List<
    ({
      FeedResourceType resourceType,
      String resourceId,
      FeedFeedbackAction action,
    })
  >
  calls = [];

  @override
  Future<void> submitFeedback({
    required FeedResourceType resourceType,
    required String resourceId,
    required FeedFeedbackAction action,
  }) async {
    calls.add((
      resourceType: resourceType,
      resourceId: resourceId,
      action: action,
    ));
    if (fail) throw Exception('offline');
  }
}

/// What people have said, independent of what has been listed.
class _FakeIntentService extends IntentService {
  _FakeIntentService([this.voices = const []]);

  final List<UserIntent> voices;
  final List<(String, String)> responses = [];

  @override
  Future<List<UserIntent>> campusFeed({
    IntentKind? kind,
    int limit = 30,
  }) async => voices
      .where((intent) => kind == null || intent.kind == kind)
      .take(limit)
      .toList();

  @override
  Future<String> respondToIntent(String intentId, String content) async {
    responses.add((intentId, content));
    return 'conversation-1';
  }
}

Widget _buildApp({
  Locale locale = const Locale('zh'),
  ThemeMode themeMode = ThemeMode.light,
  RecommendationService? recommendations,
  ListingService? listings,
  IntentService? intents,
  FeedFeedbackService? feedback,
  double textScaleFactor = 1,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomePage()),
      GoRoute(
        path: '/chat',
        builder: (context, state) =>
            Text('chat prompt: ${state.uri.queryParameters['prompt'] ?? ''}'),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Text('listing ${state.pathParameters['id'] ?? ''}'),
      ),
      GoRoute(
        path: PublishNavigation.listingPath,
        builder: (context, state) =>
            Text('publish: ${state.uri.queryParameters['direction'] ?? ''}'),
      ),
    ],
  );

  return MultiProvider(
    providers: [
      Provider<RecommendationService>.value(
        value: recommendations ?? _FakeRecommendationService(),
      ),
      Provider<ListingService>.value(value: listings ?? _FakeListingService()),
      Provider<IntentService>.value(value: intents ?? _FakeIntentService()),
      Provider<FeedFeedbackService>.value(
        value: feedback ?? _FakeFeedFeedbackService(),
      ),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScaleFactor)),
        child: child!,
      ),
    ),
  );
}

void main() {
  testWidgets('day one invites clear action instead of announcing emptiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        recommendations: _EmptyRecommendationService(),
        listings: _FakeListingService(listings: const []),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    expect(find.text(l.homeColdStartTitle), findsOneWidget);
    expect(find.text(l.noProducts), findsNothing);
    // Action buttons are explicit and balanced
    expect(find.text(l.homeActionOffer), findsWidgets);
    expect(find.text(l.homeActionWanted), findsWidgets);
  });

  testWidgets('the invitation leads to create page', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        recommendations: _EmptyRecommendationService(),
        listings: _FakeListingService(listings: const []),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    await tester.ensureVisible(find.text(l.homeActionOffer));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.homeActionOffer));
    await tester.pumpAndSettle();
    expect(find.text('publish: offer'), findsOneWidget);
  });

  testWidgets('home page removes English eyebrow and marketing slogan', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    // English eyebrow and marketing sloganeering must not appear
    expect(find.text('Goods4ncu Campus Market'), findsNothing);
    expect(find.text('今天想淘点什么？'), findsNothing);
    expect(find.text('试试这样开始'), findsNothing);
    expect(find.text('推荐怎么来'), findsNothing);
    expect(find.textContaining('相关度'), findsNothing);
    expect(find.textContaining('轻量排序'), findsNothing);

    // Search stays on the discovery page instead of duplicating the AI tab.
    await tester.enterText(
      find.byKey(const ValueKey('home-agent-prompt')),
      '帮我找一本高数教材',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.textContaining('chat prompt:'), findsNothing);
  });

  testWidgets(
    'home page shows a simple feed without duplicate publish actions',
    (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('home-action-find')), findsNothing);
      expect(find.byKey(const ValueKey('home-action-offer')), findsNothing);
      expect(find.byKey(const ValueKey('home-action-wanted')), findsNothing);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('出'), findsWidgets);
      expect(find.text('收'), findsOneWidget);
      expect(find.text('程序设计教材'), findsOneWidget);
      expect(find.text('分类符合你的需求'), findsOneWidget);
    },
  );

  testWidgets('home page localizes the entry in English', (tester) async {
    await tester.pumpWidget(_buildApp(locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Search items or requests'), findsOneWidget);
    // Publishing lives in the persistent center navigation destination; the
    // home feed does not duplicate those actions.
    expect(find.text('Post Offer'), findsNothing);
    expect(find.text('Post Request'), findsNothing);
    expect(find.text('今天想淘点什么？'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('home-agent-prompt')),
      'help me find a laptop',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.textContaining('chat prompt:'), findsNothing);
  });

  testWidgets('home page uses the dark surface gradient in dark mode', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    final decoratedBox = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .firstWhere((box) {
          final decoration = box.decoration;
          return decoration is BoxDecoration &&
              decoration.gradient is LinearGradient;
        });
    final gradient =
        (decoratedBox.decoration as BoxDecoration).gradient! as LinearGradient;

    expect(gradient.colors.first, AppTheme.surfaceDark);
  });

  testWidgets(
    'separates network load failure with retry affordance from empty campus',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          recommendations: _FailingRecommendationService(),
          listings: _FakeListingService(listings: const []),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

      // Failure must not disguise as empty cold-start
      expect(find.text(l.homeLoadFailed), findsOneWidget);
      expect(find.text(l.homeLoadFailedRetry), findsOneWidget);
      expect(find.text(l.homeColdStartTitle), findsNothing);
    },
  );

  testWidgets(
    'empty recommendation feed falls back to deterministic campus listings preserving direction',
    (tester) async {
      final fakeListingService = _FakeListingService(
        listings: [
          Listing(
            id: 'seed-listing-1',
            title: '高等数学教材',
            category: 'books',
            brand: '高等教育出版社',
            conditionScore: 8,
            suggestedPriceCny: 35,
            status: 'active',
            direction: 'offer',
          ),
        ],
      );

      await tester.pumpWidget(
        _buildApp(
          recommendations: _EmptyRecommendationService(),
          listings: fakeListingService,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('高等数学教材'), findsOneWidget);
      expect(fakeListingService.lastQueriedDirection, 'all');
    },
  );

  testWidgets(
    'empty recommendation feed with failing listing fallback shows error state and retry',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          recommendations: _EmptyRecommendationService(),
          listings: _FakeFailingListingService(),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

      expect(find.text(l.homeLoadFailed), findsOneWidget);
      expect(find.text(l.homeLoadFailedRetry), findsOneWidget);
      expect(find.text(l.homeColdStartTitle), findsNothing);
    },
  );

  testWidgets(
    'strict listing fallback passes allowAnonymousFallback false and enters error state on 401',
    (tester) async {
      final strictService = _FakeStrictListingService();
      await tester.pumpWidget(
        _buildApp(
          recommendations: _EmptyRecommendationService(),
          listings: strictService,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

      expect(strictService.allowAnonymousFallbackPassed, isFalse);
      expect(find.text(l.homeLoadFailed), findsOneWidget);
      expect(find.text(l.homeLoadFailedRetry), findsOneWidget);
      expect(find.text(l.homeColdStartTitle), findsNothing);
    },
  );

  testWidgets('publish shortcuts stay absent at 200% text scaling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_buildApp(textScaleFactor: 2.0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-action-find')), findsNothing);
    expect(find.byKey(const ValueKey('home-action-offer')), findsNothing);
    expect(find.byKey(const ValueKey('home-action-wanted')), findsNothing);
    expect(find.byKey(const ValueKey('home-agent-prompt')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty grid with people talking is not an empty campus', (
    tester,
  ) async {
    final intents = _FakeIntentService([
      UserIntent(
        id: 'intent-1',
        kind: IntentKind.goodsSeek,
        rawInput: '想收一个小冰箱',
        slots: const IntentSlots(),
        status: 'active',
      ),
    ]);
    await tester.pumpWidget(
      _buildApp(
        recommendations: _EmptyRecommendationService(),
        listings: _FakeListingService(listings: const []),
        intents: intents,
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    expect(find.text('想收一个小冰箱'), findsOneWidget);
    expect(find.text(l.homeColdStartTitle), findsNothing);
  });

  testWidgets('someone on the home screen can be answered from it', (
    tester,
  ) async {
    final intents = _FakeIntentService([
      UserIntent(
        id: 'intent-2',
        kind: IntentKind.goodsSeek,
        rawInput: '找个羽毛球拍',
        slots: const IntentSlots(),
        status: 'active',
      ),
    ]);
    await tester.pumpWidget(
      _buildApp(
        recommendations: _EmptyRecommendationService(),
        listings: _FakeListingService(listings: const []),
        intents: intents,
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    await tester.ensureVisible(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '我有闲置尤尼克斯');
    await tester.tap(find.text(l.intentRespondSend));
    await tester.pumpAndSettle();

    expect(intents.responses, [('intent-2', '我有闲置尤尼克斯')]);
  });

  testWidgets('a campus that has genuinely said nothing still gets invited', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        recommendations: _EmptyRecommendationService(),
        listings: _FakeListingService(listings: const []),
        intents: _FakeIntentService(),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    expect(find.text(l.homeColdStartTitle), findsOneWidget);
    expect(find.text(l.homeVoicesTitle), findsNothing);
  });

  testWidgets('successful listing feedback removes only that card', (
    tester,
  ) async {
    final feedback = _FakeFeedFeedbackService();
    await tester.pumpWidget(_buildApp(feedback: feedback));
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;
    final menu = find.byKey(const ValueKey('feed-feedback-listing-listing-1'));

    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackHide));
    await tester.pumpAndSettle();

    expect(find.text('程序设计教材'), findsNothing);
    expect(feedback.calls, hasLength(1));
    expect(feedback.calls.single.resourceType, FeedResourceType.listing);
    expect(feedback.calls.single.resourceId, 'listing-1');
    expect(feedback.calls.single.action, FeedFeedbackAction.hide);
  });

  testWidgets(
    'failed listing feedback keeps the card and explains the failure',
    (tester) async {
      final feedback = _FakeFeedFeedbackService()..fail = true;
      await tester.pumpWidget(_buildApp(feedback: feedback));
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;
      final menu = find.byKey(
        const ValueKey('feed-feedback-listing-listing-1'),
      );

      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.feedFeedbackNotRelevant));
      await tester.pump();

      expect(find.text('程序设计教材'), findsOneWidget);
      expect(find.text(l.feedFeedbackFailed), findsOneWidget);
      expect(feedback.calls, hasLength(1));
    },
  );

  testWidgets('listing controls do not overlap at 200% text scaling', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(textScaleFactor: 2));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('feed-feedback-listing-listing-1'));
    final direction = find.byKey(const ValueKey('listing-direction-listing-1'));

    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    final menuRect = tester.getRect(menu);
    final directionRect = tester.getRect(direction);

    expect(menuRect.overlaps(directionRect), isFalse);
    expect(
      menuRect.top,
      greaterThanOrEqualTo(directionRect.bottom),
      reason: 'the feedback menu belongs below the direction pill',
    );
  });
}
