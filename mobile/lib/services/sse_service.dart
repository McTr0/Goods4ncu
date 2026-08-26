import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/platform_utils.dart';
import 'base_service.dart';
import 'token_storage.dart';

typedef AccessTokenProvider = Future<String?> Function();
typedef RefreshAccessToken = Future<bool> Function();
typedef HttpClientFactory = http.Client Function();

/// Decode a v2 protocol event into an [SseToken] for the legacy pipeline.
SseToken? _decodeV2Event(Map<String, dynamic> json) {
  final type = json['type'] as String? ?? '';
  final convId = json['conversation_id'] as String? ?? '';

  switch (type) {
    case 'text_delta':
      final text = json['text'] as String?;
      if (text == null || text.isEmpty) return null;
      return SseToken(token: text, conversationId: convId);
    case 'turn_completed':
      return SseToken(token: '', conversationId: convId, isComplete: true);
    case 'turn_failed':
      final err = json['error'] as Map<String, dynamic>?;
      return SseToken(
        token: '',
        conversationId: convId,
        isComplete: true,
        error: err?['message'] ?? 'turn failed',
      );
    case 'turn_cancelled':
      return SseToken(
        token: '',
        conversationId: convId,
        isComplete: true,
        error: 'cancelled',
      );
    case 'tool_started':
    case 'tool_finished':
      final call = json['call'] as Map<String, dynamic>?;
      if (call == null) return null;
      return SseToken(
        token: '',
        conversationId: convId,
        toolActivity: {'tool': call['name'], 'status': call['status']},
      );
    case 'ui_action':
      final action = json['action'] as Map<String, dynamic>?;
      if (action == null) return null;
      return SseToken(
        token: '',
        conversationId: convId,
        uiAction: action,
      );
    default:
      return null; // heartbeat and unknown types are silently skipped
  }
}

/// SSE token event parsed from `data: {...}\n\n` format.
class SseToken {
  final String token;
  final String conversationId;

  /// Tool name while the backend is performing real platform work.
  final String? toolActivity;

  /// Optional UI action from the agent (e.g. SHOW_POSTS, SCROLL_TO_POST).
  final Map<String, dynamic>? uiAction;

  /// True when this is a complete message (e.g. greeting) rather than a streaming token.
  /// Complete messages should be finalized immediately without waiting for [DONE].
  final bool isComplete;
  final String? error;

  SseToken({
    required this.token,
    required this.conversationId,
    this.isComplete = false,
    this.error,
    this.uiAction,
    this.toolActivity,
  });

  factory SseToken.fromJson(Map<String, dynamic> json) {
    return SseToken(
      token: json['token'] ?? '',
      conversationId: json['conversation_id'] ?? '',
      isComplete: json['is_complete'] as bool? ?? false,
      error: json['error']?.toString(),
      uiAction: json['ui_action'] as Map<String, dynamic>?,
      toolActivity: (json['tool_activity'] as Map<String, dynamic>?)?['tool']
          ?.toString(),
    );
  }
}

/// Server-Sent Events stream consumer.
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
  StreamController<SseToken>? _controller;
  StreamSubscription<String>? _streamSubscription;
  bool _isConnected = false;
  int _activeConnectionId = 0;

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

  /// Stream of parsed SSE token events.
  Stream<SseToken> get stream => _controller?.stream ?? const Stream.empty();

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
    _controller = StreamController<SseToken>();

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
          onError: (error) {
            if (connectionId != _activeConnectionId) {
              return;
            }
            _isConnected = false;
            _streamSubscription = null;
            _emitError(connectionId, error);
            unawaited(_closeController(connectionId: connectionId));
          },
          onDone: () {
            if (connectionId != _activeConnectionId) {
              return;
            }
            _isConnected = false;
            _streamSubscription = null;
            unawaited(_closeController(connectionId: connectionId));
          },
          cancelOnError: false,
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

  void _emitToken(int connectionId, SseToken token) {
    if (connectionId != _activeConnectionId) {
      return;
    }
    final controller = _controller;
    if (controller == null || controller.isClosed) {
      return;
    }
    try {
      controller.add(token);
    } catch (_) {
      // Ignore stale emissions racing with disconnect.
    }
  }

  void _emitError(int connectionId, Object error) {
    if (connectionId != _activeConnectionId) {
      return;
    }
    final controller = _controller;
    if (controller == null || controller.isClosed) {
      return;
    }
    try {
      controller.addError(error);
    } catch (_) {
      // Ignore stale emissions racing with disconnect.
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

    final decoded = _decodeSseData(payload);
    if (decoded != null) {
      _emitToken(connectionId, decoded);
    }
  }

  /// Decode a single SSE data field using proper JSON parsing.
  /// Handles:
  /// - Streaming tokens: `{"token": "...", "conversation_id": "..."}`
  /// - Complete messages (greeting): `{"content": "...", "is_complete": true}`
  /// - Error events: `{"error": "..."}`
  SseToken? _decodeSseData(String jsonStr) {
    if (jsonStr.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Agent Runtime v2 protocol events.
      if (decoded['protocol_version'] == '2.0') {
        return _decodeV2Event(decoded);
      }

      // Handle error events from backend.
      final error = decoded['error']?.toString();
      if (error != null) {
        return SseToken(
          token: '',
          conversationId: decoded['conversation_id'] as String? ?? '',
          isComplete: true,
          error: error,
        );
      }

      // Complete message — greeting or direct response sent as a single event.
      // Backend sends `content` field (not `token`) for these.
      final content = decoded['content'] as String?;
      if (content != null && content.isNotEmpty) {
        return SseToken(
          token: content,
          conversationId: decoded['conversation_id'] as String? ?? '',
          isComplete: true, // Finalize immediately — no [DONE] will follow.
        );
      }

      if (decoded['ui_action'] is Map<String, dynamic> ||
          decoded['tool_activity'] is Map<String, dynamic>) {
        return SseToken.fromJson(decoded);
      }

      // Streaming token.
      final token = decoded['token'] as String?;
      if (token != null && token.isNotEmpty) {
        return SseToken.fromJson(decoded);
      }

      return null;
    } catch (e) {
      debugPrint('SSE JSON parse error: $e — raw: $jsonStr');
      return null;
    }
  }

  /// Disconnect and clean up. Idempotent.
  /// POST cancel to the server for an in-flight turn.
  void cancelTurn(String conversationId) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final url = Uri.parse(
      '$_baseUrl/api/agent/turns/'
      '${Uri.encodeComponent(conversationId)}/cancel',
    );
    _client
        ?.post(url, headers: headers, body: '{}')
        .then(
          (_) {},
          onError: (_) {
            // Best effort; turn will time out naturally if cancel fails.
          },
        );
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
