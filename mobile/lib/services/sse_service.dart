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
  final String _baseUrl;
  final AccessTokenProvider _getAccessToken;
  final RefreshAccessToken _refreshAccessToken;
  final HttpClientFactory _clientFactory;

  _SseConnection? _connection;

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
      _connection?.controller.stream ?? const Stream.empty();

  bool get isConnected => _connection?.isConnected ?? false;

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
    final previous = _connection;
    final connection = _SseConnection(
      _clientFactory(),
      expectedConversationId: conversationId,
    );
    // Claim ownership before awaiting anything, including credentials and old
    // teardown. A disconnect can retire this attempt before it sends a request.
    _connection = connection;

    bool isCurrent() => identical(_connection, connection);

    try {
      await previous?.close();
      if (!isCurrent()) return;

      var token = await _getAccessToken();
      if (!isCurrent()) return;
      if (token == null || token.isEmpty) {
        final refreshed = await _attemptRefresh();
        if (!isCurrent()) return;
        if (refreshed) {
          token = await _getAccessToken();
          if (!isCurrent()) return;
        }
      }
      if (token == null || token.isEmpty) {
        throw Exception('SSE: No JWT token — not authenticated');
      }

      final uri = Uri.parse('$_baseUrl/api/chat/stream');
      final body = <String, dynamic>{'message': message};
      if (conversationId != null) body['conversation_id'] = conversationId;
      if (listingId != null) body['listing_id'] = listingId;
      if (pageContext != null) body['page_context'] = pageContext;
      if (imageUrl != null) body['image_url'] = imageUrl;
      if (audioUrl != null) body['audio_url'] = audioUrl;

      var response = await _sendSseRequest(
        connection.client,
        uri,
        token,
        body,
        idempotencyKey: idempotencyKey,
      );
      if (!isCurrent()) return;

      if (response.statusCode == 401) {
        final refreshed = await _attemptRefresh();
        if (!isCurrent()) return;
        if (refreshed) {
          final refreshedToken = await _getAccessToken();
          if (!isCurrent()) return;
          if (refreshedToken != null && refreshedToken.isNotEmpty) {
            response = await _sendSseRequest(
              connection.client,
              uri,
              refreshedToken,
              body,
              idempotencyKey: idempotencyKey,
            );
            if (!isCurrent()) return;
          }
        }
      }

      if (response.statusCode == 401) {
        throw Exception('SSE authentication failed: session expired');
      }
      if (response.statusCode != 200) {
        throw Exception('SSE connection failed: ${response.statusCode}');
      }
      connection.listen(response.stream);
    } catch (_) {
      final wasCurrent = isCurrent();
      if (wasCurrent) _connection = null;
      await connection.close();
      // Closing a retired HTTP client can complete its pending send with an
      // error. That belongs to the cancelled attempt, not its replacement.
      if (wasCurrent) rethrow;
    }
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
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }

  void dispose() {
    disconnect();
  }
}

/// Resources and protocol state belong to one attempt, even after replacement.
class _SseConnection {
  _SseConnection(this.client, {String? expectedConversationId})
    : _validator = AgentTurnValidator(
        expectedConversationId: expectedConversationId,
      );

  static const int _maxPendingChars = 65536;

  final http.Client client;
  // Retain queued events/errors after EOF until the consumer attaches, or the
  // service explicitly disconnects/replaces this connection.
  final controller = StreamController<AgentStreamEvent>();
  final AgentTurnValidator _validator;
  StreamSubscription<String>? _subscription;
  bool isConnected = false;
  bool _closed = false;

  void listen(Stream<List<int>> bytes) {
    isConnected = true;
    var pendingText = '';
    _subscription = bytes
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            if (_closed) return;
            pendingText = _appendDecodedText(chunk, pendingText);
          },
          onError: _fail,
          onDone: () {
            if (_closed) return;
            _subscription = null;
            try {
              _validator.assertTerminalEventSeen();
            } catch (error, stackTrace) {
              _fail(error, stackTrace);
              return;
            }
            unawaited(close());
          },
          cancelOnError: true,
        );
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_closed) return;
    controller.addError(error, stackTrace);
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    isConnected = false;
    final subscription = _subscription;
    _subscription = null;
    client.close();
    // Consumer completion is not transport teardown. A paused or not-yet
    // attached listener must not hold the next connection's startup hostage.
    unawaited(controller.close());
    await subscription?.cancel();
  }

  String _appendDecodedText(String chunk, String pendingText) {
    final normalized = chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var pending = pendingText + normalized;
    while (!_closed) {
      final separator = pending.indexOf('\n\n');
      if (separator < 0) break;
      final block = pending.substring(0, separator);
      pending = pending.substring(separator + 2);
      _processSseEventBlock(block);
    }
    // Preserve the existing bound for malformed chunks without separators.
    if (pending.length > _maxPendingChars) {
      pending = pending.substring(pending.length - _maxPendingChars);
    }
    return pending;
  }

  void _processSseEventBlock(String block) {
    final dataLines = <String>[];
    for (final line in block.split('\n')) {
      final trimmed = line.trimRight();
      if (trimmed.startsWith('data:')) {
        dataLines.add(trimmed.substring(5).trimLeft());
      }
    }
    final payload = dataLines.join('\n').trim();
    if (payload.isEmpty) return;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final event = AgentStreamEvent.fromJson(json);
      if (!_validator.validateEvent(event)) controller.add(event);
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }
}
