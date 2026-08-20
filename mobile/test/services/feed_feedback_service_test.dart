import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:http/http.dart' as http;

class _FakeFeedFeedbackService extends FeedFeedbackService {
  Uri? lastGetUri;
  Uri? lastPutUri;
  String? lastPutBody;
  final List<Uri> postUris = [];
  final List<String> postBodies = [];

  http.Response getResponse = http.Response('{}', 200);
  http.Response putResponse = http.Response('{}', 200);
  http.Response postResponse = http.Response('{}', 200);

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastGetUri = url;
    return getResponse;
  }

  @override
  Future<http.Response> put(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    lastPutUri = url;
    lastPutBody = body;
    return putResponse;
  }

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    postUris.add(url);
    postBodies.add(body);
    return postResponse;
  }
}

void main() {
  group('FeedFeedbackService', () {
    test('submits the documented resource and action wires', () async {
      final service = _FakeFeedFeedbackService();

      await service.submitFeedback(
        resourceType: FeedResourceType.post,
        resourceId: 'post-1',
        action: FeedFeedbackAction.lessLikeThis,
      );

      expect(service.postUris.single.path, '/api/feed/feedback');
      expect(jsonDecode(service.postBodies.single), {
        'resource_type': 'post',
        'resource_id': 'post-1',
        'action': 'less_like_this',
      });
    });

    test('loads personalization preferences', () async {
      final service = _FakeFeedFeedbackService()
        ..getResponse = http.Response(
          jsonEncode({'personalization_enabled': false}),
          200,
        );

      final preferences = await service.getPreferences();

      expect(service.lastGetUri?.path, '/api/feed/preferences');
      expect(preferences.personalizationEnabled, isFalse);
    });

    test('updates preferences and clears learned signals', () async {
      final service = _FakeFeedFeedbackService()
        ..putResponse = http.Response(
          jsonEncode({'personalization_enabled': false}),
          200,
        );

      final preferences = await service.updatePersonalization(false);
      await service.clearPersonalization();

      expect(service.lastPutUri?.path, '/api/feed/preferences');
      expect(jsonDecode(service.lastPutBody!), {
        'personalization_enabled': false,
      });
      expect(preferences.personalizationEnabled, isFalse);
      expect(service.postUris.last.path, '/api/feed/personalization/clear');
      expect(jsonDecode(service.postBodies.last), isEmpty);
    });
  });
}
