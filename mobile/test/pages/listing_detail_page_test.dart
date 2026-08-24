import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/pages/listing_detail_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/base_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/content_report_service.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/order_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _ListingApiService extends ApiService {
  _ListingApiService({
    required this.listing,
    required this.currentUserId,
    this.wantedMatches = const [],
    List<WantedResponse> wantedResponses = const [],
    this.failWantedAction = false,
    this.wantedActionConflictCode,
    this.listingAfterWantedActionConflict,
    this.userListingItems = const [],
    this.wantedRecommendationFailuresRemaining = 0,
  }) : wantedResponses = List.of(wantedResponses);

  Listing listing;
  final String? currentUserId;
  final List<Listing> wantedMatches;
  final List<WantedResponse> wantedResponses;
  final bool failWantedAction;
  final String? wantedActionConflictCode;
  final Listing? listingAfterWantedActionConflict;
  final List<Map<String, dynamic>> userListingItems;
  int wantedRecommendationFailuresRemaining;
  final List<String> wantedResponseActions = [];
  final List<String?> wantedRecommendationIdempotencyKeys = [];
  String? wantedResponseRole;
  String? wantedResponseListingId;
  int listingDetailCalls = 0;
  int wantedResponseListCalls = 0;
  int fulfillCalls = 0;
  int relistCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> getToken() async => currentUserId == null ? null : 'token';

  @override
  Future<Listing> getListingDetail(String id) async {
    listingDetailCalls += 1;
    return listing;
  }

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
  Future<WantedResponsesResponse> getWantedResponses({
    String role = 'requester',
    String? wantedListingId,
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    wantedResponseListCalls += 1;
    wantedResponseRole = role;
    wantedResponseListingId = wantedListingId;
    return WantedResponsesResponse(
      items: List<WantedResponse>.of(wantedResponses),
      total: wantedResponses.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<WantedResponseActionResult> acceptWantedResponse(String id) =>
      _actOnWantedResponse(id, 'accepted');

  @override
  Future<WantedResponseActionResult> dismissWantedResponse(String id) =>
      _actOnWantedResponse(id, 'dismissed');

  @override
  Future<WantedResponseActionResult> withdrawWantedResponse(String id) =>
      _actOnWantedResponse(id, 'withdrawn');

  Future<WantedResponseActionResult> _actOnWantedResponse(
    String id,
    String status,
  ) async {
    wantedResponseActions.add('$status:$id');
    if (failWantedAction) throw Exception('offline');
    final index = wantedResponses.indexWhere((response) => response.id == id);
    final conflictCode = wantedActionConflictCode;
    if (conflictCode != null) {
      if (index >= 0) {
        wantedResponses[index] = wantedResponses[index].copyWith(
          roundState: 'closed',
          availableActions: const <String>{},
        );
      }
      if (listingAfterWantedActionConflict != null) {
        listing = listingAfterWantedActionConflict!;
      }
      throw ConflictException('round closed', conflictCode);
    }
    if (index >= 0) {
      final response = wantedResponses[index];
      wantedResponses[index] = response.copyWith(
        status: status,
        respondedAt: DateTime.utc(2026, 7, 30),
      );
    }
    return WantedResponseActionResult(id: id, status: status);
  }

  @override
  Future<void> fulfillWanted(String id) async {
    fulfillCalls += 1;
  }

  @override
  Future<void> relistListing(String id) async {
    relistCalls += 1;
  }

  @override
  Future<void> deleteListing(String id, {int? expectedContentRevision}) async {
    deleteCalls += 1;
  }

  @override
  Future<Map<String, dynamic>> getUserProfile() async {
    if (currentUserId == null) throw StateError('guest has no profile');
    return {'user_id': currentUserId, 'username': 'owner'};
  }

  @override
  Future<Map<String, dynamic>> getUserListings({
    int limit = 20,
    int offset = 0,
    String? status,
  }) async {
    return {
      'items': userListingItems,
      'total': userListingItems.length,
      'limit': limit,
      'offset': offset,
    };
  }

  @override
  Future<String> recommendOfferForWanted({
    required String wantedId,
    required String offerListingId,
    String? message,
    String? idempotencyKey,
  }) async {
    wantedRecommendationIdempotencyKeys.add(idempotencyKey);
    if (wantedRecommendationFailuresRemaining > 0) {
      wantedRecommendationFailuresRemaining -= 1;
      throw Exception('offline');
    }
    return 'recommended';
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

class _InlinePostService extends PostService {
  @override
  Future<CampusPost> getPostByListing(String listingId) async {
    return CampusPost.fromJson({
      'id': 'post-for-$listingId',
      'post_type': 'listing',
      'listing_id': listingId,
      'title': 'Listing post',
      'body': 'Listing body',
      'author': {'id': 'owner-1', 'username': 'owner'},
      'reply_count': 1,
      'status': 'active',
      'is_locked': false,
      'created_at': '2026-08-15T10:00:00Z',
    });
  }

  @override
  Future<PostRepliesResponse> getReplies(
    String postId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return PostRepliesResponse(
      items: [
        PostReply(
          id: 'reply-1',
          postId: postId,
          body: 'Is pickup available on campus?',
          author: const PostAuthor(id: 'viewer-1', username: 'viewer'),
          createdAt: DateTime.utc(2026, 8, 15, 10, 10),
          updatedAt: DateTime.utc(2026, 8, 15, 10, 10),
        ),
      ],
      total: 1,
      limit: limit,
      offset: offset,
    );
  }
}

Widget _buildDetail({
  required Listing listing,
  required String? currentUserId,
  ContentReportService? contentReportService,
  List<Listing> similarListings = const [],
  List<Listing> wantedMatches = const [],
  List<WantedResponse> wantedResponses = const [],
  FeedFeedbackService? feedbackService,
  PostService? postService,
  _ListingApiService? apiService,
}) {
  final resolvedApiService =
      apiService ??
      _ListingApiService(
        listing: listing,
        currentUserId: currentUserId,
        wantedMatches: wantedMatches,
        wantedResponses: wantedResponses,
      );
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ListingDetailPage(
      listingId: listing.id,
      apiService: resolvedApiService,
      recommendationService: _RecommendationService(similarListings),
      orderService: OrderService(),
      chatService: ChatService(),
      contentReportService:
          contentReportService ?? _RecordingContentReportService(),
      feedbackService: feedbackService ?? _RecordingFeedFeedbackService(),
      postService: postService,
    ),
  );
}

Listing _wantedListing({
  String status = 'active',
  String ownerId = 'requester-1',
}) {
  return Listing(
    id: 'wanted-response-source',
    title: '想收宿舍机械键盘',
    category: 'electronics',
    brand: '不限',
    direction: 'wanted',
    conditionScore: 6,
    suggestedPriceCny: 160,
    status: status,
    ownerId: ownerId,
    ownerUsername: 'requester',
  );
}

WantedResponse _wantedResponse({
  String status = 'pending',
  String wantedStatus = 'active',
  int? lifecycleEpoch,
  int? currentLifecycleEpoch,
  String? roundState,
  Set<String>? availableActions,
}) {
  return WantedResponse(
    id: 'response-1',
    wantedListingId: 'wanted-response-source',
    wantedTitle: '想收宿舍机械键盘',
    wantedStatus: wantedStatus,
    offerListingId: 'offer-1',
    offerTitle: '青轴机械键盘',
    offerStatus: 'active',
    responderId: 'responder-1',
    requesterId: 'requester-1',
    message: '可以在前湖校区当面试键',
    status: status,
    createdAt: DateTime.utc(2026, 7, 30),
    lifecycleEpoch: lifecycleEpoch,
    currentLifecycleEpoch: currentLifecycleEpoch,
    roundState: roundState,
    availableActions: availableActions,
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

    expect(find.text('我的商品'), findsOneWidget);
    expect(find.text('联系卖家'), findsNothing);
    expect(find.text('发起成交意向'), findsNothing);
    expect(find.byKey(const Key('listing-report-action')), findsNothing);
    expect(find.byKey(const ValueKey('listing-open-discussion')), findsNothing);
  });

  testWidgets(
    'listing detail contains its thread without a second detail CTA',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final listing = Listing(
        id: 'listing-with-thread',
        title: 'Mechanical keyboard',
        category: 'electronics',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 120,
        status: 'active',
        ownerId: 'owner-1',
        ownerUsername: 'owner',
      );

      await tester.pumpWidget(
        _buildDetail(
          listing: listing,
          currentUserId: 'viewer-1',
          postService: _InlinePostService(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('listing-inline-discussion')),
        findsOneWidget);
    // The thread jumps back to the unified discussion page instead of
    // rendering an embedded second comment surface.
    expect(
      find.byKey(const ValueKey('listing-open-discussion')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('post-reply-field')), findsNothing);
    },
  );

  testWidgets('offer actions expose one primary action and a secondary menu', (
    tester,
  ) async {
    final listing = Listing(
      id: 'listing-actions',
      title: 'Desk lamp',
      category: 'dailyGoods',
      brand: 'NCU',
      conditionScore: 8,
      suggestedPriceCny: 20,
      status: 'active',
      ownerId: 'owner-2',
      ownerUsername: 'owner',
      availableActions: const {
        Listing.actionBuy,
        Listing.actionContact,
        Listing.actionPriceDiscovery,
      },
    );

    await tester.pumpWidget(
      _buildDetail(listing: listing, currentUserId: 'viewer-1'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('listing-primary-action')),
      findsOneWidget,
    );
    expect(find.text('发起成交意向'), findsOneWidget);
    expect(find.text('联系卖家'), findsNothing);
    expect(find.text('发起价格协商'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('listing-secondary-actions')));
    await tester.pumpAndSettle();

    expect(find.text('联系卖家'), findsOneWidget);
    expect(find.text('发起价格协商'), findsOneWidget);
  });

  testWidgets(
    'restricted offer exposes no marketplace actions and shows appeal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final listing = Listing(
        id: 'listing-restricted',
        title: 'Restricted listing',
        category: 'electronics',
        brand: 'NCU',
        conditionScore: 7,
        suggestedPriceCny: 12.34,
        status: 'active',
        ownerId: 'owner-2',
        restrictionState: 'restricted',
        restriction: const ListingRestriction(
          reason: '等待人工复核',
          moderationCaseId: 'case-1',
          canAppeal: true,
        ),
        availableActions: const {
          Listing.actionContact,
          Listing.actionBuy,
          Listing.actionPriceDiscovery,
        },
      );

      await tester.pumpWidget(
        _buildDetail(listing: listing, currentUserId: 'viewer-1'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('listing-restriction-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('listing-restriction-notice')),
        findsOneWidget,
      );
      expect(find.text('等待人工复核'), findsOneWidget);
      expect(
        find.byKey(const Key('listing-view-moderation-case')),
        findsOneWidget,
      );
      expect(find.text('联系卖家'), findsNothing);
      expect(find.text('让小昌定价'), findsNothing);
      expect(find.text('发起成交意向'), findsNothing);
    },
  );

  testWidgets('restricted wanted owner cannot mutate lifecycle or responses', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final listing = Listing(
      id: 'wanted-response-source',
      title: 'Restricted wanted',
      category: 'other',
      brand: 'NCU',
      direction: 'wanted',
      conditionScore: 6,
      suggestedPriceCny: 30,
      status: 'active',
      ownerId: 'requester-1',
      restrictionState: 'restricted',
      restriction: const ListingRestriction(reason: 'policy'),
      availableActions: const {Listing.actionFulfill, Listing.actionDelete},
    );
    final api = _ListingApiService(
      listing: listing,
      currentUserId: 'requester-1',
      wantedResponses: [
        _wantedResponse(availableActions: const {'accept', 'dismiss'}),
      ],
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: listing,
        currentUserId: 'requester-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('listing-fulfill-action')), findsNothing);
    expect(find.byKey(const Key('listing-delete-action')), findsOneWidget);
    expect(find.byKey(const Key('listing-relist-action')), findsNothing);
    expect(
      find.byKey(const ValueKey('wanted-response-accept-response-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
      findsNothing,
    );
  });

  testWidgets('owner delete is shown only when authorized by the server', (
    tester,
  ) async {
    final listing = Listing(
      id: 'listing-owner-delete',
      title: 'Owner listing',
      category: 'other',
      brand: 'NCU',
      conditionScore: 7,
      suggestedPriceCny: 12,
      status: 'active',
      ownerId: 'owner-1',
      availableActions: const {Listing.actionDelete},
    );
    final api = _ListingApiService(listing: listing, currentUserId: 'owner-1');
    await tester.pumpWidget(
      _buildDetail(listing: listing, currentUserId: 'owner-1', apiService: api),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('listing-delete-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('listing-delete-confirm')));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
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

  testWidgets('wanted owner can accept a received offer recommendation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wanted = _wantedListing();
    final response = _wantedResponse(
      lifecycleEpoch: 1,
      currentLifecycleEpoch: 1,
      roundState: 'current',
      availableActions: const {'accept', 'dismiss'},
    );
    final api = _ListingApiService(
      listing: wanted,
      currentUserId: 'requester-1',
      wantedResponses: [response],
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: wanted,
        currentUserId: 'requester-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();

    expect(api.wantedResponseRole, 'requester');
    expect(api.wantedResponseListingId, wanted.id);
    expect(find.textContaining(response.offerTitle), findsOneWidget);
    final accept = find.byKey(
      const ValueKey('wanted-response-accept-response-1'),
    );
    await tester.scrollUntilVisible(
      accept,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(accept);
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(
      tester.element(find.byType(ListingDetailPage)),
    )!;
    expect(api.wantedResponseActions, ['accepted:response-1']);
    expect(find.text(l.wantedResponseStatusAccepted), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wanted-response-accept-response-1')),
      findsNothing,
    );
  });

  testWidgets('failed wanted response action preserves the pending card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wanted = _wantedListing();
    final response = _wantedResponse();
    final api = _ListingApiService(
      listing: wanted,
      currentUserId: 'requester-1',
      wantedResponses: [response],
      failWantedAction: true,
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: wanted,
        currentUserId: 'requester-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();
    final accept = find.byKey(
      const ValueKey('wanted-response-accept-response-1'),
    );
    await tester.scrollUntilVisible(
      accept,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(api.wantedResponseActions, ['accepted:response-1']);
    expect(
      find.byKey(const ValueKey('wanted-response-response-1')),
      findsOneWidget,
    );
    expect(accept, findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets(
    'fulfilled wanted keeps closed-round response history read-only',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wanted = _wantedListing(status: 'fulfilled');
      final response = _wantedResponse(
        wantedStatus: 'fulfilled',
        lifecycleEpoch: 1,
        currentLifecycleEpoch: 1,
        roundState: 'closed',
        availableActions: const <String>{},
      );
      final api = _ListingApiService(
        listing: wanted,
        currentUserId: 'responder-1',
        wantedResponses: [response],
      );

      await tester.pumpWidget(
        _buildDetail(
          listing: wanted,
          currentUserId: 'responder-1',
          apiService: api,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ListingDetailPage)),
      )!;

      expect(api.wantedResponseRole, 'responder');
      expect(find.text(l.recommendMyOffer), findsNothing);
      expect(find.text(l.wantedClosedResponderHint), findsOneWidget);
      expect(find.text(l.wantedResponseClosedRoundLabel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wanted-response-withdraw-response-1')),
        findsNothing,
      );
      expect(api.wantedResponseActions, isEmpty);
    },
  );

  testWidgets('current-round responder can withdraw a sent recommendation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wanted = _wantedListing();
    final response = _wantedResponse(
      lifecycleEpoch: 2,
      currentLifecycleEpoch: 2,
      roundState: 'current',
      availableActions: const {'withdraw'},
    );
    final api = _ListingApiService(
      listing: wanted,
      currentUserId: 'responder-1',
      wantedResponses: [response],
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: wanted,
        currentUserId: 'responder-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();
    final withdraw = find.byKey(
      const ValueKey('wanted-response-withdraw-response-1'),
    );
    await tester.scrollUntilVisible(
      withdraw,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(withdraw);
    await tester.pumpAndSettle();

    expect(api.wantedResponseActions, ['withdrawn:response-1']);
    final l = AppLocalizations.of(
      tester.element(find.byType(ListingDetailPage)),
    )!;
    expect(find.text(l.wantedResponseStatusWithdrawn), findsOneWidget);
  });

  testWidgets(
    'reopened wanted keeps the previous response read-only but allows a new recommendation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wanted = _wantedListing();
      final response = _wantedResponse(
        lifecycleEpoch: 1,
        currentLifecycleEpoch: 2,
        roundState: 'closed',
        availableActions: const <String>{},
      );
      final api = _ListingApiService(
        listing: wanted,
        currentUserId: 'responder-1',
        wantedResponses: [response],
      );

      await tester.pumpWidget(
        _buildDetail(
          listing: wanted,
          currentUserId: 'responder-1',
          apiService: api,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ListingDetailPage)),
      )!;

      expect(find.text(l.wantedResponseClosedRoundLabel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wanted-response-withdraw-response-1')),
        findsNothing,
      );
      expect(find.text(l.recommendMyOffer), findsOneWidget);
    },
  );

  testWidgets('wanted recommendation retry reuses its idempotency key', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final wanted = _wantedListing();
    final api = _ListingApiService(
      listing: wanted,
      currentUserId: 'responder-1',
      wantedRecommendationFailuresRemaining: 1,
      userListingItems: const [
        {
          'id': 'offer-retry',
          'title': '可重试的机械键盘',
          'category': 'electronics',
          'brand': 'NCU',
          'direction': 'offer',
          'condition_score': 8,
          'suggested_price_cny': 120,
          'status': 'active',
          'owner_id': 'responder-1',
        },
      ],
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: wanted,
        currentUserId: 'responder-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(ListingDetailPage)),
    )!;

    Future<void> recommendOnce() async {
      await tester.tap(find.text(l.recommendMyOffer));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可重试的机械键盘'));
      await tester.pumpAndSettle();
    }

    await recommendOnce();
    expect(find.textContaining('offline'), findsOneWidget);
    expect(api.wantedRecommendationIdempotencyKeys, hasLength(1));
    final firstKey = api.wantedRecommendationIdempotencyKeys.single;
    expect(firstKey, isNotNull);
    expect(firstKey, isNotEmpty);

    await recommendOnce();
    expect(api.wantedRecommendationIdempotencyKeys, hasLength(2));
    expect(api.wantedRecommendationIdempotencyKeys.last, firstKey);
  });

  testWidgets(
    'closed-round conflict refreshes detail and leaves the row read-only',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final wanted = _wantedListing();
      final response = _wantedResponse(
        lifecycleEpoch: 2,
        currentLifecycleEpoch: 2,
        roundState: 'current',
        availableActions: const {'accept', 'dismiss'},
      );
      final api = _ListingApiService(
        listing: wanted,
        currentUserId: 'requester-1',
        wantedResponses: [response],
        wantedActionConflictCode: 'wanted_response_round_closed',
        listingAfterWantedActionConflict: _wantedListing(status: 'fulfilled'),
      );

      await tester.pumpWidget(
        _buildDetail(
          listing: wanted,
          currentUserId: 'requester-1',
          apiService: api,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ListingDetailPage)),
      )!;
      final accept = find.byKey(
        const ValueKey('wanted-response-accept-response-1'),
      );
      await tester.scrollUntilVisible(
        accept,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(accept);
      await tester.pumpAndSettle();

      expect(api.wantedResponseActions, ['accepted:response-1']);
      expect(api.listingDetailCalls, 2);
      expect(api.wantedResponseListCalls, 2);
      expect(find.text(l.wantedResponseRoundClosedToast), findsOneWidget);
      expect(find.text(l.wantedResponseClosedRoundLabel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wanted-response-accept-response-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
        findsNothing,
      );
      expect(find.text(l.reopenWantedAction), findsOneWidget);
    },
  );

  testWidgets('fulfilling a wanted listing requires explicit confirmation', (
    tester,
  ) async {
    final wanted = _wantedListing();
    final api = _ListingApiService(
      listing: wanted,
      currentUserId: 'requester-1',
    );

    await tester.pumpWidget(
      _buildDetail(
        listing: wanted,
        currentUserId: 'requester-1',
        apiService: api,
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(ListingDetailPage)),
    )!;

    await tester.tap(find.text(l.fulfillWantedAction));
    await tester.pumpAndSettle();
    expect(find.text(l.wantedFulfillConfirmTitle), findsOneWidget);
    expect(api.fulfillCalls, 0);

    await tester.tap(find.text(l.cancel));
    await tester.pumpAndSettle();
    expect(api.fulfillCalls, 0);

    await tester.tap(find.text(l.fulfillWantedAction));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wanted-fulfill-confirm')));
    await tester.pumpAndSettle();

    expect(api.fulfillCalls, 1);
  });

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
