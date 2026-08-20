import 'dart:convert';

import '../models/post.dart';
import 'base_service.dart';

/// Unified discussion/discovery API. Marketplace listings are projected into
/// this service by the backend, but listing writes remain in ListingService.
class PostService extends BaseService {
  Future<PostsResponse> getPosts({
    int limit = 20,
    int offset = 0,
    String postType = 'all',
    String? direction,
    String? category,
    String? search,
    String sort = 'for_you',
  }) async {
    final headers = await authHeaders();
    final params = <String, String>{
      'limit': limit.clamp(1, 100).toString(),
      'offset': offset.clamp(0, 1 << 31).toString(),
      'post_type': postType,
      'sort': sort,
      if (direction != null && direction.trim().isNotEmpty)
        'direction': direction.trim(),
      if (category != null && category.trim().isNotEmpty)
        'category': category.trim(),
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

  Future<CampusPost> createPost({
    required String title,
    required String body,
    String? category,
    List<String> tags = const [],
    String? coverImageUrl,
    String postKind = 'discussion',
    Map<String, dynamic> mutualAidMetadata = const {},
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/posts'),
      headers,
      jsonEncode({
        'title': title.trim(),
        'body': body.trim(),
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        if (coverImageUrl != null && coverImageUrl.trim().isNotEmpty)
          'cover_image_url': coverImageUrl.trim(),
        'post_kind': postKind,
        'mutual_aid_metadata': mutualAidMetadata,
        'tags': tags
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList(growable: false),
      }),
    );
    return handleResponse(
      response,
      (data) => CampusPost.fromJson(
        Map<String, dynamic>.from((data as Map)['post'] ?? data),
      ),
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
      (data) => PostReply.fromJson(
        Map<String, dynamic>.from((data as Map)['reply'] ?? data),
      ),
    );
  }

  Future<CampusPost> updatePost(
    String id, {
    String? title,
    String? body,
    String? category,
    List<String>? tags,
    bool? locked,
    String? postKind,
    Map<String, dynamic>? mutualAidMetadata,
  }) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}'),
      headers,
      jsonEncode({
        if (title != null) 'title': title.trim(),
        if (body != null) 'body': body.trim(),
        if (category != null) 'category': category.trim(),
        'tags': ?tags,
        'locked': ?locked,
        'post_kind': ?postKind,
        'mutual_aid_metadata': ?mutualAidMetadata,
      }),
    );
    return handleResponse(
      response,
      (data) => CampusPost.fromJson(
        Map<String, dynamic>.from((data as Map)['post'] ?? data),
      ),
    );
  }

  Future<CampusPost> updateResolution(
    String id,
    String resolutionStatus,
  ) async {
    final headers = await authHeaders();
    final response = await patch(
      Uri.parse('$baseUrl/api/posts/${Uri.encodeComponent(id)}/resolution'),
      headers,
      jsonEncode({'resolution_status': resolutionStatus}),
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
