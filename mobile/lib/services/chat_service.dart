import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'base_service.dart';

class ChatService extends BaseService {
  static const _uuid = Uuid();

  /// GET /api/agent/plans — pending agent action plans awaiting user
  /// confirmation. The confirmation token only ever travels through this
  /// authenticated API, never through model-visible chat text.
  Future<List<AgentPlan>> getAgentPlans() async {
    final headers = await authHeaders();
    final response = await get(Uri.parse('$baseUrl/api/agent/plans'), headers);
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => AgentPlan.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/agent/plans/{id}/confirm — confirm a proposed agent action.
  /// L2 plans execute on the first confirmation; L3 plans return
  /// `needs_second_confirmation` first and execute on the second call.
  Future<AgentPlanConfirmResult> confirmAgentPlan(
    String id,
    String confirmationToken,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agent/plans/$id/confirm'),
      headers,
      jsonEncode({'confirmation_token': confirmationToken}),
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    return AgentPlanConfirmResult(
      status: data['status']?.toString() ?? '',
      result: data['result']?.toString() ?? '',
    );
  }

  /// POST /api/agent/plans/{id}/cancel — discard a proposed agent action.
  Future<void> cancelAgentPlan(String id) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/agent/plans/$id/cancel'),
      headers,
      jsonEncode({}),
    );
    handleResponse(response, (_) {});
  }

  /// GET /api/actions/undoable — writes the assistant already made that can
  /// still be reverted.
  ///
  /// Distinct from [getAgentPlans]: those are waiting on the user, these have
  /// happened. Low-risk actions run immediately and stay recoverable, so the
  /// common case is not taxed with a confirmation dialog.
  Future<List<UndoableAction>> getUndoableActions() async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/actions/undoable'),
      headers,
    );
    final data = handleResponse(response, (d) => d as Map<String, dynamic>);
    final items = data['items'] as List<dynamic>? ?? [];
    return items
        .map((e) => UndoableAction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/actions/{id}/undo — revert an action inside its window.
  ///
  /// A 409 here is usually not an error the user caused: it means the target
  /// changed after the action, so reverting would have overwritten that change.
  /// It is surfaced as [UndoResult.conflict] with the server's explanation
  /// rather than thrown, because the user needs to read what happened.
  Future<UndoResult> undoAction(String id) async {
    final headers = await authHeaders();
    try {
      final response = await post(
        Uri.parse('$baseUrl/api/actions/$id/undo'),
        headers,
        jsonEncode({}),
      );
      final data = handleResponse(response, (d) => d as Map<String, dynamic>);
      return UndoResult(
        undone: true,
        conflict: false,
        message: data['result']?.toString() ?? '',
      );
    } on ConflictException catch (e) {
      return UndoResult(undone: false, conflict: true, message: e.message);
    }
  }

  Future<AssistantConversationHistory> getAssistantHistory({
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/chat/assistant',
    ).replace(queryParameters: {'limit': '$limit', 'offset': '$offset'});
    final response = await get(uri, headers);
    return handleResponse(
      response,
      (data) =>
          AssistantConversationHistory.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<String> sendChatMessage(ChatMessage message) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat'),
      headers,
      jsonEncode(message.toJson()),
    );
    return handleResponse(
      response,
      (data) => data['reply'] ?? 'Empty response',
    );
  }

  Future<Conversation> createConversation({
    required String recipientId,
    required ConversationMode mode,
    required String content,
    String? listingId,
    String? subject,
    String? clientRequestId,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{
      'client_request_id': clientRequestId ?? _uuid.v4(),
      'recipient_id': recipientId,
      'mode': mode.wireValue,
      'content': content,
      'listing_id': ?listingId,
      'subject': ?subject,
    };
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations'),
      headers,
      jsonEncode(body),
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(
        (data['conversation'] ?? data) as Map<String, dynamic>,
      ),
    );
  }

  Future<List<Conversation>> getConversations({
    ConversationMode? mode,
    String? cursor,
    int limit = 30,
  }) async {
    final headers = await authHeaders();
    final query = <String, String>{
      'limit': '$limit',
      'mode': ?mode?.wireValue,
      'cursor': ?cursor,
    };
    final uri = Uri.parse(
      '$baseUrl/api/chat/conversations',
    ).replace(queryParameters: query);
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChatThread>> getThreads({
    ConversationMode? mode,
    int limit = 50,
  }) async {
    final headers = await authHeaders();
    final query = <String, String>{
      'limit': '$limit',
      'mode': mode?.wireValue ?? 'all',
    };
    final uri = Uri.parse(
      '$baseUrl/api/chat/threads',
    ).replace(queryParameters: query);
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .map((item) => ChatThread.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ChatThreadDetail> getThread(
    String peerUserId, {
    ConversationMode? mode,
  }) async {
    final headers = await authHeaders();
    final query = <String, String>{'mode': mode?.wireValue ?? 'all'};
    final uri = Uri.parse(
      '$baseUrl/api/chat/threads/$peerUserId',
    ).replace(queryParameters: query);
    final response = await get(uri, headers);
    return handleResponse(
      response,
      (data) => ChatThreadDetail.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Conversation> getConversation(String conversationId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId'),
      headers,
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Conversation> respondConversation(
    String conversationId, {
    required bool accept,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/respond'),
      headers,
      jsonEncode({'decision': accept ? 'accept' : 'decline'}),
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Conversation> acknowledgeConversation(String conversationId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/ack'),
      headers,
      '{}',
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Conversation> closeConversation(String conversationId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/close'),
      headers,
      '{}',
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<Conversation> archiveConversation(
    String conversationId, {
    required bool archived,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/archive'),
      headers,
      jsonEncode({'archived': archived}),
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<ConversationMessage> sendMessage(
    String conversationId, {
    required String content,
    String? replyToMessageId,
    Map<String, String>? quote,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
  }) async {
    final headers = await authHeaders();
    final body = <String, dynamic>{
      'client_message_id': _uuid.v4(),
      'content': content,
      'reply_to_message_id': ?int.tryParse(replyToMessageId ?? ''),
      'quote': ?quote,
      'image_base64': ?imageBase64,
      'audio_base64': ?audioBase64,
      'image_url': ?imageUrl,
      'audio_url': ?audioUrl,
    };
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/messages'),
      headers,
      jsonEncode(body),
    );
    return handleResponse(
      response,
      (data) => ConversationMessage.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<ConversationMessage> setMessageReaction(
    String messageId,
    String emoji,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/messages/$messageId/reaction'),
      headers,
      jsonEncode({'emoji': emoji}),
    );
    return handleResponse(
      response,
      (data) => ConversationMessage.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<ConversationMessage> deleteMessageReaction(String messageId) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/chat/messages/$messageId/reaction'),
      headers,
    );
    return handleResponse(
      response,
      (data) => ConversationMessage.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<void> hideMessage(String messageId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/messages/$messageId/hide'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  Future<String> reportMessage(
    String messageId, {
    required String reason,
    String? details,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/messages/$messageId/report'),
      headers,
      jsonEncode({'reason': reason, 'details': ?details}),
    );
    return handleResponse(
      response,
      (data) => (data as Map<String, dynamic>)['report_id']?.toString() ?? '',
    );
  }

  Future<Map<String, dynamic>> createSpace({
    required String kind,
    required String name,
    String? description,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/spaces'),
      headers,
      jsonEncode({'kind': kind, 'name': name, 'description': ?description}),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<List<Map<String, dynamic>>> getSpaces({String? kind}) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/chat/spaces',
    ).replace(queryParameters: {'kind': ?kind});
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .map((item) => item as Map<String, dynamic>)
        .toList();
  }

  Future<Map<String, dynamic>> getSpace(String spaceId) async {
    final headers = await authHeaders();
    final response = await get(
      Uri.parse('$baseUrl/api/chat/spaces/$spaceId'),
      headers,
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> sendSpaceMessage(
    String spaceId, {
    required String content,
    String? replyToMessageId,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/spaces/$spaceId/messages'),
      headers,
      jsonEncode({
        'client_message_id': _uuid.v4(),
        'content': content,
        'reply_to_message_id': ?int.tryParse(replyToMessageId ?? ''),
      }),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<List<Map<String, dynamic>>> getSpaceMessages(
    String spaceId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/chat/spaces/$spaceId/messages',
    ).replace(queryParameters: {'limit': '$limit', 'offset': '$offset'});
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .map((item) => item as Map<String, dynamic>)
        .toList();
  }

  Future<Map<String, dynamic>> createCall({
    required String conversationId,
    required String media,
    required String offerSdp,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/calls'),
      headers,
      jsonEncode({
        'conversation_id': conversationId,
        'media': media,
        'offer_sdp': offerSdp,
      }),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> sendSecretMessage(
    String sessionId, {
    required String ciphertext,
    required String nonce,
    required String keyFingerprint,
    String? expiresAt,
  }) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/secret-sessions/$sessionId/messages'),
      headers,
      jsonEncode({
        'client_message_id': _uuid.v4(),
        'ciphertext': ciphertext,
        'nonce': nonce,
        'key_fingerprint': keyFingerprint,
        'expires_at': ?expiresAt,
      }),
    );
    return handleResponse(response, (data) => data as Map<String, dynamic>);
  }

  Future<List<ConversationMessage>> getChatConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final headers = await authHeaders();
    final uri = Uri.parse(
      '$baseUrl/api/chat/conversations/$conversationId/messages?limit=$limit&offset=$offset',
    );
    final response = await get(uri, headers);
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['messages'] as List<dynamic>? ?? const [])
        .map(
          (item) => ConversationMessage.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> markConversationRead(String conversationId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/read'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  Future<Conversation> setConversationReadPreference(
    String conversationId,
    String mode,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse(
        '$baseUrl/api/chat/conversations/$conversationId/read-preference',
      ),
      headers,
      jsonEncode({'mode': mode}),
    );
    return handleResponse(
      response,
      (data) => Conversation.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<ConversationMessage> editMessage(
    String messageId,
    String content,
  ) async {
    final headers = await authHeaders();
    final response = await patch(
      Uri.parse('$baseUrl/api/chat/messages/$messageId'),
      headers,
      jsonEncode({'content': content}),
    );
    return handleResponse(
      response,
      (data) => ConversationMessage.fromJson(data as Map<String, dynamic>),
    );
  }

  Future<void> sendTyping(String conversationId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/conversations/$conversationId/typing'),
      headers,
      '{}',
    );
    handleResponse(response, (_) {});
  }

  Future<List<ReplySuggestion>> getReplySuggestions(
    String conversationId,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse(
        '$baseUrl/api/chat/conversations/$conversationId/reply-suggestions',
      ),
      headers,
      '{}',
    );
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    return (data['suggestions'] as List<dynamic>? ?? const [])
        .map((item) => ReplySuggestion.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> blockUser(String userId) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/chat/blocks'),
      headers,
      jsonEncode({'user_id': userId}),
    );
    handleResponse(response, (_) {});
  }

  Future<void> unblockUser(String userId) async {
    final headers = await authHeaders();
    final response = await delete(
      Uri.parse('$baseUrl/api/chat/blocks/$userId'),
      headers,
    );
    handleResponse(response, (_) {});
  }

  Future<List<Conversation>> getConnections() => getConversations();
  Future<void> requestConnection(String receiverId, {String? listingId}) async {
    await createConversation(
      recipientId: receiverId,
      listingId: listingId,
      mode: ConversationMode.realtime,
      content: '你好，想和你聊聊这个商品。',
    );
  }

  Future<void> acceptConnection(String conversationId) async {
    await respondConversation(conversationId, accept: true);
  }

  Future<void> rejectConnection(String conversationId) async {
    await respondConversation(conversationId, accept: false);
  }

  Future<void> markConnectionAsRead(String conversationId) =>
      markConversationRead(conversationId);
  Future<void> markMessageRead(String messageId) async {}
}
