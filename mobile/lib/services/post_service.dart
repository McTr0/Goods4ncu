import 'dart:convert';

import '../models/post.dart';
import 'base_service.dart';

/// Unified discussion/discovery API. Marketplace listings are projected into
/// this service by the backend, but listing writes remain in ListingService.
class PostService extends BaseService {
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,

    /// offer | wanted | discussion | all
    String category = 'all',
    String? spaceId,
    String? search,
    List<String> tags = const [],
    String sort = 'for_you',
  }) async {
    final headers = await authHeaders();
    final params = <String, String>{
      'limit': limit.clamp(1, 100).toString(),
      'offset': offset.clamp(0, 1 << 31).toString(),
      'category': category,
      'space_id': ?spaceId,
      if (tags.isNotEmpty) 'tags': tags.join(','),
      'sort': sort,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
    };
    final uri = Uri.parse(
      '$baseUrl/api/posts',
    ).replace(queryParameters: params);
    var response = await get(uri, headers);
    if (response.statusCode == 401 && headers.containsKey('Authorization')) {
      response = await get(uri, const {'Accept': 'application/json'});
    }
    return handleResponse(
      response,
      (data) => PostsResponse.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// GET /api/user/posts — the caller's unified posts (manager view).
  Future<Map<String, dynamic>> getUserPosts({
    String status = 'all',
    int limit = 100,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/user/posts',
    ).replace(queryParameters: {'status': status, 'limit': '$limit'});
    final response = await get(uri, headers);
    return handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  Future<CampusPost> getPost(String id) async {
    return _getPostAt(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}'),
    );
  }

  Future<CampusPost> getPostByListing(String listingId) async {
    return _getPostAt(
      Uri.parse(
        '$baseUrl/api/posts/by-listing/${Uri.encodeComponent(listingId)}',
      ),
    );
  }

  Future<CampusPost> _getPostAt(Uri uri) async {
    final headers = await authHeaders();
    var response = await get(uri, headers);
    if (response.statusCode == 401 && headers.containsKey('Authorization')) {
      response = await get(uri, const {'Accept': 'application/json'});
    }
    return handleResponse(
      response,
      (data) => CampusPost.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<PostRepliesResponse> getReplies(
    String postId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri =
        Uri.parse(
          '$baseUrl/api/posts/${Uri.encodeComponent(postId)}/replies',
        ).replace(
          queryParameters: {
            'limit': limit.clamp(1, 100).toString(),
            'offset': offset.clamp(0, 1 << 31).toString(),
          },
        );
    var response = await get(uri, headers);
    if (response.statusCode == 401 && headers.containsKey('Authorization')) {
      response = await get(uri, const {'Accept': 'application/json'});
    }
    return handleResponse(
      response,
      (data) =>
          PostRepliesResponse.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  /// GET /api/camphor — settles today's grant and returns the balance.
  Future<int> getCamphorBalance() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/camphor'), headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return (data['balance'] as num?)?.toInt() ?? 0;
  }

  /// POST /api/posts/{id}/fertilize — spend one leaf on a post.
  Future<Map<String, dynamic>> fertilizePost(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}/fertilize'),
      headers,
      '',
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return {
      'balance': (data['balance'] as num?)?.toInt() ?? 0,
      'fertilizer_count': (data['fertilizer_count'] as num?)?.toInt() ?? 0,
    };
  }

  Future<CampusPost> createPost({
    required String title,
    required String body,
    required String category,
    List<String> tags = const [],
    String? coverImageUrl,
    String? listingId,
    String? spaceId,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/posts'),
      headers,
      jsonEncode({
        'title': title.trim(),
        'body': body.trim(),
        'category': category,
        if (coverImageUrl != null && coverImageUrl.trim().isNotEmpty)
          'cover_image_url': coverImageUrl.trim(),
        'listing_id': ?listingId,
        'space_id': ?spaceId,
        'tags': tags
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList(growable: false),
      }),
    );
    return handleResponse(
      response,
      (data) => CampusPost.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<PostReply> createReply(
    String postId, {
    required String body,
    String? replyToId,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(postId)}/replies'),
      headers,
      jsonEncode({
        'body': body.trim(),
        if (replyToId != null && replyToId.trim().isNotEmpty)
          'reply_to_id': replyToId,
      }),
    );
    return handleResponse(
      response,
      (data) => PostReply.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<CampusPost> updatePost(
    String id, {
    String? title,
    String? body,
    List<String>? tags,
  }) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}'),
      headers,
      jsonEncode({
        if (title != null) 'title': title.trim(),
        if (body != null) 'body': body.trim(),
        'tags': ?tags,
      }),
    );
    return handleResponse(
      response,
      (data) => CampusPost.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<void> deletePost(String id) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}'),
      headers,
    );
    handleResponse(response, (_) {});
  }

  Future<PostReply> updateReply(
    String postId,
    String replyId,
    String body,
  ) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse(
        '$baseUrl/api/posts/${Uri.encodeComponent(postId)}/replies/${Uri.encodeComponent(replyId)}',
      ),
      headers,
      jsonEncode({'body': body.trim()}),
    );
    return handleResponse(
      response,
      (data) => PostReply.fromJson(
        Map<String, dynamic>.from((data as Map)['reply'] ?? data),
      ),
    );
  }

  Future<void> deleteReply(String postId, String replyId) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse(
        '$baseUrl/api/posts/${Uri.encodeComponent(postId)}/replies/${Uri.encodeComponent(replyId)}',
      ),
      headers,
    );
    handleResponse(response, (_) {});
  }
}
