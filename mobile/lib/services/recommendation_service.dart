import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/platform_utils.dart';
import '../models/models.dart';

/// Service for fetching personalized recommendations via embedding similarity.
class RecommendationService {
  static String get _baseUrl => getApiBaseUrl();

  Future<http.Response> _getPublicRecommendation(Uri uri) =>
      http.get(uri, headers: const {'Accept': 'application/json'});

  /// GET /api/recommendations/similar?listing_id=xxx
  /// Returns Top-10 similar listings based on pgvector cosine similarity.
  Future<List<Listing>> getSimilarListings(String listingId) async {
    final response = await _getPublicRecommendation(
      Uri.parse('$_baseUrl/api/recommendations/similar?listing_id=$listingId'),
    );

    if (response.statusCode == 401) {
      throw Exception('请先登录');
    }
    if (response.statusCode != 200) {
      throw Exception('获取推荐失败: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => Listing.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/recommendations/feed
  /// Returns personalized recommendation feed for the home page.
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await _getPublicRecommendation(
      Uri.parse(
        '$_baseUrl/api/recommendations/feed?limit=$limit&offset=$offset',
      ),
    );

    if (response.statusCode == 401) {
      // Not logged in — return empty list, caller should not show carousel
      return [];
    }
    if (response.statusCode != 200) {
      throw Exception('获取推荐失败: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => Listing.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
