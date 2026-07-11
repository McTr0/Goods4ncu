import 'dart:convert';
import '../models/models.dart';
import 'base_service.dart';

/// Negotiate service — handles HITL (Human-In-The-Loop) price negotiations.
class NegotiateService extends BaseService {
  /// List pending negotiation requests for the current user.
  /// Sellers see pending + expired; buyers see countered + approved + rejected + expired.
  /// GET /api/negotiations
  Future<List<HitlRequest>> getNegotiations() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/negotiations'), headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => HitlRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Seller responds to a pending negotiation.
  /// action: 'approve' | 'reject' | 'counter'
  /// counter_price: required when action == 'counter' (in yuan, not cents)
  /// PATCH /api/negotiations/{id}/respond
  Future<Map<String, dynamic>> respondNegotiation(
    String id, {
    required String action,
    double? counterPrice,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{'action': action};
    if (counterPrice != null) body['counter_price'] = counterPrice;
    final response = await patch(
      Uri.parse('$baseUrl/api/negotiations/$id/respond'),
      headers,
      jsonEncode(body),
    );
    return handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  /// Buyer accepts seller's counter-offer.
  /// PATCH /api/negotiations/{id}/accept
  Future<Map<String, dynamic>> acceptCounterNegotiation(String id) async {
    final headers = await authHeaders();
    final response = await patch(
      Uri.parse('$baseUrl/api/negotiations/$id/accept'),
      headers,
      '{}',
    );
    return handleResponse(response, (d) => d as Map<String, dynamic>);
  }

  /// Buyer rejects seller's counter-offer.
  /// PATCH /api/negotiations/{id}/reject
  Future<Map<String, dynamic>> rejectCounterNegotiation(String id) async {
    final headers = await authHeaders();
    final response = await patch(
      Uri.parse('$baseUrl/api/negotiations/$id/reject'),
      headers,
      '{}',
    );
    return handleResponse(response, (d) => d as Map<String, dynamic>);
  }
}
