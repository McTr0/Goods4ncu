import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'base_service.dart';

/// Order service — records offline deal intents and seller confirmations.
class OrderService extends BaseService {
  /// Get paginated orders for current user.
  /// GET /api/orders
  Future<Map<String, dynamic>> getOrders({
    String? role,
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (role != null) queryParams['role'] = role;
    final uri = Uri.parse(
      '$baseUrl/api/orders',
    ).replace(queryParameters: queryParams);
    final response = await get(uri, headers);
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Get single order detail.
  /// GET /api/orders/{id}
  Future<Map<String, dynamic>> getOrder(String orderId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/orders/$orderId'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Create a new offline deal intent.
  /// POST /api/orders
  Future<Map<String, dynamic>> createOrder({
    required String listingId,
    required double offeredPriceCny,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/orders'),
      headers,
      jsonEncode({
        'listing_id': listingId,
        'offered_price_cny': offeredPriceCny,
      }),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  /// Legacy endpoint: platform no longer intermediates payment.
  /// POST /api/orders/{id}/pay
  Future<void> payOrder(String orderId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/orders/$orderId/pay'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Legacy endpoint: platform no longer tracks logistics.
  /// POST /api/orders/{id}/ship
  Future<void> shipOrder(String orderId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/orders/$orderId/ship'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Seller confirms the offline deal.
  /// POST /api/orders/{id}/confirm
  Future<void> confirmOrder(
    String orderId, {
    bool autoDelist = true,
    String? idempotencyKey,
  }) async {
    final headers = await authHeaders();
    headers['Idempotency-Key'] = idempotencyKey ?? const Uuid().v4();
    final response = await post(
      Uri.parse('$baseUrl/api/orders/$orderId/confirm'),
      headers,
      jsonEncode({'auto_delist': autoDelist}),
    );
    handleResponse(response, (_) {});
  }

  /// Cancel an order.
  /// POST /api/orders/{id}/cancel
  Future<void> cancelOrder(String orderId, {String? reason}) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/orders/$orderId/cancel'),
      headers,
      jsonEncode({'reason': reason}),
    );
    handleResponse(response, (_) {});
  }
}
