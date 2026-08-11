import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/platform_utils.dart';
import 'token_storage.dart';
import 'ws_channel.dart';

/// Incoming WS message envelope. Matches backend WS push payload.
class WsNotification {
  final String? id;
  final String eventType;
  final String title;
  final String body;
  final String? relatedOrderId;
  final String? relatedListingId;
  final String? negotiationId;
  final String? relatedConversationId;

  /// 用于 connection_request 等事件
  final String? connectionId;

  /// 用于 new_message 和 message acknowledgement 事件
  final String? messageId;

  final String? conversationId;
  final String? conversationMode;
  final String? conversationState;
  final DateTime? expiresAt;

  WsNotification({
    this.id,
    required this.eventType,
    required this.title,
    required this.body,
    this.relatedOrderId,
    this.relatedListingId,
    this.negotiationId,
    this.relatedConversationId,
    this.connectionId,
    this.messageId,
    this.conversationId,
    this.conversationMode,
    this.conversationState,
    this.expiresAt,
  });

  factory WsNotification.fromJson(Map<String, dynamic> json) {
    return WsNotification(
      id: json['id']?.toString(),
      eventType: json['event'] ?? json['event_type'] ?? '',
      title: json['title'] ?? '',
      body: json['body'] ?? '',
      relatedOrderId: json['related_order_id']?.toString(),
      relatedListingId: json['related_listing_id']?.toString(),
      negotiationId: json['negotiation_id']?.toString(),
      relatedConversationId:
          json['related_conversation_id']?.toString() ??
          json['conversation_id']?.toString(),
      connectionId: json['connection_id']?.toString(),
      messageId: json['message_id']?.toString(),
      conversationId: json['conversation_id']?.toString(),
      conversationMode: json['mode']?.toString(),
      conversationState: json['state']?.toString(),
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.tryParse(json['expires_at'].toString()),
    );
  }
}

/// Global WebSocket singleton.
///
/// Usage:
///   // App startup (after login):
///   await WsService.instance.connect();
///
///   // Pages subscribe (no teardown needed — singleton persists across navigation):
///   final sub = WsService.instance.stream.listen(handler);
///   // In dispose():
///   sub.cancel();  // only cancel the subscription
///
///   // Logout (disconnect global singleton):
///   await WsService.instance.disconnect();
class WsService {
  WsService._();

  static final WsService instance = WsService._();

  static String get _wsUrl => getWsUrl();
  static const Duration _baseDelay = Duration(seconds: 1);
  static const Duration _maxDelay = Duration(seconds: 30);

  WebSocketChannel? _channel;
  StreamController<WsNotification>? _controller;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  int _reconnectAttempts = 0;
  bool _shouldReconnect = true;
  String? _pendingAuthToken;
  bool _isConnecting = false;

  /// Stream of parsed WS push notifications.
  Stream<WsNotification> get stream =>
      _controller?.stream ?? const Stream.empty();

  bool get isConnected => _channel != null;

  /// Connect to WebSocket. Idempotent — safe to call multiple times.
  /// Stores token for automatic reconnect.
  Future<void> connect() async {
    if (_isConnecting || isConnected) return;
    final token = await TokenStorage.instance.getAccessToken();
    if (token == null) return; // Not authenticated — skip
    _pendingAuthToken = token;
    _shouldReconnect = true;
    await _doConnect(token);
  }

  Future<void> _doConnect(String token) async {
    _isConnecting = true;
    try {
      _channel = connectWsChannel(wsUrl: _wsUrl, token: token);

      _controller ??= StreamController<WsNotification>.broadcast();

      _channel!.stream.listen(
        (data) => _handleMessage(data),
        onError: (error) {
          debugPrint('WS error: $error');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('WS connection closed');
          _scheduleReconnect();
        },
        cancelOnError: false,
      );

      _reconnectAttempts = 0;
    } on UnsupportedError catch (e) {
      debugPrint('WS unsupported on this platform: $e');
      _shouldReconnect = false;
      _pendingAuthToken = null;
    } catch (e) {
      debugPrint('WS connect error: $e');
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final eventType = json['event_type'] as String? ?? '';

      // Server sends ping as `{"type":"ping"}` — respond with pong via channel.
      if (eventType == 'ping' || (json['type']?.toString() == 'ping')) {
        _channel?.sink.add(jsonEncode({'type': 'pong'}));
        return;
      }

      final notification = WsNotification.fromJson(json);
      _controller?.add(notification);
    } catch (e) {
      debugPrint('WS message parse error: $e — data: $data');
    }
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    if (_pendingAuthToken == null) return;

    _heartbeatTimer?.cancel();
    _channel = null;

    // Exponential backoff: 1s, 2s, 4s, 8s, ... cap at 30s.
    final delay = Duration(
      seconds: (_baseDelay.inSeconds * (1 << _reconnectAttempts)).clamp(
        1,
        _maxDelay.inSeconds,
      ),
    );
    _reconnectAttempts++;

    debugPrint(
      'WS: scheduling reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_shouldReconnect && _pendingAuthToken != null) {
        _doConnect(_pendingAuthToken!);
      }
    });
  }

  /// Disconnect permanently. Call ONLY on logout.
  Future<void> disconnect() async {
    _shouldReconnect = false;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _pendingAuthToken = null;
  }
}
