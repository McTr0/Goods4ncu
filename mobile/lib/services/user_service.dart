import 'dart:convert';
import 'base_service.dart';

/// STS token response from GET /api/upload/token
class StsToken {
  final String accessKeyId;
  final String accessKeySecret;
  final String securityToken;
  final String expiration;
  final String endpoint;
  final String bucket;

  StsToken({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.securityToken,
    required this.expiration,
    required this.endpoint,
    required this.bucket,
  });

  factory StsToken.fromJson(Map<String, dynamic> json) {
    return StsToken(
      accessKeyId: json['access_key_id'] as String,
      accessKeySecret: json['access_key_secret'] as String,
      securityToken: json['security_token'] as String,
      expiration: json['expiration'] as String,
      endpoint: json['endpoint'] as String,
      bucket: json['bucket'] as String,
    );
  }
}

/// User service — handles profile, listings, public profile, and search.
class UserLookupMatch {
  const UserLookupMatch({
    required this.userId,
    required this.username,
    required this.matchedBy,
    required this.listingCount,
    required this.canStartConversation,
    this.maskedIdentifier,
  });

  final String userId;
  final String username;
  final String matchedBy;
  final String? maskedIdentifier;
  final int listingCount;
  final bool canStartConversation;

  factory UserLookupMatch.fromJson(Map<String, dynamic> json) {
    return UserLookupMatch(
      userId: json['user_id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      matchedBy: json['matched_by']?.toString() ?? 'username',
      maskedIdentifier: json['masked_identifier']?.toString(),
      listingCount: (json['listing_count'] as num?)?.toInt() ?? 0,
      canStartConversation: json['can_start_conversation'] != false,
    );
  }
}

class UserService extends BaseService {
  /// Get current user's profile.
  /// GET /api/user/profile
  Future<Map<String, dynamic>> getUserProfile() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/user/profile'), headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Update current user's profile.
  /// PATCH /api/user/profile
  Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? email,
    String? avatarUrl,
    Map<String, bool?>? discoverability,
    String? chatReadReceiptMode,
    Map<String, dynamic>? paymentQr,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (email != null) body['email'] = email;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    if (chatReadReceiptMode != null) {
      body['chat_read_receipt_mode'] = chatReadReceiptMode;
    }
    if (discoverability != null) {
      body['discoverability'] = {
        if (discoverability.containsKey('username'))
          'username': discoverability['username'],
        if (discoverability.containsKey('email'))
          'email': discoverability['email'],
        if (discoverability.containsKey('student_id'))
          'student_id': discoverability['student_id'],
      };
    }
    if (paymentQr != null) {
      body['payment_qr'] = {
        if (paymentQr.containsKey('wechat_url'))
          'wechat_url': paymentQr['wechat_url'],
        if (paymentQr.containsKey('alipay_url'))
          'alipay_url': paymentQr['alipay_url'],
        if (paymentQr.containsKey('show_wechat'))
          'show_wechat': paymentQr['show_wechat'],
        if (paymentQr.containsKey('show_alipay'))
          'show_alipay': paymentQr['show_alipay'],
      };
    }
    final response = await patch(
      Uri.parse('$baseUrl/api/user/profile'),
      headers,
      jsonEncode(body),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get STS upload token for direct OSS upload.
  /// GET /api/upload/token
  Future<StsToken> getUploadToken() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/upload/token'), headers);
    return handleResponse(
      response,
      (data) => StsToken.fromJson(data as Map<String, dynamic>),
    );
  }

  /// Get current user's listings.
  /// GET /api/user/listings
  Future<Map<String, dynamic>> getUserListings({
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/user/listings?limit=$limit&offset=$offset'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get public user profile.
  /// GET /api/users/{id}
  Future<Map<String, dynamic>> getPublicUserProfile(String userId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/users/$userId'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get a user's public active listings.
  /// GET /api/users/{id}/listings
  Future<Map<String, dynamic>> getPublicUserListings(
    String userId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/users/$userId/listings',
    ).replace(queryParameters: {'limit': '$limit', 'offset': '$offset'});
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Privacy-aware lookup for starting a direct conversation.
  /// GET /api/users/lookup
  Future<List<UserLookupMatch>> lookupUsers(
    String query, {
    String method = 'auto',
    int limit = 10,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/users/lookup').replace(
      queryParameters: {'q': query, 'method': method, 'limit': '$limit'},
    );
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .map((item) => UserLookupMatch.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Search users by username.
  /// GET /api/users/search
  Future<Map<String, dynamic>> searchUsers(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/users/search').replace(
      queryParameters: {'q': query, 'limit': '$limit', 'offset': '$offset'},
    );
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }
}
