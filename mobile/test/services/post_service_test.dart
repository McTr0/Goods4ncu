import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:http/http.dart' as http;

class _FakePostService extends PostService {
  http.Response response = http.Response('{}', 200);
  Uri? lastUri;
  String? lastBody;
  String? lastMethod;

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastMethod = 'GET';
    lastUri = url;
    return response;
  }

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    lastMethod = 'POST';
    lastUri = url;
    lastBody = body;
    return response;
  }
}

void main() {
  test('getPosts sends the unified post type and sort filters', () async {
    final service = _FakePostService()
      ..response = http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'post-1',
              'post_type': 'listing',
              'title': 'Textbook',
              'body_excerpt': 'Good condition',
              'tags': [],
              'listing_id': 'listing-1',
              'author': {'id': 'u-1', 'username': 'mira'},
              'reply_count': 2,
              'status': 'active',
              'is_locked': false,
            },
          ],
          'total': 1,
          'limit': 20,
          'offset': 0,
        }),
        200,
      );

    final response = await service.getPosts(
      postType: 'listing',
      sort: 'replies',
    );

    expect(service.lastMethod, 'GET');
    expect(service.lastUri?.path, '/api/posts');
    expect(service.lastUri?.queryParameters['post_type'], 'listing');
    expect(service.lastUri?.queryParameters['sort'], 'replies');
    expect(response.items.single.isListing, isTrue);
    expect(response.items.single.listingId, 'listing-1');
  });

  test('createReply posts body and reply target', () async {
    final service = _FakePostService()
      ..response = http.Response(
        jsonEncode({
          'id': 'reply-2',
          'post_id': 'post-1',
          'body': 'Helpful answer',
          'reply_to_id': 'reply-1',
          'author': {'id': 'u-2', 'username': 'lee'},
        }),
        200,
      );

    final reply = await service.createReply(
      'post-1',
      body: 'Helpful answer',
      replyToId: 'reply-1',
    );

    expect(service.lastMethod, 'POST');
    expect(service.lastUri?.path, '/api/posts/post-1/replies');
    expect(jsonDecode(service.lastBody!)['reply_to_id'], 'reply-1');
    expect(reply.id, 'reply-2');
  });
}
