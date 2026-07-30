import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:http/http.dart' as http;

class _FakeRecommendationService extends RecommendationService {
  http.Response response = http.Response('{}', 200);
  Uri? lastUri;

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastUri = url;
    return response;
  }
}

void main() {
  test('similar recommendations preserve envelope ranking metadata', () async {
    final service = _FakeRecommendationService()
      ..response = http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'similar-1',
              'title': '相似教材',
              'category': 'books',
              'brand': 'NCU',
              'direction': 'offer',
              'condition_score': 8,
              'suggested_price_cny': 20,
              'status': 'active',
              'rank_reason': 'semantic_similarity',
              'match_summary': ['semantic_similarity'],
              'source': 'vector_similarity',
            },
          ],
          'ranking_version': '2026.07-similar-feedback-v1',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

    final items = await service.getSimilarListings('source-1');

    expect(service.lastUri?.path, '/api/recommendations/similar');
    expect(service.lastUri?.queryParameters['listing_id'], 'source-1');
    expect(items.single.rankReason, 'semantic_similarity');
    expect(items.single.rankingVersion, '2026.07-similar-feedback-v1');
  });
}
