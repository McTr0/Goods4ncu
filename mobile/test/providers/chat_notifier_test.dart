import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/providers/chat_notifier.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

Future<void> flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class FakeChatService extends ChatService {
  FakeChatService({
    this.messages = const [],
    this.connections = const [],
    this.conversation,
    this.reply,
  });

  List<ConversationMessage> messages;
  List<Conversation> connections;
  Conversation? conversation;
  ConversationMessage? reply;
  String? sentContent;
  String? sentImageBase64;
  String? sentAudioBase64;
  String? sentImageUrl;
  String? sentAudioUrl;
  int loadMessagesCalls = 0;

  @override
  Future<List<ConversationMessage>> getChatConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    loadMessagesCalls += 1;
    return messages;
  }

  @override
  Future<List<Conversation>> getConnections() async => connections;

  @override
  Future<Conversation> getConversation(String conversationId) async {
    return conversation ??
        connections.firstWhere((item) => item.id == conversationId);
  }

  @override
  Future<ConversationMessage> sendMessage(
    String conversationId, {
    required String content,
    String? replyToMessageId,
    String? imageBase64,
    String? audioBase64,
    String? imageUrl,
    String? audioUrl,
    Map<String, String>? quote,
  }) async {
    sentContent = content;
    sentImageBase64 = imageBase64;
    sentAudioBase64 = audioBase64;
    sentImageUrl = imageUrl;
    sentAudioUrl = audioUrl;
    return reply ??
        ConversationMessage(
          id: 'server-1',
          conversationId: conversationId,
          senderId: 'user-me',
          content: content,
          imageBase64: imageBase64,
          audioBase64: audioBase64,
          imageUrl: imageUrl,
          audioUrl: audioUrl,
          sentAt: DateTime.now(),
        );
  }

  @override
  Future<ConversationMessage> editMessage(
    String messageId,
    String content,
  ) async {
    return ConversationMessage(
      id: messageId,
      conversationId: 'conv-1',
      senderId: 'user-me',
      content: content,
      sentAt: DateTime.now(),
      editedAt: DateTime.now(),
    );
  }
}

class FakeUserService extends UserService {
  FakeUserService(this.profile);

  final Map<String, dynamic> profile;

  @override
  Future<Map<String, dynamic>> getUserProfile() async => profile;
}

void main() {
  test('hydrates current user and normalizes established status', () async {
    final conversation = Conversation(
      id: 'conv-1',
      requesterId: 'user-other',
      otherUserId: 'user-other',
      otherUsername: 'Other',
      status: 'established',
    );
    final chatService = FakeChatService(
      messages: [
        ConversationMessage(
          id: 'm1',
          conversationId: 'conv-1',
          senderId: 'user-other',
          content: 'hello',
          sentAt: DateTime.now(),
        ),
      ],
      connections: [conversation],
      conversation: conversation,
    );
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: chatService,
      userService: FakeUserService({'user_id': 'user-me'}),
    );

    await flushAsync();
    await notifier.hydrateConnectionStatus();
    await flushAsync();

    final state = notifier.currentState as ChatViewData;
    expect(state.currentUserId, 'user-me');
    expect(state.connectionStatus, 'active');
    expect(state.messages, hasLength(1));
    notifier.dispose();
  });

  test('sendMessage supports URL-only media sends', () async {
    final chatService = FakeChatService(
      messages: const [],
      reply: ConversationMessage(
        id: 'server-2',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: '[图片消息]',
        imageUrl: 'https://cdn.example/image.jpg',
        sentAt: DateTime.now(),
      ),
    );
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: chatService,
      userService: FakeUserService({'user_id': 'user-me'}),
    );

    await flushAsync();
    notifier.setConnectionStatus('connected');

    await notifier.sendMessage(
      content: '[图片消息]',
      imageUrl: 'https://cdn.example/image.jpg',
    );

    final state = notifier.currentState as ChatViewData;
    expect(chatService.sentContent, '[图片消息]');
    expect(chatService.sentImageBase64, isNull);
    expect(chatService.sentImageUrl, 'https://cdn.example/image.jpg');
    expect(state.messages.single.id, 'server-2');
    expect(state.messages.single.imageUrl, 'https://cdn.example/image.jpg');
    expect(state.messages.single.imageBase64, isNull);
    notifier.dispose();
  });

  test(
    'connection_established reloads messages and marks conversation connected',
    () async {
      final chatService = FakeChatService(
        messages: const [],
        conversation: Conversation(
          id: 'conv-1',
          requesterId: 'user-other',
          otherUserId: 'user-other',
          otherUsername: 'Other',
          state: ConversationState.active,
        ),
      );
      final notifier = ChatNotifier(
        conversationId: 'conv-1',
        chatService: chatService,
        userService: FakeUserService({'user_id': 'user-me'}),
      );

      await flushAsync();
      chatService.messages = [
        ConversationMessage(
          id: 'm2',
          conversationId: 'conv-1',
          senderId: 'user-other',
          content: 'after connect',
          sentAt: DateTime.now(),
        ),
      ];

      notifier.handleWsNotification('connection_established');
      await flushAsync();

      final state = notifier.currentState as ChatViewData;
      expect(state.connectionStatus, 'active');
      expect(state.messages.single.content, 'after connect');
      expect(chatService.loadMessagesCalls, greaterThanOrEqualTo(2));
      notifier.dispose();
    },
  );
}
