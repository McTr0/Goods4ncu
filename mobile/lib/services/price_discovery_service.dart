import 'dart:convert';

import '../models/models.dart';
import 'base_service.dart';

/// Private-limit price negotiation.
///
/// The limit is sent and never read back. There is no method here that returns
/// the other side's number, because the server has no endpoint that would — the
/// absence is the feature.
class PriceDiscoveryService extends BaseService {
  /// POST /api/price-discovery — ask the other side to settle it this way.
  Future<PriceDiscoveryResult> propose(String listingId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/price-discovery'),
      headers,
      jsonEncode({'listing_id': listingId}),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return PriceDiscoveryResult.fromJson(data);
  }

  /// GET /api/price-discovery/{id}
  Future<PriceDiscoveryResult> session(String sessionId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/price-discovery/$sessionId'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return PriceDiscoveryResult.fromJson(data);
  }

  /// POST /api/price-discovery/{id}/accept
  Future<PriceDiscoveryResult> accept(String sessionId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/price-discovery/$sessionId/accept'),
      headers,
      jsonEncode({}),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return PriceDiscoveryResult.fromJson(data);
  }

  /// POST /api/price-discovery/{id}/decline — keep haggling instead.
  Future<PriceDiscoveryResult> decline(String sessionId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/price-discovery/$sessionId/decline'),
      headers,
      jsonEncode({}),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return PriceDiscoveryResult.fromJson(data);
  }

  /// POST /api/price-discovery/{id}/limit — state your limit, in cents.
  ///
  /// One-way. The response says whether a deal exists and, if so, at what price;
  /// it never contains what either side said.
  Future<PriceDiscoveryResult> stateLimit(String sessionId, int cents) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/price-discovery/$sessionId/limit'),
      headers,
      jsonEncode({'cents': cents}),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return PriceDiscoveryResult.fromJson(data);
  }
}
