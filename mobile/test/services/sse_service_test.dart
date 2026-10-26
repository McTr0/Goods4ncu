import 'dart:async';
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

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(request);
  }

  @override
  void close() => isClosed = true;
}

String _completedTurn() => [
  'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"c","seq":1,"type":"turn_started"}\n\n',
  'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"c","seq":2,"type":"text_delta","text":"complete reply"}\n\n',
  'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"c","seq":3,"type":"turn_completed","usage":{"model_steps":1,"tool_calls":0}}\n\n',
].join();

http.StreamedResponse _response(int statusCode, {String body = ''}) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    statusCode,
    headers: const {'content-type': 'text/event-stream'},
  );
}

void main() {
  group('SseService', () {
    test('disconnect while loading a token prevents a late request', () async {
      final tokenRequested = Completer<void>();
      final token = Completer<String?>();
      final client = _RecordingClient((_) async => _response(200));
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () {
          tokenRequested.complete();
          return token.future;
        },
        clientFactory: () => client,
      );

      final connecting = service.connect(message: 'stopped');
      await tokenRequested.future;
      await service.disconnect();
      token.complete('test-token');
      await connecting;

      expect(client.requests, isEmpty);
      expect(service.isConnected, isFalse);
      await service.disconnect();
    });

    test('disconnect during refresh prevents an obsolete auth retry', () async {
      final refreshing = Completer<void>();
      final refreshed = Completer<bool>();
      final client = _RecordingClient((_) async => _response(401));
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        refreshAccessToken: () {
          refreshing.complete();
          return refreshed.future;
        },
        clientFactory: () => client,
      );

      final connecting = service.connect(message: 'stopped');
      await refreshing.future;
      await service.disconnect();
      refreshed.complete(true);
      await connecting;

      expect(client.requests, hasLength(1));
      expect(client.isClosed, isTrue);
      expect(service.isConnected, isFalse);
    });

    test(
      'old teardown cannot block or close a replacement connection',
      () async {
        final cancelling = Completer<void>();
        final releaseCancellation = Completer<void>();
        final oldBody = StreamController<List<int>>(
          onCancel: () {
            cancelling.complete();
            return releaseCancellation.future;
          },
        );
        final newBody = StreamController<List<int>>();
        final oldClient = _RecordingClient(
          (_) async => http.StreamedResponse(oldBody.stream, 200),
        );
        final newClient = _RecordingClient(
          (_) async => http.StreamedResponse(newBody.stream, 200),
        );
        final clients = [oldClient, newClient];
        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => 'test-token',
          clientFactory: () => clients.removeAt(0),
        );

        await service.connect(message: 'old');
        final teardown = service.disconnect();
        await cancelling.future;
        final replacement = service.connect(message: 'new');
        try {
          await replacement.timeout(const Duration(seconds: 1));
          expect(newClient.requests, hasLength(1));
          expect(newClient.isClosed, isFalse);
          expect(service.isConnected, isTrue);
        } finally {
          releaseCancellation.complete();
          await teardown;
          await replacement;
        }
        expect(newClient.isClosed, isFalse);
        expect(service.isConnected, isTrue);

        final received = service.stream.toList();
        newBody.add(utf8.encode(_completedTurn()));
        await newBody.close();
        expect(await received, hasLength(3));
        await service.disconnect();
        await oldBody.close();
      },
    );

    test('replacement does not wait for a paused old consumer', () async {
      final oldBody = StreamController<List<int>>();
      final newBody = StreamController<List<int>>();
      final oldClient = _RecordingClient(
        (_) async => http.StreamedResponse(oldBody.stream, 200),
      );
      final newClient = _RecordingClient(
        (_) async => http.StreamedResponse(newBody.stream, 200),
      );
      final clients = [oldClient, newClient];
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        clientFactory: () => clients.removeAt(0),
      );

      await service.connect(message: 'old');
      final consumer = service.stream.listen((_) {});
      consumer.pause();
      final replacement = service.connect(message: 'replacement');
      try {
        await replacement.timeout(const Duration(seconds: 1));
        expect(newClient.requests, hasLength(1));
        expect(oldClient.isClosed, isTrue);
      } finally {
        await consumer.cancel();
        await replacement;
        await service.disconnect();
        await oldBody.close();
        await newBody.close();
      }
    });

    test('completed events remain available to a late listener', () async {
      final client = _QueuedClient([_response(200, body: _completedTurn())]);
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        clientFactory: () => client,
      );

      await service.connect(message: 'hello');
      await Future<void>.delayed(Duration.zero);
      expect(service.isConnected, isFalse);
      final events = await service.stream.toList();
      expect(events, hasLength(3));
      expect(events[1].text, 'complete reply');
      expect(events.last.type, 'turn_completed');
      await service.disconnect();
    });

    test('protocol errors remain available to a late listener', () async {
      final client = _QueuedClient([
        _response(
          200,
          body:
              'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"c","seq":99,"type":"text_delta","text":"gap"}\n\n',
        ),
      ]);
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        clientFactory: () => client,
      );

      await service.connect(message: 'hello');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        service.stream.toList(),
        throwsA(isA<ProtocolViolationException>()),
      );
      await service.disconnect();
    });

    test('a failed connection releases its own HTTP client', () async {
      final client = _RecordingClient((_) async => throw StateError('offline'));
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        clientFactory: () => client,
      );

      await expectLater(service.connect(message: 'hello'), throwsStateError);
      expect(client.isClosed, isTrue);
      expect(service.isConnected, isFalse);
      await service.disconnect();
    });

    test('late credentials cannot overwrite the replacement stream', () async {
      final loadingToken = Completer<void>();
      final oldToken = Completer<String?>();
      final body = StreamController<List<int>>();
      final clients = <_RecordingClient>[];
      var tokenCalls = 0;
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () {
          if (tokenCalls++ == 0) {
            loadingToken.complete();
            return oldToken.future;
          }
          return Future.value('test-token');
        },
        clientFactory: () {
          final client = _RecordingClient(
            (_) async => http.StreamedResponse(body.stream, 200),
          );
          clients.add(client);
          return client;
        },
      );

      final oldConnect = service.connect(message: 'obsolete');
      await loadingToken.future;
      await service.connect(message: 'replacement');
      final received = service.stream.toList();
      oldToken.complete('test-token');
      await oldConnect;
      expect(
        clients
            .expand((client) => client.requests)
            .map(
              (request) =>
                  jsonDecode((request as http.Request).body)['message'],
            ),
        ['replacement'],
      );
      expect(service.isConnected, isTrue);
      body.add(utf8.encode(_completedTurn()));
      await body.close();
      expect(await received, hasLength(3));
      expect(clients.every((client) => client.isClosed), isTrue);
      await service.disconnect();
    });

    test('a retired HTTP send error cannot fail its replacement', () async {
      final requested = Completer<void>();
      final oldResponse = Completer<http.StreamedResponse>();
      final body = StreamController<List<int>>();
      final oldClient = _RecordingClient((_) {
        requested.complete();
        return oldResponse.future;
      });
      final newClient = _RecordingClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      );
      final clients = [oldClient, newClient];
      final service = SseService(
        baseUrl: 'https://api.test',
        getAccessToken: () async => 'test-token',
        clientFactory: () => clients.removeAt(0),
      );

      final oldConnect = service.connect(message: 'obsolete');
      await requested.future;
      await service.connect(message: 'replacement');
      oldResponse.completeError(StateError('client closed'));
      await oldConnect;
      expect(service.isConnected, isTrue);
      expect(oldClient.isClosed, isTrue);
      expect(newClient.isClosed, isFalse);

      final received = service.stream.toList();
      body.add(utf8.encode(_completedTurn()));
      await body.close();
      expect(await received, hasLength(3));
      await service.disconnect();
    });

    test('parses server error events', () {
      final event = AgentStreamEvent.fromJson({
        'protocol_version': '2.0',
        'turn_id': 'turn-err-1',
        'conversation_id': 'conv-err-1',
        'type': 'turn_failed',
        'seq': 1,
        'error': {'code': 'provider_error', 'message': 'provider unavailable'},
      });

      expect(event.errorMessage, 'provider unavailable');
      expect(event.errorCode, 'provider_error');
    });

    test('retries once with refreshed token when first response is 401', () async {
      final client = _QueuedClient([
        _response(401),
        _response(
          200,
          body: [
            'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"conv-1","seq":1,"type":"turn_started"}\n\n',
            'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"conv-1","seq":2,"type":"text_delta","text":"ok"}\n\n',
            'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"conv-1","seq":3,"type":"turn_completed","usage":{"model_steps":1,"tool_calls":0}}\n\n',
          ].join(),
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
      expect(client.requests[1].headers['Authorization'], 'Bearer fresh-token');

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
    });

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
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":1,"type":"turn_started"}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":2,"type":"text_delta","text":"你好"}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":3,"type":"tool_started","call":{"name":"search_inventory","status":"started"}}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":4,"type":"ui_action","action":{"action_type":"SHOW_POSTS","payload":{"postIds":["p1"]}}}\n\n',
        'data: {"protocol_version":"2.0","turn_id":"t","conversation_id":"__agent__","seq":5,"type":"turn_completed","usage":{"model_steps":1,"tool_calls":1}}\n\n',
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

      expect(events, hasLength(5));
      expect(events[0].type, 'turn_started');
      expect(events[1].text, '你好');
      expect(events[2].toolName, 'search_inventory');
      expect(events[3].actionType, 'SHOW_POSTS');
      expect(events[4].type, 'turn_completed');
      expect(events[4].usage?.modelSteps, 1);
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

    test(
      'emits StreamTruncatedException when stream ends without terminal event',
      () async {
        final body = [
          'data: {"protocol_version":"2.0","turn_id":"t1","conversation_id":"__agent__","seq":1,"type":"turn_started"}\n\n',
          'data: {"protocol_version":"2.0","turn_id":"t1","conversation_id":"__agent__","seq":2,"type":"text_delta","text":"partial"}\n\n',
        ].join();
        final client = _QueuedClient([_response(200, body: body)]);
        final service = SseService(
          baseUrl: 'https://api.test',
          getAccessToken: () async => 'token-123',
          refreshAccessToken: () async => false,
          clientFactory: () => client,
        );

        await service.connect(message: 'hi');
        expect(
          service.stream.toList(),
          throwsA(isA<StreamTruncatedException>()),
        );
      },
    );

    test('validates monotonic sequence and rejects gaps', () async {
      final validator = AgentTurnValidator();
      final ev1 = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'c1',
      );
      final ev3 = AgentStreamEvent(
        type: 'text_delta',
        seq: 3,
        turnId: 't1',
        conversationId: 'c1',
        text: 'hi',
      );

      expect(validator.validateEvent(ev1), isFalse);
      expect(
        () => validator.validateEvent(ev3),
        throwsA(isA<ProtocolViolationException>()),
      );
    });

    test('rejects first event when not turn_started or seq != 1', () {
      final validator = AgentTurnValidator();
      final evText = AgentStreamEvent(
        type: 'text_delta',
        seq: 1,
        turnId: 't1',
        conversationId: 'c1',
        text: 'hi',
      );
      expect(
        () => validator.validateEvent(evText),
        throwsA(isA<ProtocolViolationException>()),
      );

      validator.reset();
      final evTurnStartedSeq2 = AgentStreamEvent(
        type: 'turn_started',
        seq: 2,
        turnId: 't1',
        conversationId: 'c1',
      );
      expect(
        () => validator.validateEvent(evTurnStartedSeq2),
        throwsA(isA<ProtocolViolationException>()),
      );
    });

    test('rejects conversation ID mismatch', () {
      final validator = AgentTurnValidator(
        expectedConversationId: 'expected-conv',
      );
      final evWrongConv = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'other-conv',
      );
      expect(
        () => validator.validateEvent(evWrongConv),
        throwsA(isA<ProtocolViolationException>()),
      );

      final dynamicValidator = AgentTurnValidator();
      final ev1 = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'conv-a',
      );
      dynamicValidator.validateEvent(ev1);
      final ev2 = AgentStreamEvent(
        type: 'text_delta',
        seq: 2,
        turnId: 't1',
        conversationId: 'conv-b',
        text: 'hi',
      );
      expect(
        () => dynamicValidator.validateEvent(ev2),
        throwsA(isA<ProtocolViolationException>()),
      );
    });

    test(
      'AgentStreamEvent.fromJson rejects invalid seq, unknown types, or missing fields',
      () {
        // Float seq
        expect(
          () => AgentStreamEvent.fromJson({
            'protocol_version': '2.0',
            'turn_id': 't1',
            'conversation_id': 'c1',
            'type': 'turn_started',
            'seq': 1.5,
          }),
          throwsA(isA<FormatException>()),
        );

        // Negative seq
        expect(
          () => AgentStreamEvent.fromJson({
            'protocol_version': '2.0',
            'turn_id': 't1',
            'conversation_id': 'c1',
            'type': 'turn_started',
            'seq': -1,
          }),
          throwsA(isA<FormatException>()),
        );

        // Unknown event type
        expect(
          () => AgentStreamEvent.fromJson({
            'protocol_version': '2.0',
            'turn_id': 't1',
            'conversation_id': 'c1',
            'type': 'custom_unknown_type',
            'seq': 1,
          }),
          throwsA(isA<FormatException>()),
        );

        // Missing conversation_id
        expect(
          () => AgentStreamEvent.fromJson({
            'protocol_version': '2.0',
            'turn_id': 't1',
            'type': 'turn_started',
            'seq': 1,
          }),
          throwsA(isA<FormatException>()),
        );

        // text_delta missing text
        expect(
          () => AgentStreamEvent.fromJson({
            'protocol_version': '2.0',
            'turn_id': 't1',
            'conversation_id': 'c1',
            'type': 'text_delta',
            'seq': 2,
          }),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('heartbeat advances sequence count and is flagged for filtering', () {
      final validator = AgentTurnValidator();
      final ev1 = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'c1',
      );
      final evHb = AgentStreamEvent(
        type: 'heartbeat',
        seq: 2,
        turnId: 't1',
        conversationId: 'c1',
      );
      final ev3 = AgentStreamEvent(
        type: 'text_delta',
        seq: 3,
        turnId: 't1',
        conversationId: 'c1',
        text: 'hi',
      );

      expect(validator.validateEvent(ev1), isFalse);
      expect(validator.validateEvent(evHb), isTrue);
      expect(validator.validateEvent(ev3), isFalse);
    });

    test('rejects events after terminal event', () {
      final validator = AgentTurnValidator();
      final ev1 = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'c1',
      );
      final evTerm = AgentStreamEvent(
        type: 'turn_completed',
        seq: 2,
        turnId: 't1',
        conversationId: 'c1',
      );
      final evPost = AgentStreamEvent(
        type: 'text_delta',
        seq: 3,
        turnId: 't1',
        conversationId: 'c1',
        text: 'extra',
      );

      expect(validator.validateEvent(ev1), isFalse);
      expect(validator.validateEvent(evTerm), isFalse);
      expect(validator.hasSeenTerminalEvent, isTrue);
      expect(
        () => validator.validateEvent(evPost),
        throwsA(isA<ProtocolViolationException>()),
      );
    });

    test('assertTerminalEventSeen throws if stream ends prematurely', () {
      final validator = AgentTurnValidator();
      final ev1 = AgentStreamEvent(
        type: 'turn_started',
        seq: 1,
        turnId: 't1',
        conversationId: 'c1',
      );
      validator.validateEvent(ev1);

      expect(
        () => validator.assertTerminalEventSeen(),
        throwsA(isA<StreamTruncatedException>()),
      );
    });

    test(
      'validateEvent does not mutate internal state when validation fails on first event',
      () {
        final validator = AgentTurnValidator(
          expectedConversationId: 'expected-conv',
        );
        final evWrongConv = AgentStreamEvent(
          type: 'turn_started',
          seq: 1,
          turnId: 'wrong-turn',
          conversationId: 'wrong-conv',
        );

        expect(
          () => validator.validateEvent(evWrongConv),
          throwsA(isA<ProtocolViolationException>()),
        );

        // Now pass the genuine expected event with seq=1
        final validEv = AgentStreamEvent(
          type: 'turn_started',
          seq: 1,
          turnId: 'actual-turn',
          conversationId: 'expected-conv',
        );
        expect(validator.validateEvent(validEv), isFalse);
      },
    );

    test(
      'protocol violation in chunk terminates stream immediately with single error and no EOF duplicate',
      () async {
        final client = _QueuedClient([
          _response(
            200,
            body:
                'data: {"protocol_version":"2.0","type":"turn_started","seq":1,"turn_id":"t1","conversation_id":"c1"}\n\n'
                'data: {"protocol_version":"2.0","type":"text_delta","seq":99,"turn_id":"t1","conversation_id":"c1","text":"gap"}\n\n'
                'data: {"protocol_version":"2.0","type":"text_delta","seq":100,"turn_id":"t1","conversation_id":"c1","text":"after"}\n\n',
          ),
        ]);

        final service = SseService(
          baseUrl: 'http://example.test',
          getAccessToken: () async => 'test-token',
          clientFactory: () => client,
        );

        await service.connect(message: 'hi');

        final events = <AgentStreamEvent>[];
        final errors = <dynamic>[];

        final completer = Completer<void>();
        service.stream.listen(
          events.add,
          onError: (err) {
            errors.add(err);
          },
          onDone: () {
            completer.complete();
          },
        );

        await completer.future;

        expect(events.length, 1);
        expect(events.first.type, 'turn_started');
        expect(errors.length, 1);
        expect(errors.first, isA<ProtocolViolationException>());
      },
    );
  });
}
