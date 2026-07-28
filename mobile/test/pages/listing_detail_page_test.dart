import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/listing_detail_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/content_report_service.dart';
import 'package:goods4ncu_mobile/services/order_service.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _ListingApiService extends ApiService {
  _ListingApiService({required this.listing, required this.currentUserId});

  final Listing listing;
  final String? currentUserId;

  @override
  Future<String?> getToken() async => currentUserId == null ? null : 'token';

  @override
  Future<Listing> getListingDetail(String id) async => listing;

  @override
  Future<Map<String, dynamic>> getUserProfile() async {
    if (currentUserId == null) throw StateError('guest has no profile');
    return {'user_id': currentUserId, 'username': 'owner'};
  }
}

class _EmptyRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getSimilarListings(String listingId) async => [];
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
      ),
      recommendationService: _EmptyRecommendationService(),
      orderService: OrderService(),
      chatService: ChatService(),
      contentReportService:
          contentReportService ?? _RecordingContentReportService(),
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
      _buildDetail(listing: listing, currentUserId: null),
    );
    await tester.pumpAndSettle();

    expect(find.text('Public listing'), findsWidgets);
    expect(find.byKey(const Key('listing-report-action')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
