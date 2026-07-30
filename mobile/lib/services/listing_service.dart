import 'dart:convert';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'base_service.dart';

/// Listing service — handles marketplace browse, detail, create, update, delete.
class ListingService extends BaseService {
  /// Get paginated listings with optional filters.
  /// GET /api/listings
  ///
  /// Supports all backend filter parameters: [category], [categories] (multi),
  /// [minPriceCny], [maxPriceCny], [sort], [search], plus pagination [limit]/[offset].
  Future<ListingsResponse> getListings({
    int limit = 20,
    int offset = 0,
    String? category,
    String? search,
    List<String>? categories,
    double? minPriceCny,
    double? maxPriceCny,
    String sort = 'newest',
    String direction = 'offer',
  }) async {
    final headers = await authHeaders();
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (category != null) queryParams['category'] = category;
    if (search != null && search.isNotEmpty) queryParams['search'] = search;
    if (categories != null && categories.isNotEmpty) {
      queryParams['categories'] = categories.join(',');
    }
    if (minPriceCny != null) {
      queryParams['min_price_cny'] = minPriceCny.toString();
    }
    if (maxPriceCny != null) {
      queryParams['max_price_cny'] = maxPriceCny.toString();
    }
    if (sort != 'newest') queryParams['sort'] = sort;
    queryParams['direction'] = direction;

    final uri = Uri.parse(
      '$baseUrl/api/listings',
    ).replace(queryParameters: queryParams);
    var response = await get(uri, headers);
    if (response.statusCode == 401 && headers.containsKey('Authorization')) {
      response = await get(uri, const {'Accept': 'application/json'});
    }
    return handleResponse(response, (data) => ListingsResponse.fromJson(data));
  }

  /// Get single listing detail.
  /// GET /api/listings/{id}
  Future<Listing> getListingDetail(String id) async {
    final headers = await authHeaders();
    final uri = Uri.parse('$baseUrl/api/listings/$id');
    var response = await get(uri, headers);
    if (response.statusCode == 401 && headers.containsKey('Authorization')) {
      response = await get(uri, const {'Accept': 'application/json'});
    }
    return handleResponse(
      response,
      (data) => Listing.fromJson(data as Map<String, dynamic>),
    );
  }

  /// Create new listing.
  /// POST /api/listings
  Future<String> createListing({
    required String title,
    required String category,
    required String brand,
    required int conditionScore,
    required double suggestedPriceCny,
    required List<String> defects,
    String? description,
    String direction = 'offer',
    String? idempotencyKey,
  }) async {
    final headers = await authHeaders();
    headers['Idempotency-Key'] = idempotencyKey ?? const Uuid().v4();
    final response = await post(
      Uri.parse('$baseUrl/api/listings'),
      headers,
      jsonEncode({
        'title': title,
        'category': category,
        'brand': direction == 'wanted' && brand.trim().isEmpty ? '不限' : brand,
        'direction': direction,
        'condition_score': conditionScore,
        'suggested_price_cny': suggestedPriceCny,
        'defects': defects,
        'description': description,
      }),
    );
    return handleResponse(response, (data) => data['id'] ?? '');
  }

  /// Get active offers matching a wanted listing.
  Future<ListingsResponse> getWantedMatches(String wantedId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/listings/$wantedId/matches'),
      headers,
    );
    return handleResponse(response, (data) => ListingsResponse.fromJson(data));
  }

  /// Recommend one of the current user's active offers to a wanted listing.
  Future<String> recommendOfferForWanted({
    required String wantedId,
    required String offerListingId,
    String? message,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/listings/$wantedId/responses'),
      headers,
      jsonEncode({
        'offer_listing_id': offerListingId,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      }),
    );
    return handleResponse(response, (data) => data['message'] ?? '');
  }

  /// List explicit offer recommendations received for, or sent to, wanted
  /// listings owned by the current user.
  Future<WantedResponsesResponse> getWantedResponses({
    String role = 'requester',
    String? wantedListingId,
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final queryParameters = <String, String>{
      'role': role,
      'limit': limit.clamp(1, 100).toString(),
      'offset': offset.clamp(0, 1 << 31).toString(),
    };
    if (wantedListingId != null && wantedListingId.trim().isNotEmpty) {
      queryParameters['wanted_listing_id'] = wantedListingId.trim();
    }
    if (status != null && status.trim().isNotEmpty) {
      queryParameters['status'] = status.trim();
    }
    final uri = Uri.parse(
      '$baseUrl/api/wanted-responses',
    ).replace(queryParameters: queryParameters);
    final response = await get(uri, headers);
    return handleResponse(
      response,
      (data) => WantedResponsesResponse.fromJson(
        Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  Future<WantedResponseActionResult> acceptWantedResponse(String id) {
    return _actOnWantedResponse(id, 'accept');
  }

  Future<WantedResponseActionResult> dismissWantedResponse(String id) {
    return _actOnWantedResponse(id, 'dismiss');
  }

  Future<WantedResponseActionResult> withdrawWantedResponse(String id) {
    return _actOnWantedResponse(id, 'withdraw');
  }

  Future<WantedResponseActionResult> _actOnWantedResponse(
    String id,
    String action,
  ) async {
    final headers = await authHeaders();
    final encodedId = Uri.encodeComponent(id.trim());
    final response = await post(
      Uri.parse('$baseUrl/api/wanted-responses/$encodedId/$action'),
      headers,
      '{}',
    );
    return handleResponse(
      response,
      (data) => WantedResponseActionResult.fromJson(
        Map<String, dynamic>.from(data as Map),
      ),
    );
  }

  /// Update existing listing.
  /// PUT /api/listings/{id}
  Future<void> updateListing(String id, Map<String, dynamic> updates) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse('$baseUrl/api/listings/$id'),
      headers,
      jsonEncode(updates),
    );
    handleResponse(response, (_) {});
  }

  /// Mark a wanted item as fulfilled (owner only).
  /// POST /api/listings/{id}/fulfill
  Future<void> fulfillWanted(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/listings/$id/fulfill'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Reopen a sold/fulfilled/deleted listing (owner only).
  /// POST /api/listings/{id}/relist
  Future<void> relistListing(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/listings/$id/relist'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  /// Delete listing.
  /// DELETE /api/listings/{id}
  Future<void> deleteListing(String id) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/listings/$id'),
      headers,
    );
    handleResponse(response, (_) {});
  }

  /// Recognize item from image using AI.
  /// POST /api/listings/recognize
  Future<RecognizedItem> recognizeItem(String imageBase64) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/listings/recognize'),
      headers,
      jsonEncode({'image_base64': imageBase64}),
    );
    return handleResponse(response, (data) => RecognizedItem.fromJson(data));
  }
}

/// Item recognized from image AI analysis.
class RecognizedItem {
  final String title;
  final String category;
  final String brand;
  final int conditionScore;
  final List<String> defects;
  final String description;

  RecognizedItem({
    required this.title,
    required this.category,
    required this.brand,
    required this.conditionScore,
    required this.defects,
    required this.description,
  });

  factory RecognizedItem.fromJson(Map<String, dynamic> json) {
    return RecognizedItem(
      title: json['title'] ?? '',
      category: json['category'] ?? 'other',
      brand: json['brand'] ?? '',
      conditionScore: json['condition_score'] ?? 5,
      defects:
          (json['defects'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      description: json['description'] ?? '',
    );
  }
}
