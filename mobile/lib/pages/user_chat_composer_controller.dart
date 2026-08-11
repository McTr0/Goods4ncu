import 'package:flutter/material.dart';

import '../models/models.dart';
import '../providers/chat_notifier.dart';

class UserChatComposerException implements Exception {
  UserChatComposerException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UserChatComposerController {
  UserChatComposerController({required ChatNotifier chatNotifier})
    : _chatNotifier = chatNotifier;

  final ChatNotifier _chatNotifier;
  final TextEditingController textController = TextEditingController();

  ChatViewData? get _chatData {
    final state = _chatNotifier.currentState;
    return state is ChatViewData ? state : null;
  }

  String? get editingMessageId => _chatData?.editingMessageId;
  ConversationMessage? get replyingToMessage => _chatData?.replyingToMessage;

  bool get isSending => _chatData?.isSending ?? false;

  void startEditMessage(ConversationMessage message) {
    _chatNotifier.startEditMessage(message);
    textController.text = message.content;
  }

  void cancelEdit() {
    _chatNotifier.cancelEdit();
    textController.clear();
  }

  void startReplyMessage(ConversationMessage message) {
    _chatNotifier.startReplyMessage(message);
  }

  void cancelReply() {
    _chatNotifier.cancelReply();
  }

  Future<String?> confirmEdit() async {
    final editingMessageId = this.editingMessageId;
    final newContent = textController.text.trim();
    if (editingMessageId == null || newContent.isEmpty) {
      return null;
    }

    try {
      await _chatNotifier.confirmEdit(newContent);
      textController.clear();
      return '消息已编辑';
    } catch (e) {
      throw UserChatComposerException('编辑失败: $e');
    }
  }

  Future<void> sendMessage({Map<String, String>? quote}) async {
    if (isSending) {
      return;
    }

    final content = textController.text.trim();
    if (content.isEmpty) {
      return;
    }

    final chatData = _chatData;
    final canSend =
        chatData?.conversation?.capabilities.canSend ??
        (chatData?.connectionStatus == 'connected' ||
            chatData?.connectionStatus == 'active');
    if (!canSend) {
      throw UserChatComposerException('等待连接建立后再发送消息');
    }

    textController.clear();
    try {
      await _chatNotifier.sendMessage(content: content, quote: quote);
    } catch (e) {
      throw UserChatComposerException('发送失败: $e');
    }
  }

  void dispose() {
    textController.dispose();
  }
}
