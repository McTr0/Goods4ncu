import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/platform_utils.dart';
import 'agent_stream_event.dart';
import 'base_service.dart';
import 'token_storage.dart';

typedef AccessTokenProvider = Future<String?> Function();
typedef RefreshAccessToken = Future<bool> Function();
typedef HttpClientFactory = http.Client Function();

/// Server-Sent Events stream consumer for Agent Runtime v2.
///
/// Connects to `POST /api/chat/stream` with JWT auth.
/// Each SSE `data:` line is parsed as JSON and emitted via StreamController.
class SseService {
  static const int _maxPendingChars = 65536;

  final String _baseUrl;
  final AccessTokenProvider _getAccessToken;
  final RefreshAccessToken _refreshAccessToken;
  final HttpClientFactory _clientFactory;

  http.Client? _client;
  StreamController<AgentStreamEvent>? _controller;
  StreamSubscription<String>? _streamSubscription;
  bool _isConnected = false;
  int _activeConnectionId = 0;
  final _validator = AgentTurnValidator();

  SseService({
    String? baseUrl,
    AccessTokenProvider? getAccessToken,
    RefreshAccessToken? refreshAccessToken,
    HttpClientFactory? clientFactory,
  }) : _baseUrl = baseUrl ?? getApiBaseUrl(),
       _getAccessToken = getAccessToken ?? _defaultGetAccessToken,
       _refreshAccessToken = refreshAccessToken ?? _defaultRefreshAccessToken,
       _clientFactory = clientFactory ?? http.Client.new;

  static Future<String?> _defaultGetAccessToken() {
    return TokenStorage.instance.getAccessToken();
  }

  static Future<bool> _defaultRefreshAccessToken() async {
    return BaseService().refreshAccessTokenIfNeeded();
  }

  Future<bool> _attemptRefresh() async {
    try {
      return await _refreshAccessToken();
    } catch (error) {
      debugPrint('SSE token refresh failed: $error');
      return false;
    }
  }

  /// Stream of parsed Agent Runtime v2 events.
  Stream<AgentStreamEvent> get stream =>
      _controller?.stream ?? const Stream.empty();

  bool get isConnected => _isConnected;

  /// Connect to SSE stream. Idempotent — safe to call multiple times.
  Future<void> connect({
    required String message,
    String? conversationId,
    String? listingId,
    Map<String, dynamic>? pageContext,
    String? imageUrl,
    String? audioUrl,
    String? idempotencyKey,
  }) async {
    await disconnect();
    final connectionId = _activeConnectionId;

    var token = await _getAccessToken();
    if (token == null || token.isEmpty) {
      final refreshed = await _attemptRefresh();
      if (refreshed) {
        token = await _getAccessToken();
      }
    }

    if (token == null || token.isEmpty) {
      throw Exception('SSE: No JWT token — not authenticated');
    }

    final client = _clientFactory();
    _client = client;
    // Single-subscription stream preserves events that arrive before UI listener attaches.
    _controller = StreamController<AgentStreamEvent>();
    _validator.reset(expectedConversationId: conversationId);

    final uri = Uri.parse('$_baseUrl/api/chat/stream');
    final body = <String, dynamic>{'message': message};
    if (conversationId != null) body['conversation_id'] = conversationId;
    if (listingId != null) body['listing_id'] = listingId;
    if (pageContext != null) body['page_context'] = pageContext;
    if (imageUrl != null) body['image_url'] = imageUrl;
    if (audioUrl != null) body['audio_url'] = audioUrl;

    var streamedResponse = await _sendSseRequest(
      client,
      uri,
      token,
      body,
      idempotencyKey: idempotencyKey,
    );

    if (connectionId != _activeConnectionId) {
      client.close();
      if (identical(_client, client)) {
        _client = null;
      }
      return;
    }

    if (streamedResponse.statusCode == 401) {
      final refreshed = await _attemptRefresh();
      if (refreshed) {
        final refreshedToken = await _getAccessToken();
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          streamedResponse = await _sendSseRequest(
            client,
            uri,
            refreshedToken,
            body,
            idempotencyKey: idempotencyKey,
          );
        }
      }
    }

    if (connectionId != _activeConnectionId) {
      client.close();
      if (identical(_client, client)) {
        _client = null;
      }
      return;
    }

    if (streamedResponse.statusCode != 200) {
      await _closeController(connectionId: connectionId);
      client.close();
      if (identical(_client, client)) {
        _client = null;
      }
      if (streamedResponse.statusCode == 401) {
        throw Exception('SSE authentication failed: session expired');
      }
      throw Exception('SSE connection failed: ${streamedResponse.statusCode}');
    }

    _isConnected = true;
    var pendingSseText = '';

    _streamSubscription = streamedResponse.stream
        .transform(utf8.decoder)
        .listen(
          (decodedChunk) {
            if (connectionId != _activeConnectionId) {
              return;
            }
            pendingSseText = _appendDecodedText(
              connectionId: connectionId,
              decodedChunk: decodedChunk,
              pendingText: pendingSseText,
            );
          },
          onError: (error, st) {
            _failProtocol(connectionId, error, st);
          },
          onDone: () {
            if (connectionId != _activeConnectionId) {
              return;
            }
            _isConnected = false;
            _streamSubscription = null;
            try {
              _validator.assertTerminalEventSeen();
            } catch (error, st) {
              _failProtocol(connectionId, error, st);
              return;
            }
            unawaited(_closeController(connectionId: connectionId));
          },
          cancelOnError: true,
        );
  }

  Future<http.StreamedResponse> _sendSseRequest(
    http.Client client,
    Uri uri,
    String token,
    Map<String, dynamic> body, {
    String? idempotencyKey,
  }) {
    final request = http.Request('POST', uri);
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    request.headers['Content-Type'] = 'application/json';
    request.headers['Authorization'] = 'Bearer $token';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    request.body = jsonEncode(body);
    return client.send(request);
  }

  void _emitEvent(int connectionId, AgentStreamEvent event) {
    if (connectionId != _activeConnectionId) {
      return;
    }
    final controller = _controller;
    if (controller == null || controller.isClosed) {
      return;
    }
    try {
      controller.add(event);
    } catch (_) {
      // Ignore stale emissions racing with disconnect.
    }
  }

  void _failProtocol(int connectionId, Object error, [StackTrace? stackTrace]) {
    if (connectionId != _activeConnectionId) {
      return;
    }
    _activeConnectionId += 1;
    _isConnected = false;

    final sub = _streamSubscription;
    _streamSubscription = null;
    try {
      sub?.cancel();
    } catch (_) {}

    final client = _client;
    _client = null;
    try {
      client?.close();
    } catch (_) {}

    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      try {
        controller.addError(error, stackTrace);
      } catch (_) {}
      if (!controller.hasListener) {
        unawaited(controller.close());
      } else {
        controller.close();
      }
    }
  }

  Future<void> _closeController({int? connectionId}) async {
    if (connectionId != null && connectionId != _activeConnectionId) {
      return;
    }
    final controller = _controller;
    _controller = null;
    if (controller == null || controller.isClosed) {
      return;
    }
    if (!controller.hasListener) {
      // Single-subscription controllers may never complete close() if no listener attaches.
      unawaited(controller.close());
      return;
    }
    await controller.close();
  }

  String _appendDecodedText({
    required int connectionId,
    required String decodedChunk,
    required String pendingText,
  }) {
    if (connectionId != _activeConnectionId) {
      return pendingText;
    }
    if (decodedChunk.isEmpty) {
      return pendingText;
    }

    final normalized = decodedChunk
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    var updatedPendingText = pendingText + normalized;

    while (true) {
      if (connectionId != _activeConnectionId) {
        return '';
      }
      final separatorIndex = updatedPendingText.indexOf('\n\n');
      if (separatorIndex < 0) {
        break;
      }

      final eventBlock = updatedPendingText.substring(0, separatorIndex);
      updatedPendingText = updatedPendingText.substring(separatorIndex + 2);
      _processSseEventBlock(connectionId, eventBlock);
    }

    // Keep memory bounded if server sends malformed chunks without separators.
    if (updatedPendingText.length > _maxPendingChars) {
      updatedPendingText = updatedPendingText.substring(
        updatedPendingText.length - _maxPendingChars,
      );
    }

    return updatedPendingText;
  }

  void _processSseEventBlock(int connectionId, String eventBlock) {
    if (eventBlock.trim().isEmpty) {
      return;
    }

    final lines = eventBlock.split('\n');
    final dataLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.startsWith('data:')) {
        dataLines.add(trimmed.substring(5).trimLeft());
      }
    }

    if (dataLines.isEmpty) {
      return;
    }

    final payload = dataLines.join('\n').trim();
    if (payload.isEmpty) {
      return;
    }

    try {
      final decodedJson = jsonDecode(payload) as Map<String, dynamic>;
      final event = AgentStreamEvent.fromJson(decodedJson);
      final isHeartbeat = _validator.validateEvent(event);
      if (!isHeartbeat) {
        _emitEvent(connectionId, event);
      }
    } catch (e, st) {
      debugPrint('SSE validation error: $e — raw: $payload');
      _failProtocol(connectionId, e, st);
    }
  }

  /// Disconnect and clean up. Idempotent.
  /// POST cancel to the server for an in-flight turn.
  ///
  /// Uses an independent [http.Client] so the cancel request survives
  /// the SSE stream's disconnect. Carries Bearer auth for the Session
  /// extractor on the server side.
  Future<void> cancelTurn(String conversationId) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    try {
      final token = await _getAccessToken();
      if (token == null || token.isEmpty) return;
      headers['Authorization'] = 'Bearer $token';
    } catch (_) {
      return;
    }
    final url = Uri.parse(
      '$_baseUrl/api/agent/turns/'
      '${Uri.encodeComponent(conversationId)}/cancel',
    );
    final client = _clientFactory();
    try {
      await client.post(url, headers: headers, body: '{}');
    } catch (_) {
      // Best effort; turn will time out naturally if cancel fails.
    } finally {
      client.close();
    }
  }

  Future<void> disconnect() async {
    _activeConnectionId += 1;
    _isConnected = false;
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _client?.close();
    _client = null;
    await _closeController();
  }

  void dispose() {
    disconnect();
  }
}
