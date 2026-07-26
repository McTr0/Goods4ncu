import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/notification_service.dart';
import 'package:http/http.dart' as http;

class _FakeNotificationService extends NotificationService {
  Uri? lastGetUri;
  final List<Uri> postUris = [];

  http.Response notificationsResponse = http.Response('{}', 200);
  http.Response markReadResponse = http.Response('{}', 200);
  http.Response markAllResponse = http.Response('{}', 200);

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
    return notificationsResponse;
  }

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    postUris.add(url);
    if (url.path.endsWith('/read-all')) {
      return markAllResponse;
    }
    return markReadResponse;
  }
}

void main() {
  group('NotificationService', () {
    test(
      'getNotifications sends include_read and parses unread_count',
      () async {
        final service = _FakeNotificationService();
        service.notificationsResponse = http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'n1',
                'event_type': 'new_message',
                'title': 'New message',
                'body': 'You have a new message',
                'is_read': false,
                'created_at': '2026-03-01T09:00:00Z',
              },
            ],
            'total': 1,
            'unread_count': 1,
            'limit': 30,
            'offset': 10,
          }),
          200,
        );

        final response = await service.getNotifications(
          limit: 30,
          offset: 10,
          includeRead: true,
        );

        expect(service.lastGetUri, isNotNull);
        expect(service.lastGetUri!.path, '/api/notifications');
        expect(service.lastGetUri!.queryParameters['limit'], '30');
        expect(service.lastGetUri!.queryParameters['offset'], '10');
        expect(service.lastGetUri!.queryParameters['include_read'], 'true');

        expect(response.unreadCount, 1);
        expect(response.items.length, 1);
        expect(response.items.first.id, 'n1');
      },
    );

    test(
      'markRead and markAll hit expected endpoints and default count',
      () async {
        final service = _FakeNotificationService();
        service.markReadResponse = http.Response(jsonEncode({'ok': true}), 200);
        service.markAllResponse = http.Response(jsonEncode({}), 200);

        await service.markNotificationRead('n123');
        final markedCount = await service.markAllRead();

        expect(service.postUris.length, 2);
        expect(service.postUris[0].path, '/api/notifications/n123/read');
        expect(service.postUris[1].path, '/api/notifications/read-all');
        expect(markedCount, 0);
      },
    );

    test('markNotificationRead encodes reserved characters in ID', () async {
      final service = _FakeNotificationService();
      const notificationId = 'id with space/and/slash';

      await service.markNotificationRead(notificationId);

      expect(service.postUris.length, 1);
      final uri = service.postUris.first;
      expect(uri.pathSegments.length, 4);
      expect(uri.pathSegments[2], notificationId);
      expect(uri.pathSegments[3], 'read');
    });
  });
}
