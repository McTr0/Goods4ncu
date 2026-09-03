import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/agent_stream_event.dart';
import 'package:goods4ncu_mobile/services/sse_service.dart';
import 'package:http/http.dart' as http;

class _QueuedClient extends http.BaseClient {
  final List<http.StreamedResponse> _responses;
  final List<http.BaseRequest> requests = [];

  _QueuedClient(this._responses);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) {
      throw StateError('No queued response');
    }
    return _responses.removeAt(0);
  }
}

http.StreamedResponse _response(int statusCode, {String body = ''}) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    statusCode,
    headers: const {'content-type': 'text/event-stream'},
  );
}

void main() {
  group('SseService', () {
    test('parses server error events', () {
      final event = AgentStreamEvent.fromJson({
        'type': 'turn_failed',
        'seq': 1,
        'error': {'code': 'provider_error', 'message': 'provider unavailable'},
      });

      expect(event.errorMessage, 'provider unavailable');
      expect(event.errorCode, 'provider_error');
    });

    test(
      'retries once with refreshed token when first response is 401',
      () async {
        final client = _QueuedClient([
          _response(401),
          _response(
            200,
            body:
                'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"conv-1","seq":1,"type":"text_delta","text":"ok"}\n\n',
          ),
        ]);

        var accessToken = 'expired-token';
        var refreshCalls = 0;

        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => accessToken,
          refreshAccessToken: () async {
            refreshCalls += 1;
            accessToken = 'fresh-token';
            return true;
          },
          clientFactory: () => client,
        );

        await service.connect(message: 'hello', conversationId: 'conv-1');

        expect(refreshCalls, 1);
        expect(client.requests.length, 2);
        expect(
          client.requests[0].headers['Authorization'],
          'Bearer expired-token',
        );
        expect(
          client.requests[1].headers['Authorization'],
          'Bearer fresh-token',
        );

        final firstRequest = client.requests[0] as http.Request;
        final secondRequest = client.requests[1] as http.Request;
        expect(firstRequest.method, 'POST');
        expect(firstRequest.url.path, '/api/chat/stream');
        expect(jsonDecode(firstRequest.body), {
          'message': 'hello',
          'conversation_id': 'conv-1',
        });
        expect(jsonDecode(secondRequest.body), {
          'message': 'hello',
          'conversation_id': 'conv-1',
        });

        await service.disconnect();
      },
    );

    test('throws auth error when 401 cannot be recovered by refresh', () async {
      final client = _QueuedClient([_response(401)]);

      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'expired-token',
        refreshAccessToken: () async => false,
        clientFactory: () => client,
      );

      await expectLater(
        service.connect(message: 'hello'),
        throwsA(
          predicate((error) {
            return error.toString().contains('session expired');
          }),
        ),
      );
      expect(service.isConnected, isFalse);
    });

    test(
      'fails fast when access token is empty after refresh attempt',
      () async {
        final client = _QueuedClient([_response(200)]);

        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => '',
          refreshAccessToken: () async => false,
          clientFactory: () => client,
        );

        await expectLater(
          service.connect(message: 'hello'),
          throwsA(
            predicate((error) {
              return error.toString().contains('No JWT token');
            }),
          ),
        );
        expect(client.requests, isEmpty);
        expect(service.isConnected, isFalse);
      },
    );

    test('treats refresh exceptions as auth-expired on 401', () async {
      final client = _QueuedClient([_response(401)]);

      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'expired-token',
        refreshAccessToken: () async {
          throw Exception('refresh exploded');
        },
        clientFactory: () => client,
      );

      await expectLater(
        service.connect(message: 'hello'),
        throwsA(
          predicate((error) {
            return error.toString().contains('session expired');
          }),
        ),
      );
      expect(client.requests.length, 1);
      expect(service.isConnected, isFalse);
    });

    test(
      'fails fast when initial refresh throws and token is missing',
      () async {
        final client = _QueuedClient([_response(200)]);

        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => null,
          refreshAccessToken: () async {
            throw Exception('refresh exploded');
          },
          clientFactory: () => client,
        );

        await expectLater(
          service.connect(message: 'hello'),
          throwsA(
            predicate((error) {
              return error.toString().contains('No JWT token');
            }),
          ),
        );
        expect(client.requests, isEmpty);
        expect(service.isConnected, isFalse);
      },
    );

    test('sends media URLs in JSON body instead of query params', () async {
      final client = _QueuedClient([_response(200)]);

      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'token-123',
        refreshAccessToken: () async => false,
        clientFactory: () => client,
      );

      await service.connect(
        message: 'hello',
        conversationId: 'conv-1',
        listingId: 'listing-1',
        imageUrl: 'https://cdn.example.com/a.jpg',
        audioUrl: 'https://cdn.example.com/a.ogg',
      );

      final request = client.requests.single as http.Request;
      expect(request.url.queryParameters, isEmpty);
      expect(jsonDecode(request.body), {
        'message': 'hello',
        'conversation_id': 'conv-1',
        'listing_id': 'listing-1',
        'image_url': 'https://cdn.example.com/a.jpg',
        'audio_url': 'https://cdn.example.com/a.ogg',
      });

      await service.disconnect();
    });

    test('preserves the proposal idempotency key across auth retry', () async {
      final client = _QueuedClient([_response(401), _response(200)]);
      var accessToken = 'expired-token';

      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => accessToken,
        refreshAccessToken: () async {
          accessToken = 'fresh-token';
          return true;
        },
        clientFactory: () => client,
      );

      await service.connect(message: 'draft', idempotencyKey: 'agent-retry-1');

      expect(client.requests.length, 2);
      expect(
        (client.requests[0] as http.Request).headers['Idempotency-Key'],
        'agent-retry-1',
      );
      expect(
        (client.requests[1] as http.Request).headers['Idempotency-Key'],
        'agent-retry-1',
      );
      await service.disconnect();
    });

    test('decodes complete Runtime v2 event envelopes', () async {
      final body = [
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":1,"type":"text_delta","text":"你好"}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":2,"type":"tool_started","call":{"name":"search_inventory","status":"started"}}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":3,"type":"ui_action","action":{"action_type":"SHOW_POSTS","payload":{"postIds":["p1"]}}}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":4,"type":"turn_completed","usage":{"model_steps":1,"tool_calls":1}}\n\n',
      ].join();
      final client = _QueuedClient([_response(200, body: body)]);
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'token-123',
        refreshAccessToken: () async => false,
        clientFactory: () => client,
      );

      await service.connect(message: '找书', conversationId: '__agent__');
      final events = await service.stream.toList();

      expect(events, hasLength(4));
      expect(events[0].text, '你好');
      expect(events[1].toolName, 'search_inventory');
      expect(events[2].actionType, 'SHOW_POSTS');
      expect(events[3].type, 'turn_completed');
      expect(events[3].usage?.modelSteps, 1);
    });

    test(
      'cancel endpoint uses public conversation id and bearer auth',
      () async {
        final client = _QueuedClient([_response(200, body: '{}')]);
        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => 'token-123',
          refreshAccessToken: () async => false,
          clientFactory: () => client,
        );

        await service.cancelTurn('__agent__');

        final request = client.requests.single as http.Request;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/agent/turns/__agent__/cancel');
        expect(request.headers['Authorization'], 'Bearer token-123');
      },
    );
  });
}
