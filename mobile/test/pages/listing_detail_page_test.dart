import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/listing_detail_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/content_report_service.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/order_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _ListingApiService extends ApiService {
  _ListingApiService({
    required this.listing,
    required this.currentUserId,
    this.wantedMatches = const [],
  });

  final Listing listing;
  final String? currentUserId;
  final List<Listing> wantedMatches;

  @override
  Future<String?> getToken() async => currentUserId == null ? null : 'token';

  @override
  Future<Listing> getListingDetail(String id) async => listing;

  @override
  Future<ListingsResponse> getWantedMatches(String wantedId) async =>
      ListingsResponse(
        items: wantedMatches,
        total: wantedMatches.length,
        limit: 20,
        offset: 0,
        rankingVersion: '2026.07-wanted-feedback-v1',
      );

  @override
  Future<Map<String, dynamic>> getUserProfile() async {
    if (currentUserId == null) throw StateError('guest has no profile');
    return {'user_id': currentUserId, 'username': 'owner'};
  }
}

class _SwitchingListingApiService extends ApiService {
  _SwitchingListingApiService(this.listings);

  final Map<String, Listing> listings;

  @override
  Future<String?> getToken() async => null;

  @override
  Future<Listing> getListingDetail(String id) async => listings[id]!;
}

class _RecommendationService extends RecommendationService {
  _RecommendationService([this.items = const []]);

  final List<Listing> items;

  @override
  Future<List<Listing>> getSimilarListings(String listingId) async => items;
}

class _RecordingFeedFeedbackService extends FeedFeedbackService {
  _RecordingFeedFeedbackService({this.fail = false});

  final bool fail;
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

class _RecordingContentReportService extends ContentReportService {
  _RecordingContentReportService({this.pending});

  final Completer<String>? pending;
  int listingCalls = 0;
  String? listingId;
  String? reason;
  String? details;

  @override
  Future<String> reportListing(
    String listingId, {
    required String reason,
    String? details,
  }) {
    listingCalls += 1;
    this.listingId = listingId;
    this.reason = reason;
    this.details = details;
    return pending?.future ?? Future.value('report-1');
  }
}

Widget _buildDetail({
  required Listing listing,
  required String? currentUserId,
  ContentReportService? contentReportService,
  List<Listing> similarListings = const [],
  List<Listing> wantedMatches = const [],
  FeedFeedbackService? feedbackService,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ListingDetailPage(
      listingId: listing.id,
      apiService: _ListingApiService(
        listing: listing,
        currentUserId: currentUserId,
        wantedMatches: wantedMatches,
      ),
      recommendationService: _RecommendationService(similarListings),
      orderService: OrderService(),
      chatService: ChatService(),
      contentReportService:
          contentReportService ?? _RecordingContentReportService(),
      feedbackService: feedbackService ?? _RecordingFeedFeedbackService(),
    ),
  );
}

void main() {
  testWidgets('offer owner sees management instead of buyer actions', (
    tester,
  ) async {
    final listing = Listing(
      id: 'listing-owner-test',
      title: 'Owner listing',
      category: 'electronics',
      brand: 'Goods4ncu QA',
      conditionScore: 7,
      suggestedPriceCny: 12.34,
      status: 'active',
      ownerId: 'owner-1',
      ownerUsername: 'owner',
    );

    await tester.pumpWidget(
      _buildDetail(listing: listing, currentUserId: 'owner-1'),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的发布'), findsOneWidget);
    expect(find.text('联系卖家'), findsNothing);
    expect(find.text('发起成交意向'), findsNothing);
    expect(find.byKey(const Key('listing-report-action')), findsNothing);
  });

  testWidgets(
    'other listing can be reported once while submission is pending',
    (tester) async {
      final pending = Completer<String>();
      final reports = _RecordingContentReportService(pending: pending);
      final listing = Listing(
        id: 'listing-other-test',
        title: 'Suspicious listing',
        category: 'electronics',
        brand: 'Goods4ncu QA',
        conditionScore: 7,
        suggestedPriceCny: 12.34,
        status: 'active',
        ownerId: 'owner-2',
        ownerUsername: 'other owner',
      );

      await tester.pumpWidget(
        _buildDetail(
          listing: listing,
          currentUserId: 'viewer-1',
          contentReportService: reports,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('listing-report-action')), findsOneWidget);
      await tester.tap(find.byKey(const Key('listing-report-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('举报此商品'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('content-report-reason')),
        '疑似诈骗',
      );
      await tester.enterText(
        find.byKey(const Key('content-report-details')),
        '价格和描述不一致',
      );
      await tester.tap(find.byKey(const Key('content-report-submit')));
      await tester.pump();

      expect(reports.listingCalls, 1);
      expect(reports.listingId, listing.id);
      expect(reports.reason, '疑似诈骗');
      expect(reports.details, '价格和描述不一致');
      expect(find.byKey(const Key('listing-report-action')), findsNothing);

      pending.complete('report-1');
      await tester.pumpAndSettle();
      expect(find.text('已提交举报'), findsOneWidget);
      expect(reports.listingCalls, 1);
    },
  );

  testWidgets('guest can browse without a report action or profile request', (
    tester,
  ) async {
    final listing = Listing(
      id: 'listing-guest-test',
      title: 'Public listing',
      category: 'books',
      brand: 'Goods4ncu QA',
      conditionScore: 8,
      suggestedPriceCny: 20,
      status: 'active',
      ownerId: null,
      ownerUsername: 'owner',
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: listing,
        currentUserId: null,
        similarListings: [
          Listing(
            id: 'guest-similar',
            title: 'Guest-visible recommendation',
            category: 'books',
            brand: 'NCU',
            conditionScore: 7,
            suggestedPriceCny: 18,
            status: 'active',
            rankReason: 'vector_similarity',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Public listing'), findsWidgets);
    expect(find.byKey(const Key('listing-report-action')), findsNothing);
    expect(
      find.byKey(const ValueKey('feed-feedback-listing-guest-similar')),
      findsNothing,
      reason: 'feedback requires a confirmed signed-in viewer',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'similar recommendation explains itself and disappears after feedback',
    (tester) async {
      final listing = Listing(
        id: 'source-offer',
        title: 'Source offer',
        category: 'books',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 30,
        status: 'active',
        ownerId: 'owner-source',
        ownerUsername: 'source owner',
      );
      final first = Listing(
        id: 'similar-first',
        title: 'First similar book',
        category: 'books',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 20,
        status: 'active',
        rankReason: 'vector_similarity',
        source: 'vector_similarity',
      );
      final second = Listing(
        id: 'similar-second',
        title: 'Second similar book',
        category: 'books',
        brand: 'NCU',
        conditionScore: 7,
        suggestedPriceCny: 25,
        status: 'active',
        rankReason: 'recent',
        source: 'recency',
      );
      final feedback = _RecordingFeedFeedbackService();

      await tester.pumpWidget(
        _buildDetail(
          listing: listing,
          currentUserId: 'viewer-1',
          similarListings: [first, second],
          feedbackService: feedback,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ListingDetailPage)),
      )!;
      final menu = find.byKey(
        const ValueKey('feed-feedback-listing-similar-first'),
      );

      expect(find.textContaining(l.feedReasonSimilar), findsOneWidget);
      expect(find.textContaining('vector_similarity'), findsNothing);
      await tester.scrollUntilVisible(
        menu,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.feedFeedbackHide));
      await tester.pumpAndSettle();

      expect(find.text(first.title), findsNothing);
      expect(find.text(second.title), findsOneWidget);
      expect(feedback.calls, hasLength(1));
      expect(feedback.calls.single.resourceType, FeedResourceType.listing);
      expect(feedback.calls.single.resourceId, first.id);
      expect(feedback.calls.single.action, FeedFeedbackAction.hide);
    },
  );

  testWidgets(
    'wanted match shows constraint reasons and removes only after success',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wanted = Listing(
        id: 'wanted-source',
        title: '想收程序设计教材',
        category: 'books',
        brand: '不限',
        direction: 'wanted',
        conditionScore: 6,
        suggestedPriceCny: 40,
        status: 'active',
        ownerId: 'viewer-1',
        ownerUsername: 'requester',
      );
      final match = Listing(
        id: 'wanted-match',
        title: '程序设计教材第六版',
        category: 'books',
        brand: '高教社',
        conditionScore: 8,
        suggestedPriceCny: 35,
        status: 'active',
        rankReason: 'known_slots_compatible',
        matchSummary: const [
          'category_match',
          'price_within_constraint',
          'condition_at_least_requested',
        ],
        source: 'wanted_match',
      );
      final feedback = _RecordingFeedFeedbackService();

      await tester.pumpWidget(
        _buildDetail(
          listing: wanted,
          currentUserId: 'viewer-1',
          wantedMatches: [match],
          feedbackService: feedback,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ListingDetailPage)),
      )!;
      final menu = find.byKey(
        const ValueKey('feed-feedback-listing-wanted-match'),
      );

      expect(find.textContaining(l.feedReasonWithinBudget), findsOneWidget);
      expect(find.textContaining('price_within_constraint'), findsNothing);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -350),
      );
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.feedFeedbackLessLikeThis));
      await tester.pumpAndSettle();

      expect(find.text(match.title), findsNothing);
      expect(feedback.calls.single.resourceType, FeedResourceType.listing);
      expect(feedback.calls.single.resourceId, match.id);
      expect(feedback.calls.single.action, FeedFeedbackAction.lessLikeThis);
    },
  );

  testWidgets('changing the route id reloads the reused detail page state', (
    tester,
  ) async {
    final first = Listing(
      id: 'route-first',
      title: 'First route listing',
      category: 'books',
      brand: 'NCU',
      conditionScore: 8,
      suggestedPriceCny: 20,
      status: 'active',
      ownerId: 'owner-first',
      ownerUsername: 'first owner',
    );
    final second = Listing(
      id: 'route-second',
      title: 'Second route listing',
      category: 'electronics',
      brand: 'NCU',
      conditionScore: 9,
      suggestedPriceCny: 40,
      status: 'active',
      ownerId: 'owner-second',
      ownerUsername: 'second owner',
    );
    final listingId = ValueNotifier(first.id);
    addTearDown(listingId.dispose);
    final api = _SwitchingListingApiService({
      first.id: first,
      second.id: second,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<String>(
          valueListenable: listingId,
          builder: (context, id, _) => ListingDetailPage(
            listingId: id,
            apiService: api,
            recommendationService: _RecommendationService(),
            orderService: OrderService(),
            chatService: ChatService(),
            contentReportService: _RecordingContentReportService(),
            feedbackService: _RecordingFeedFeedbackService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(first.title), findsWidgets);

    listingId.value = second.id;
    await tester.pumpAndSettle();

    expect(find.text(first.title), findsNothing);
    expect(find.text(second.title), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed recommendation feedback retains the selected listing', (
    tester,
  ) async {
    final listing = Listing(
      id: 'failure-source',
      title: 'Source listing',
      category: 'electronics',
      brand: 'NCU',
      conditionScore: 8,
      suggestedPriceCny: 100,
      status: 'active',
      ownerId: 'owner-source',
      ownerUsername: 'source owner',
    );
    final candidate = Listing(
      id: 'failure-candidate',
      title: 'Candidate remains',
      category: 'electronics',
      brand: 'NCU',
      conditionScore: 8,
      suggestedPriceCny: 90,
      status: 'active',
      rankReason: 'vector_similarity',
    );
    final feedback = _RecordingFeedFeedbackService(fail: true);

    await tester.pumpWidget(
      _buildDetail(
        listing: listing,
        currentUserId: 'viewer-1',
        similarListings: [candidate],
        feedbackService: feedback,
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(ListingDetailPage)),
    )!;
    final menu = find.byKey(
      const ValueKey('feed-feedback-listing-failure-candidate'),
    );

    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackNotRelevant));
    await tester.pumpAndSettle();

    expect(find.text(candidate.title), findsOneWidget);
    expect(find.text(l.feedFeedbackFailed), findsOneWidget);
    expect(feedback.calls, hasLength(1));
  });
}
