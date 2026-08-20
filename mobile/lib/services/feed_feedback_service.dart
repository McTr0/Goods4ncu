import 'dart:convert';

import 'package:http/http.dart' as http;

import 'base_service.dart';

enum FeedResourceType {
  listing('listing'),
  post('post');

  const FeedResourceType(this.wire);

  final String wire;
}

enum FeedFeedbackAction {
  hide('hide'),
  lessLikeThis('less_like_this'),
  notRelevant('not_relevant');

  const FeedFeedbackAction(this.wire);

  final String wire;
}

class FeedPreferences {
  const FeedPreferences({required this.personalizationEnabled});

  final bool personalizationEnabled;

  factory FeedPreferences.fromJson(Map<String, dynamic> json) =>
      FeedPreferences(
        personalizationEnabled: json['personalization_enabled'] != false,
      );
}

/// User controls for recommendation and intent feeds.
///
/// Feedback is deliberately separate from analytics events: every call here
/// represents an explicit instruction from the user and must take effect on
/// what they see next.
class FeedFeedbackService extends BaseService {
  Future<void> submitFeedback({
    required FeedResourceType resourceType,
    required String resourceId,
    required FeedFeedbackAction action,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/feed/feedback'),
      headers,
      jsonEncode({
        'resource_type': resourceType.wire,
        'resource_id': resourceId,
        'action': action.wire,
      }),
    );
    _ensureSuccess(response);
  }

  Future<FeedPreferences> getPreferences() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/feed/preferences'),
      headers,
    );
    return handleResponse(
      response,
      (data) => FeedPreferences.fromJson(
        (data as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );
  }

  Future<FeedPreferences> updatePersonalization(bool enabled) async {
    final headers = await authHeaders();
    final response = await put(
      Uri.parse('$baseUrl/api/feed/preferences'),
      headers,
      jsonEncode({'personalization_enabled': enabled}),
    );
    return handleResponse(
      response,
      (data) => FeedPreferences.fromJson(
        (data as Map<Object?, Object?>).cast<String, dynamic>(),
      ),
    );
  }

  Future<void> clearPersonalization() async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/feed/personalization/clear'),
      headers,
      jsonEncode(const <String, dynamic>{}),
    );
    _ensureSuccess(response);
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode == 200) return;
    handleResponse<void>(response, (_) {});
  }
}
