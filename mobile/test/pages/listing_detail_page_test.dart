import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:good4ncu_mobile/l10n/app_localizations.dart';
import 'package:good4ncu_mobile/models/models.dart';
import 'package:good4ncu_mobile/pages/listing_detail_page.dart';
import 'package:good4ncu_mobile/services/api_service.dart';
import 'package:good4ncu_mobile/services/chat_service.dart';
import 'package:good4ncu_mobile/services/order_service.dart';
import 'package:good4ncu_mobile/services/recommendation_service.dart';
import 'package:good4ncu_mobile/theme/app_theme.dart';

class _ListingApiService extends ApiService {
  _ListingApiService({required this.listing, required this.currentUserId});

  final Listing listing;
  final String currentUserId;

  @override
  Future<Listing> getListingDetail(String id) async => listing;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => {
    'user_id': currentUserId,
    'username': 'owner',
  };
}

class _EmptyRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getSimilarListings(String listingId) async => [];
}

Widget _buildDetail({required Listing listing, required String currentUserId}) {
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
  });
}
