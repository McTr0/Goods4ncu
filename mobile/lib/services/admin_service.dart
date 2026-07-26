import 'dart:convert';
import 'base_service.dart';

/// Admin service — handles administrative operations (admin role required).
class AdminService extends BaseService {
  /// Resolve authoritative admin capabilities for the active campus.
  Future<Map<String, dynamic>> getCapabilities() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/admin/capabilities'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get admin dashboard statistics.
  /// GET /api/admin/stats
  Future<Map<String, dynamic>> getAdminStats() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/admin/stats'), headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get all users with optional search query.
  /// GET /api/admin/users
  Future<Map<String, dynamic>> getAllUsers({
    String? q,
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (q != null && q.isNotEmpty) queryParams['q'] = q;
    final uri = Uri.parse(
      '$baseUrl/api/admin/users',
    ).replace(queryParameters: queryParams);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get detailed user profile.
  /// GET /api/admin/users/{id}
  Future<Map<String, dynamic>> getUserDetail(String userId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/admin/users/$userId'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Update user role.
  /// POST /api/admin/users/{id}/role
  Future<void> updateUserRole(String userId, String role) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/role'),
      headers,
      jsonEncode({'role': role}),
    );
    handleResponse(response, (_) {});
  }

  /// Ban a user.
  /// POST /api/admin/users/{id}/ban
  Future<void> banUser(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/ban'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Unban a user.
  /// POST /api/admin/users/{id}/unban
  Future<void> unbanUser(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/unban'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Impersonate a user.
  /// POST /api/admin/users/{id}/impersonate
  Future<Map<String, dynamic>> impersonateUser(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/impersonate'),
      headers,
      '{}',
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Impersonate a user and return the new token directly.
  /// POST /api/admin/users/{id}/impersonate
  Future<String> impersonateUserToken(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/impersonate'),
      headers,
      '{}',
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final token = data['token'] ?? '';
      if (token.isEmpty) throw Exception('Impersonation failed: no token');
      return token;
    } else {
      throw Exception('Impersonation failed: ${response.statusCode}');
    }
  }

  /// Revoke all tokens for a user (force logout).
  /// POST /api/admin/users/{id}/revoke_tokens
  Future<void> revokeUserTokens(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/users/$userId/revoke_tokens'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Get all listings (admin view).
  /// GET /api/admin/listings
  Future<Map<String, dynamic>> getAdminListings({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (status != null) queryParams['status'] = status;
    final uri = Uri.parse(
      '$baseUrl/api/admin/listings',
    ).replace(queryParameters: queryParams);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Take down a listing.
  /// POST /api/admin/listings/{id}/takedown
  Future<void> takedownListing(String listingId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/listings/$listingId/takedown'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Get paginated orders (admin view).
  /// GET /api/admin/orders
  Future<Map<String, dynamic>> getAdminOrders({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (status != null) queryParams['status'] = status;
    final uri = Uri.parse(
      '$baseUrl/api/admin/orders',
    ).replace(queryParameters: queryParams);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Update order status (admin).
  /// POST /api/admin/orders/{id}/status
  Future<void> updateAdminOrderStatus(
    String orderId,
    String status, {
    bool? autoDelist,
    String? reason,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{'status': status};
    if (autoDelist != null) body['auto_delist'] = autoDelist;
    if (reason != null) body['reason'] = reason;
    final response = await post(
      Uri.parse('$baseUrl/api/admin/orders/$orderId/status'),
      headers,
      jsonEncode(body),
    );
    handleResponse(response, (_) {});
  }

  Future<Map<String, dynamic>> getModerationCases({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (status != null && status.isNotEmpty) 'status': status,
    };
    final uri = Uri.parse(
      '$baseUrl/api/admin/moderation/cases',
    ).replace(queryParameters: query);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> reviewModerationCase(
    String caseId, {
    required String action,
    String? note,
    String? publicReason,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{
      'action': action,
      if (note != null && note.isNotEmpty) 'note': note,
      if (publicReason != null && publicReason.isNotEmpty)
        'public_reason': publicReason,
    };
    final response = await post(
      Uri.parse('$baseUrl/api/admin/moderation/cases/$caseId/review'),
      headers,
      jsonEncode(body),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> reviewModerationAppeal(
    String appealId, {
    required String decision,
    required String note,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/admin/moderation/appeals/$appealId/review'),
      headers,
      jsonEncode({'decision': decision, 'note': note}),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }
}
