import 'package:state_notifier/state_notifier.dart';
import '../models/models.dart';
import '../services/chat_service.dart';
import '../services/chat_local_seen_storage.dart';
import '../services/user_service.dart';

/// Sealed state for chat messages — mutually exclusive states prevent boolean flag soup.
sealed class ChatViewState {
  const ChatViewState();
}

class ChatViewInitial extends ChatViewState {
  const ChatViewInitial();
}

class ChatViewLoading extends ChatViewState {
  const ChatViewLoading();
}

class ChatViewData extends ChatViewState {
  final List<ConversationMessage> messages;
  final String? currentUserId;
  final Conversation? conversation;
  final String? connectionStatus;
  final String? editingMessageId;
  final ConversationMessage? replyingToMessage;
  final bool isSending;
  const ChatViewData({
    required this.messages,
    this.currentUserId,
    this.conversation,
    this.connectionStatus,
    this.editingMessageId,
    this.replyingToMessage,
    this.isSending = false,
  });

  ChatViewData copyWith({
    List<ConversationMessage>? messages,
    String? currentUserId,
    String? connectionStatus,
    Conversation? conversation,
    String? editingMessageId,
    ConversationMessage? replyingToMessage,
    bool? isSending,
    bool clearEditing = false,
    bool clearReply = false,
  }) {
    return ChatViewData(
      messages: messages ?? this.messages,
      currentUserId: currentUserId ?? this.currentUserId,
      conversation: conversation ?? this.conversation,
      connectionStatus:
          connectionStatus ??
          conversation?.state.wireValue ??
          this.connectionStatus,
      editingMessageId: clearEditing
          ? null
          : (editingMessageId ?? this.editingMessageId),
      replyingToMessage: clearReply
          ? null
          : (replyingToMessage ?? this.replyingToMessage),
      isSending: isSending ?? this.isSending,
    );
  }
}

class ChatViewError extends ChatViewState {
  final String message;
  final List<ConversationMessage> messages;
  const ChatViewError(this.message, [this.messages = const []]);
}

/// Chat state notifier — manages message list, connection status, explicit
/// acknowledgements, and message editing for a single conversation.
class ChatNotifier extends StateNotifier<ChatViewState> {
  final ChatService _chatService;
  final UserService _userService;
  final String conversationId;
  final String? peerUserId;
  final ChatLocalSeenStorage _localSeenStorage;

  String? _currentUserId;
  String? _connectionStatus;
  Conversation? _conversation;

  ChatNotifier({
    required this.conversationId,
    this.peerUserId,
    ChatService? chatService,
    UserService? userService,
    ChatLocalSeenStorage? localSeenStorage,
  }) : _chatService = chatService ?? ChatService(),
       _userService = userService ?? UserService(),
       _localSeenStorage =
           localSeenStorage ?? SharedPreferencesChatLocalSeenStorage(),
       super(const ChatViewInitial()) {
    _loadCurrentUser();
    loadMessages();
  }

  ChatViewState get currentState => state;

  static String? _normalizeConnectionStatus(String? status) {
    if (status == 'established') {
      return 'connected';
    }
    return status;
  }

  Future<void> _loadCurrentUser() async {
    try {
      final profile = await _userService.getUserProfile();
      if (!mounted) return;
      _currentUserId = profile['user_id']?.toString();
      if (state is ChatViewData) {
        state = (state as ChatViewData).copyWith(currentUserId: _currentUserId);
      }
    } catch (_) {}
  }

  Future<void> hydrateConnectionStatus() async {
    try {
      var conversation = await _chatService.getConversation(conversationId);
      if (!mounted) return;
      if (conversation.capabilities.canAck) {
        conversation = await _chatService.acknowledgeConversation(
          conversationId,
        );
        if (!mounted) return;
      }
      setConversation(conversation);
    } catch (_) {
      // Best-effort hydrate. Live WS events and send paths still update state.
    }
  }

  Future<void> loadMessages() async {
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith();
    } else {
      state = const ChatViewLoading();
    }
    try {
      final messages = await _chatService.getChatConversationMessages(
        conversationId,
      );
      if (!mounted) return;
      final currentState = state;
      if (currentState is ChatViewData) {
        state = currentState.copyWith(
          messages: messages.reversed.toList(),
          currentUserId: _currentUserId,
          connectionStatus: _connectionStatus,
          conversation: _conversation,
          isSending: false,
        );
      } else {
        state = ChatViewData(
          messages: messages.reversed.toList(),
          currentUserId: _currentUserId,
          connectionStatus: _connectionStatus,
          conversation: _conversation,
        );
      }
      await _markLocallySeen(messages);
    } catch (e) {
      if (!mounted) return;
      state = ChatViewError(e.toString());
    }
  }

  Future<void> _markLocallySeen(List<ConversationMessage> messages) async {
    final peer = peerUserId;
    if (peer == null || peer.isEmpty || messages.isEmpty) return;
    try {
      final latest = messages
          .map((message) => message.sentAt)
          .reduce((left, right) => left.isAfter(right) ? left : right);
      await _localSeenStorage.mark(peer, latest);
    } catch (_) {
      // Local badge persistence is best effort and must never block chat.
    }
  }

  void setConnectionStatus(String? status) {
    _connectionStatus = _normalizeConnectionStatus(status);
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(
        connectionStatus: _connectionStatus,
      );
    }
  }

  void setConversation(Conversation conversation) {
    _conversation = conversation;
    _connectionStatus = conversation.state.wireValue;
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(
        conversation: conversation,
        connectionStatus: _connectionStatus,
      );
    }
  }

  void _hydrateConversationAndReload() {
    hydrateConnectionStatus().then((_) {
      if (mounted) {
        loadMessages();
      }
    });
  }

  void startEditMessage(ConversationMessage msg) {
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(editingMessageId: msg.id);
    }
  }

  void cancelEdit() {
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(clearEditing: true);
    }
  }

  void startReplyMessage(ConversationMessage msg) {
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(replyingToMessage: msg);
    }
  }

  void cancelReply() {
    if (state is ChatViewData) {
      state = (state as ChatViewData).copyWith(clearReply: true);
    }
  }

  Future<void> confirmEdit(String newContent) async {
    if (state is! ChatViewData) return;
    final currentState = state as ChatViewData;
    if (currentState.editingMessageId == null) return;

    try {
      final updated = await _chatService.editMessage(
        currentState.editingMessageId!,
        newContent,
      );
      final idx = currentState.messages.indexWhere(
        (m) => m.id == currentState.editingMessageId,
      );
      final newMessages = List<ConversationMessage>.from(currentState.messages);
      if (idx >= 0) newMessages[idx] = updated;
      state = currentState.copyWith(messages: newMessages, clearEditing: true);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> sendMessage({
    required String content,
    Map<String, String>? quote,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
  }) async {
    if (state is! ChatViewData) return;
    final currentState = state as ChatViewData;
    final canSend =
        currentState.conversation?.capabilities.canSend ??
        (currentState.connectionStatus == 'connected' ||
            currentState.connectionStatus == 'active');
    if (!canSend) {
      throw Exception('等待连接建立后再发送消息');
    }

    final tempMsg = ConversationMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: conversationId,
      senderId: currentState.currentUserId ?? '',
      content: content,
      imageBase64: imageBase64,
      audioBase64: audioBase64,
      imageUrl: imageUrl,
      audioUrl: audioUrl,
      replyToMessageId: currentState.replyingToMessage?.id,
      sentAt: DateTime.now(),
      status: 'sending',
    );

    state = currentState.copyWith(
      messages: [...currentState.messages, tempMsg],
      isSending: true,
    );

    try {
      final reply = await _chatService.sendMessage(
        conversationId,
        content: content,
        quote: quote,
        imageBase64: imageBase64,
        audioBase64: audioBase64,
        imageUrl: imageUrl,
        audioUrl: audioUrl,
        replyToMessageId: currentState.replyingToMessage?.id,
      );
      if (_conversation?.state == ConversationState.synAck) {
        await hydrateConnectionStatus();
      }
      if (!mounted) return;
      if (state is ChatViewData) {
        final s = state as ChatViewData;
        final idx = s.messages.indexWhere((m) => m.id == tempMsg.id);
        final newMessages = List<ConversationMessage>.from(s.messages);
        if (idx >= 0) newMessages[idx] = reply;
        state = s.copyWith(
          messages: newMessages,
          isSending: false,
          clearReply: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (state is ChatViewData) {
        final s = state as ChatViewData;
        state = s.copyWith(
          messages: s.messages.where((m) => m.id != tempMsg.id).toList(),
          isSending: false,
        );
      }
      rethrow;
    }
  }

  Future<void> acceptConnection(String connectionId) async {
    final conversation = await _chatService.respondConversation(
      connectionId,
      accept: true,
    );
    setConversation(conversation);
    await loadMessages();
  }

  Future<void> rejectConnection(String connectionId) async {
    final conversation = await _chatService.respondConversation(
      connectionId,
      accept: false,
    );
    setConversation(conversation);
  }

  Future<void> closeConversation() async {
    final conversation = await _chatService.closeConversation(conversationId);
    setConversation(conversation);
  }

  Future<List<ReplySuggestion>> getReplySuggestions() =>
      _chatService.getReplySuggestions(conversationId);

  Future<void> reactToMessage(ConversationMessage message, String emoji) async {
    if (state is! ChatViewData) return;
    final currentState = state as ChatViewData;
    final updated =
        message.reactions.any(
          (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
        )
        ? await _chatService.deleteMessageReaction(message.id)
        : await _chatService.setMessageReaction(message.id, emoji);
    _replaceMessage(currentState, updated);
  }

  Future<void> acknowledgeMessage(
    ConversationMessage message,
    MessageAcknowledgementKind kind,
  ) async {
    if (state is! ChatViewData) return;
    final currentState = state as ChatViewData;
    final updated = await _chatService.setMessageAcknowledgement(
      message.id,
      kind,
    );
    _replaceMessage(currentState, updated);
  }

  Future<void> withdrawMessageAcknowledgement(
    ConversationMessage message,
  ) async {
    if (state is! ChatViewData) return;
    final currentState = state as ChatViewData;
    final updated = await _chatService.deleteMessageAcknowledgement(message.id);
    _replaceMessage(currentState, updated);
  }

  Future<void> hideMessage(ConversationMessage message) async {
    if (state is! ChatViewData) return;
    await _chatService.hideMessage(message.id);
    final currentState = state as ChatViewData;
    state = currentState.copyWith(
      messages: currentState.messages.where((m) => m.id != message.id).toList(),
    );
  }

  Future<void> reportMessage(
    ConversationMessage message, {
    required String reason,
    String? details,
  }) async {
    await _chatService.reportMessage(
      message.id,
      reason: reason,
      details: details,
    );
  }

  void _replaceMessage(ChatViewData currentState, ConversationMessage updated) {
    final idx = currentState.messages.indexWhere((m) => m.id == updated.id);
    if (idx < 0) return;
    final newMessages = List<ConversationMessage>.from(currentState.messages);
    newMessages[idx] = updated;
    state = currentState.copyWith(messages: newMessages);
  }

  Future<void> blockOtherUser() async {
    final otherUserId = _conversation?.otherUserId;
    if (otherUserId == null || otherUserId.isEmpty) return;
    await _chatService.blockUser(otherUserId);
    await hydrateConnectionStatus();
  }

  void handleWsNotification(
    String eventType, {
    String? messageId,
    String? conversationId,
  }) {
    switch (eventType) {
      case 'conversation_created':
      case 'conversation_state_changed':
      case 'connection_established':
      case 'connection_rejected':
        _hydrateConversationAndReload();
        break;
      case 'new_message':
        if (messageId != null && conversationId == this.conversationId) {
          loadMessages();
        }
        break;
      case 'message_acknowledgement_changed':
      case 'message_reaction_changed':
      case 'message_hidden':
      case 'message_reported':
        loadMessages();
        break;
    }
  }
}
