import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/watchlist_service.dart';
import 'package:http/http.dart' as http;

class _FakeWatchlistService extends WatchlistService {
  Uri? lastGetUri;
  Uri? lastPostUri;
  Uri? lastDeleteUri;
  http.Response getResponse = http.Response('{}', 200);
  http.Response postResponse = http.Response('{}', 200);
  http.Response deleteResponse = http.Response('{}', 200);

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastGetUri = url;
    return getResponse;
  }

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    lastPostUri = url;
    return postResponse;
  }

  @override
  Future<http.Response> delete(
    Uri url,
    Map<String, String> headers, {
    bool allowAuthRetry = true,
  }) async {
    lastDeleteUri = url;
    return deleteResponse;
  }
}

void main() {
  group('WatchlistService', () {
    test(
      'getWatchlist builds limit/offset query and parses response',
      () async {
        final service = _FakeWatchlistService();
        service.getResponse = http.Response(
          jsonEncode({
            'items': [
              {
                'listing_id': 'listing-1',
                'title': 'MacBook Air',
                'category': 'electronics',
                'brand': 'Apple',
                'condition_score': 8,
                'suggested_price_cny': 5999.0,
                'status': 'active',
                'owner_id': 'owner-1',
                'created_at': '2026-03-01T08:00:00Z',
              },
            ],
            'total': 1,
            'limit': 10,
            'offset': 20,
          }),
          200,
        );

        final response = await service.getWatchlist(limit: 10, offset: 20);

        expect(service.lastGetUri, isNotNull);
        expect(service.lastGetUri!.path, '/api/watchlist');
        expect(service.lastGetUri!.queryParameters['limit'], '10');
        expect(service.lastGetUri!.queryParameters['offset'], '20');

        expect(response.total, 1);
        expect(response.limit, 10);
        expect(response.offset, 20);
        expect(response.items.length, 1);
        expect(response.items.first.listingId, 'listing-1');
      },
    );

    test('isWatched returns false when watched field is missing', () async {
      final service = _FakeWatchlistService();
      service.getResponse = http.Response(jsonEncode({}), 200);

      final watched = await service.isWatched('listing-2');

      expect(service.lastGetUri, isNotNull);
      expect(service.lastGetUri!.path, '/api/watchlist/listing-2');
      expect(watched, isFalse);
    });

    test(
      'encodes listing IDs with reserved characters in path segment',
      () async {
        final service = _FakeWatchlistService();
        const listingId = 'id with space/and/slash';

        await service.addToWatchlist(listingId);
        await service.removeFromWatchlist(listingId);
        await service.isWatched(listingId);

        expect(service.lastPostUri, isNotNull);
        expect(service.lastDeleteUri, isNotNull);
        expect(service.lastGetUri, isNotNull);

        final postSegments = service.lastPostUri!.pathSegments;
        final deleteSegments = service.lastDeleteUri!.pathSegments;
        final getSegments = service.lastGetUri!.pathSegments;

        expect(postSegments.length, 3);
        expect(deleteSegments.length, 3);
        expect(getSegments.length, 3);
        expect(postSegments.last, listingId);
        expect(deleteSegments.last, listingId);
        expect(getSegments.last, listingId);
      },
    );
  });
}
