import 'package:state_notifier/state_notifier.dart';
import '../models/models.dart';
import '../services/chat_service.dart';

/// Sealed state for conversation list — mutually exclusive states.
sealed class ConversationListViewState {
  const ConversationListViewState();
}

class ConversationListViewInitial extends ConversationListViewState {
  const ConversationListViewInitial();
}

class ConversationListViewLoading extends ConversationListViewState {
  const ConversationListViewLoading();
}

class ConversationListViewData extends ConversationListViewState {
  final List<Conversation> conversations;
  final String? currentUserId;
  const ConversationListViewData({
    required this.conversations,
    this.currentUserId,
  });

  ConversationListViewData copyWith({
    List<Conversation>? conversations,
    String? currentUserId,
  }) {
    return ConversationListViewData(
      conversations: conversations ?? this.conversations,
      currentUserId: currentUserId ?? this.currentUserId,
    );
  }
}

class ConversationListViewError extends ConversationListViewState {
  final String message;
  const ConversationListViewError(this.message);
}

/// Manages conversation list state including pending incoming requests.
class ConversationListNotifier
    extends StateNotifier<ConversationListViewState> {
  final ChatService _chatService;

  ConversationListNotifier({ChatService? chatService})
    : _chatService = chatService ?? ChatService(),
      super(const ConversationListViewInitial());

  Future<void> loadConversations() async {
    state = const ConversationListViewLoading();
    try {
      final connections = await _chatService.getConnections();
      state = ConversationListViewData(conversations: connections);
    } catch (e) {
      state = ConversationListViewError(e.toString());
    }
  }

  Future<void> acceptConnection(String connectionId) async {
    await _chatService.acceptConnection(connectionId);
    await loadConversations();
  }

  Future<void> rejectConnection(String connectionId) async {
    await _chatService.rejectConnection(connectionId);
    await loadConversations();
  }

  void refreshOnWsEvent(String eventType) {
    if (eventType == 'connection_established' ||
        eventType == 'connection_rejected' ||
        eventType == 'connection_request') {
      loadConversations();
    }
  }
}
