import 'dart:convert';
import '../models/models.dart';
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

class CampusMembership {
  const CampusMembership({
    required this.id,
    required this.campusId,
    required this.campusSlug,
    required this.campusNameZh,
    required this.campusNameEn,
    required this.status,
    required this.role,
  });

  final String id;
  final String campusId;
  final String campusSlug;
  final String campusNameZh;
  final String campusNameEn;
  final String status;
  final String role;

  bool get isVerified => status == 'verified';

  factory CampusMembership.fromJson(Map<String, dynamic> json) {
    return CampusMembership(
      id: json['id']?.toString() ?? '',
      campusId: json['campus_id']?.toString() ?? '',
      campusSlug: json['campus_slug']?.toString() ?? '',
      campusNameZh: json['campus_name_zh']?.toString() ?? '',
      campusNameEn: json['campus_name_en']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      role: json['role']?.toString() ?? 'member',
    );
  }
}

class CampusMembershipState {
  const CampusMembershipState({
    required this.items,
    required this.activeCampusId,
  });

  final List<CampusMembership> items;
  final String? activeCampusId;
}

class UserService extends BaseService {
  Future<Map<String, dynamic>> getAdminCapabilities() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/admin/capabilities'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get current user's profile.
  /// GET /api/user/profile
  Future<Map<String, dynamic>> getUserProfile() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/user/profile'), headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get the current user's private draft/published role presentation.
  /// GET /api/user/persona
  Future<SocialPersona?> getSocialPersona() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/user/persona'), headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    final persona = data['persona'];
    return persona is Map
        ? SocialPersona.fromJson(persona.cast<String, dynamic>())
        : null;
  }

  /// Read the server-owned role and skin catalog. This endpoint is public so
  /// the editor can render the same allow-list that the write path enforces.
  /// GET /api/persona/catalog
  Future<SocialPersonaCatalog> getSocialPersonaCatalog() async {
    final response = await get(Uri.parse('$baseUrl/api/persona/catalog'), {
      'Content-Type': 'application/json',
    });
    return handleResponse(
      response,
      (data) =>
          SocialPersonaCatalog.fromJson((data as Map).cast<String, dynamic>()),
    );
  }

  /// Get another user's published role presentation in the resolved campus.
  /// GET /api/users/{id}/persona
  Future<SocialPersona?> getPublicSocialPersona(String userId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/users/${Uri.encodeComponent(userId)}/persona'),
      headers,
    );
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    final persona = data['persona'];
    return persona is Map
        ? SocialPersona.fromJson(persona.cast<String, dynamic>())
        : null;
  }

  Future<Map<String, dynamic>> getModerationCases({
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (status != null && status.isNotEmpty) 'status': status,
    };
    final uri = Uri.parse(
      '$baseUrl/api/moderation/cases',
    ).replace(queryParameters: query);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> submitModerationAppeal(
    String caseId,
    String reason,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/moderation/cases/$caseId/appeals'),
      headers,
      jsonEncode({'reason': reason}),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get the current user's campus qualification records.
  /// GET /api/user/campus-memberships
  Future<List<CampusMembership>> getCampusMemberships() async {
    return (await getCampusMembershipState()).items;
  }

  Future<CampusMembershipState> getCampusMembershipState() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/user/campus-memberships'),
      headers,
    );
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    final items = (data['items'] as List<dynamic>? ?? const [])
        .map((item) => CampusMembership.fromJson(item as Map<String, dynamic>))
        .toList();
    return CampusMembershipState(
      items: items,
      activeCampusId: data['active_campus_id']?.toString(),
    );
  }

  /// Request a short-lived code for the membership's campus email.
  Future<void> requestCampusVerification(String membershipId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse(
        '$baseUrl/api/user/campus-memberships/$membershipId/verification/request',
      ),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Confirm the campus email code and return the activated membership.
  Future<CampusMembership> confirmCampusVerification(
    String membershipId,
    String code,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse(
        '$baseUrl/api/user/campus-memberships/$membershipId/verification/confirm',
      ),
      headers,
      jsonEncode({'code': code}),
    );
    return handleResponse(
      response,
      (data) => CampusMembership.fromJson(data as Map<String, dynamic>),
    );
  }

  /// Update current user's profile.
  /// PATCH /api/user/profile
  Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? email,
    Map<String, bool?>? discoverability,
    Map<String, dynamic>? paymentQr,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (email != null) body['email'] = email;
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
    String? status,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/user/listings').replace(
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    final response = await get(uri, headers);
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
