import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/platform_utils.dart';

/// User behavior analytics service.
/// Tracks impressions, clicks, and negotiation events.
/// Gracefully degrades if backend is not available.
class AnalyticsService {
  static String get _baseUrl => getApiBaseUrl();
  static const String _endpoint = '/api/analytics/events';

  /// Track a listing impression (浏览曝光).
  /// Fire-and-forget: errors are logged but not thrown.
  Future<void> trackImpression(String listingId) async {
    await _track('impression', listingId);
  }

  /// Track a listing click (点击).
  /// Fire-and-forget: errors are logged but not thrown.
  Future<void> trackClick(String listingId) async {
    await _track('click', listingId);
  }

  /// Track a negotiation initiation (发起议价).
  /// Fire-and-forget: errors are logged but not thrown.
  Future<void> trackNegotiate(String listingId) async {
    await _track('negotiate', listingId);
  }

  Future<void> _track(String eventType, String listingId) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl$_endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'event_type': eventType,
              'listing_id': listingId,
              'timestamp': DateTime.now().toUtc().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint(
          '[Analytics] Event $eventType failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      // Graceful degradation: analytics failure should not affect user experience.
      debugPrint(
        '[Analytics] Event $eventType for listing $listingId failed: $e',
      );
    }
  }
}
