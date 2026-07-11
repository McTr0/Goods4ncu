import 'dart:convert';

import 'base_service.dart';
import '../models/models.dart';

/// Service for fetching recommendations (similar listings + home feed).
///
/// Feed requests send an access token when available so the backend can
/// personalize ranking; anonymous callers still work without auth.
class RecommendationService extends BaseService {
  List<Listing> _parseItems(String body) {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => Listing.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/recommendations/similar?listing_id=xxx
  /// Returns Top-N similar listings based on pgvector cosine similarity.
  Future<List<Listing>> getSimilarListings(String listingId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/recommendations/similar?listing_id=$listingId'),
      headers,
    );

    if (response.statusCode == 401) {
      throw AuthException('请先登录');
    }
    if (response.statusCode != 200) {
      throw Exception('获取推荐失败: ${response.statusCode}');
    }

    try {
      return _parseItems(response.body);
    } catch (_) {
      throw ServerException(response.statusCode, '服务器返回数据格式错误');
    }
  }

  /// GET /api/recommendations/feed
  /// Returns the home recommendation feed (personalized when logged in).
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/recommendations/feed').replace(
      queryParameters: {
        'limit': limit.toString(),
        'offset': offset.toString(),
        'direction': direction,
      },
    );
    final response = await get(uri, headers);

    // Auth is optional: expired/missing tokens should not force a login wall.
    if (response.statusCode == 401) {
      return [];
    }
    if (response.statusCode != 200) {
      throw Exception('获取推荐失败: ${response.statusCode}');
    }

    try {
      return _parseItems(response.body);
    } catch (_) {
      throw ServerException(response.statusCode, '服务器返回数据格式错误');
    }
  }
}
