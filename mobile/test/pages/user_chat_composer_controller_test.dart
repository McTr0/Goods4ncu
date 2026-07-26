import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/user_chat_composer_controller.dart';
import 'package:goods4ncu_mobile/providers/chat_notifier.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

Future<void> flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeChatService extends ChatService {
  _FakeChatService({
    this.messages = const [],
    this.reply,
    this.editReply,
    this.throwOnSend = false,
    this.throwOnEdit = false,
  });

  final List<ConversationMessage> messages;
  final ConversationMessage? reply;
  final ConversationMessage? editReply;
  final bool throwOnSend;
  final bool throwOnEdit;

  String? sentContent;
  String? editedMessageId;
  String? editedContent;
  int typingCalls = 0;

  @override
  Future<List<ConversationMessage>> getChatConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async => messages;

  @override
  Future<void> markConnectionAsRead(String conversationId) async {}

  @override
  Future<void> markConversationRead(String conversationId) async {}

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
    if (throwOnSend) {
      throw Exception('send failed');
    }
    sentContent = content;
    return reply ??
        ConversationMessage(
          id: 'sent-1',
          conversationId: conversationId,
          senderId: 'user-me',
          content: content,
          sentAt: DateTime.now(),
        );
  }

  @override
  Future<ConversationMessage> editMessage(
    String messageId,
    String content,
  ) async {
    if (throwOnEdit) {
      throw Exception('edit failed');
    }
    editedMessageId = messageId;
    editedContent = content;
    return editReply ??
        ConversationMessage(
          id: messageId,
          conversationId: 'conv-1',
          senderId: 'user-me',
          content: content,
          sentAt: DateTime.now(),
          editedAt: DateTime.now(),
        );
  }

  @override
  Future<void> sendTyping(String conversationId) async {
    typingCalls += 1;
  }
}

class _FakeUserService extends UserService {
  @override
  Future<Map<String, dynamic>> getUserProfile() async => {'user_id': 'user-me'};
}

Conversation _activeConversation() {
  return Conversation(
    id: 'conv-1',
    requesterId: 'user-me',
    otherUserId: 'user-other',
    otherUsername: 'Other',
    state: ConversationState.active,
    capabilities: const ConversationCapabilities(canSend: true),
  );
}

void main() {
  test(
    'startEditMessage and cancelEdit keep text controller in sync',
    () async {
      final notifier = ChatNotifier(
        conversationId: 'conv-1',
        chatService: _FakeChatService(),
        userService: _FakeUserService(),
      );
      await flushAsync();
      final controller = UserChatComposerController(chatNotifier: notifier);

      final message = ConversationMessage(
        id: 'm1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'draft text',
        sentAt: DateTime.now(),
      );

      controller.startEditMessage(message);
      expect(controller.textController.text, 'draft text');
      expect(controller.editingMessageId, 'm1');

      controller.cancelEdit();
      expect(controller.textController.text, isEmpty);
      expect(controller.editingMessageId, isNull);

      controller.dispose();
      notifier.dispose();
    },
  );

  test('confirmEdit returns success message and clears input', () async {
    final chatService = _FakeChatService(
      editReply: ConversationMessage(
        id: 'm1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'after',
        sentAt: DateTime.now(),
        editedAt: DateTime.now(),
      ),
    );
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: chatService,
      userService: _FakeUserService(),
    );
    await flushAsync();
    final controller = UserChatComposerController(chatNotifier: notifier);

    controller.startEditMessage(
      ConversationMessage(
        id: 'm1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'before',
        sentAt: DateTime.now(),
      ),
    );
    controller.textController.text = 'after';

    final message = await controller.confirmEdit();

    expect(message, '消息已编辑');
    expect(chatService.editedMessageId, 'm1');
    expect(chatService.editedContent, 'after');
    expect(controller.textController.text, isEmpty);

    controller.dispose();
    notifier.dispose();
  });

  test('sendMessage forwards content when connected', () async {
    final chatService = _FakeChatService(
      reply: ConversationMessage(
        id: 'sent-1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'hello',
        sentAt: DateTime.now(),
      ),
    );
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: chatService,
      userService: _FakeUserService(),
    );
    await flushAsync();
    notifier.setConnectionStatus('connected');
    final controller = UserChatComposerController(chatNotifier: notifier);
    controller.textController.text = 'hello';

    await controller.sendMessage();

    expect(chatService.sentContent, 'hello');
    expect(controller.textController.text, isEmpty);

    controller.dispose();
    notifier.dispose();
  });

  test('sendMessage can operate after initial messages hydrate', () async {
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: _FakeChatService(
        messages: [
          ConversationMessage(
            id: 'm0',
            conversationId: 'conv-1',
            senderId: 'user-other',
            content: 'earlier',
            sentAt: DateTime.now(),
          ),
        ],
      ),
      userService: _FakeUserService(),
    );
    await flushAsync();
    notifier.setConnectionStatus('connected');
    final controller = UserChatComposerController(chatNotifier: notifier);
    controller.textController.text = 'hello';

    await controller.sendMessage();

    final state = notifier.currentState as ChatViewData;
    expect(state.messages, isNotEmpty);

    controller.dispose();
    notifier.dispose();
  });

  test('sendMessage rejects disconnected conversations', () async {
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: _FakeChatService(),
      userService: _FakeUserService(),
    );
    await flushAsync();
    final controller = UserChatComposerController(chatNotifier: notifier);
    controller.textController.text = 'hello';

    await expectLater(
      controller.sendMessage(),
      throwsA(
        isA<UserChatComposerException>().having(
          (e) => e.message,
          'message',
          '等待连接建立后再发送消息',
        ),
      ),
    );

    controller.dispose();
    notifier.dispose();
  });

  test('confirmEdit surfaces backend edit failures', () async {
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: _FakeChatService(throwOnEdit: true),
      userService: _FakeUserService(),
    );
    await flushAsync();
    final controller = UserChatComposerController(chatNotifier: notifier);

    controller.startEditMessage(
      ConversationMessage(
        id: 'm1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'before',
        sentAt: DateTime.now(),
      ),
    );
    controller.textController.text = 'after';

    await expectLater(
      controller.confirmEdit(),
      throwsA(
        isA<UserChatComposerException>().having(
          (e) => e.message,
          'message',
          contains('编辑失败'),
        ),
      ),
    );

    controller.dispose();
    notifier.dispose();
  });

  test('sendMessage surfaces backend send failures', () async {
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: _FakeChatService(throwOnSend: true),
      userService: _FakeUserService(),
    );
    await flushAsync();
    notifier.setConnectionStatus('connected');
    final controller = UserChatComposerController(chatNotifier: notifier);
    controller.textController.text = 'hello';

    await expectLater(
      controller.sendMessage(),
      throwsA(
        isA<UserChatComposerException>().having(
          (e) => e.message,
          'message',
          contains('发送失败'),
        ),
      ),
    );

    controller.dispose();
    notifier.dispose();
  });

  test('sendTypingIndicator delegates to chat service', () async {
    final chatService = _FakeChatService();
    final notifier = ChatNotifier(
      conversationId: 'conv-1',
      chatService: chatService,
      userService: _FakeUserService(),
    );
    await flushAsync();
    final controller = UserChatComposerController(chatNotifier: notifier);
    notifier.setConversation(_activeConversation());

    controller.sendTypingIndicator();
    await flushAsync();

    expect(chatService.typingCalls, 1);

    controller.dispose();
    notifier.dispose();
  });
}
