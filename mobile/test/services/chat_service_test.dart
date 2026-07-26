import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';

void main() {
  group('ChatService message model parsing', () {
    group('ConversationMessage.fromJson', () {
      test('parses full response correctly', () {
        final json = {
          'id': 'msg-123',
          'conversation_id': 'conv-456',
          'sender': 'user-789',
          'content': 'Hello, how are you?',
          'image_base64': 'iVBORw0KGgoAAAANSUhEUg==',
          'audio_base64': 'SUQzBAAAAAAAI1RTU0U=',
          'sent_at': '2024-01-15T10:30:00Z',
          'read_at': '2024-01-15T10:35:00Z',
          'status': 'delivered',
          'edited_at': '2024-01-15T11:00:00Z',
        };

        final message = ConversationMessage.fromJson(json);

        expect(message.id, 'msg-123');
        expect(message.conversationId, 'conv-456');
        expect(message.senderId, 'user-789');
        expect(message.content, 'Hello, how are you?');
        expect(message.imageBase64, 'iVBORw0KGgoAAAANSUhEUg==');
        expect(message.audioBase64, 'SUQzBAAAAAAAI1RTU0U=');
        expect(message.sentAt, DateTime.parse('2024-01-15T10:30:00Z'));
        expect(message.readAt, DateTime.parse('2024-01-15T10:35:00Z'));
        expect(message.status, 'delivered');
        expect(message.editedAt, DateTime.parse('2024-01-15T11:00:00Z'));
      });

      test('handles minimal json', () {
        final json = {
          'id': 'msg-minimal',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Minimal message',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        final message = ConversationMessage.fromJson(json);

        expect(message.id, 'msg-minimal');
        expect(message.conversationId, 'conv-1');
        expect(message.senderId, 'user-1');
        expect(message.content, 'Minimal message');
        expect(message.sentAt, DateTime.parse('2024-01-15T10:00:00Z'));
        expect(message.imageBase64, isNull);
        expect(message.audioBase64, isNull);
        expect(message.readAt, isNull);
        expect(message.status, 'sent'); // default
        expect(message.editedAt, isNull);
      });

      test('handles different status values', () {
        final statuses = ['sending', 'sent', 'delivered', 'read', 'failed'];

        for (final status in statuses) {
          final json = {
            'id': 'msg-1',
            'conversation_id': 'conv-1',
            'sender': 'user-1',
            'content': 'Test',
            'sent_at': '2024-01-15T10:00:00Z',
            'status': status,
          };

          final message = ConversationMessage.fromJson(json);
          expect(message.status, status);
        }
      });

      test('handles missing sent_at with timestamp fallback', () {
        final json = {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'timestamp': '2024-01-15T10:00:00Z',
        };

        final message = ConversationMessage.fromJson(json);
        expect(message.sentAt, DateTime.parse('2024-01-15T10:00:00Z'));
      });

      test('handles both image_base64 and image_data', () {
        final jsonWithBase64 = {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'image_base64': 'from_base64',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithBase64).imageBase64,
          'from_base64',
        );

        final jsonWithData = {
          'id': 'msg-2',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'image_data': 'from_data',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithData).imageBase64,
          'from_data',
        );
      });

      test('handles both audio_base64 and audio_data', () {
        final jsonWithBase64 = {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'audio_base64': 'from_base64',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithBase64).audioBase64,
          'from_base64',
        );

        final jsonWithData = {
          'id': 'msg-2',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'audio_data': 'from_data',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithData).audioBase64,
          'from_data',
        );
      });
    });

    group('ChatMessage', () {
      test('parses assistant history roles and media', () {
        final history = AssistantConversationHistory.fromJson({
          'messages': [
            {
              'id': '1',
              'role': 'user',
              'content': '帮我找一本高数教材',
              'timestamp': '2026-07-01T10:00:00Z',
            },
            {
              'id': '2',
              'role': 'assistant',
              'content': '我来帮你筛选。',
              'image_url': 'https://cdn.example.com/book.webp',
              'timestamp': '2026-07-01T10:00:01Z',
            },
          ],
          'total': 2,
        });

        expect(history.total, 2);
        expect(history.messages.first.sender, 'user');
        expect(history.latest?.sender, 'bot');
        expect(history.latest?.imageUrl, 'https://cdn.example.com/book.webp');
      });

      test('creates instance correctly', () {
        final timestamp = DateTime.now();
        final message = ChatMessage(
          sender: 'user-123',
          content: 'Hello!',
          imageBase64: 'img123',
          audioBase64: 'aud456',
          timestamp: timestamp,
          isPartial: false,
        );

        expect(message.sender, 'user-123');
        expect(message.content, 'Hello!');
        expect(message.imageBase64, 'img123');
        expect(message.audioBase64, 'aud456');
        expect(message.timestamp, timestamp);
        expect(message.isPartial, false);
      });

      test('default isPartial is false', () {
        final message = ChatMessage(
          sender: 'user-123',
          content: 'Hello!',
          timestamp: DateTime.now(),
        );

        expect(message.isPartial, false);
      });

      test('toJson produces correct structure', () {
        final message = ChatMessage(
          sender: 'user-123',
          content: 'Test message',
          imageBase64: 'image-data',
          audioBase64: 'audio-data',
          timestamp: DateTime.now(),
        );

        final json = message.toJson();

        expect(json['message'], 'Test message');
        expect(json['image'], 'image-data');
        expect(json['audio'], 'audio-data');
      });

      test('toJson with null optionals', () {
        final message = ChatMessage(
          sender: 'user-123',
          content: 'Text only',
          timestamp: DateTime.now(),
        );

        final json = message.toJson();

        expect(json['message'], 'Text only');
        expect(json['image'], isNull);
        expect(json['audio'], isNull);
      });

      test('copyWith works correctly', () {
        final original = ChatMessage(
          sender: 'user-1',
          content: 'Original',
          timestamp: DateTime.parse('2024-01-15T10:00:00Z'),
        );

        final copied = original.copyWith(content: 'Modified', isPartial: true);

        expect(copied.sender, 'user-1');
        expect(copied.content, 'Modified');
        expect(copied.isPartial, true);
        expect(copied.timestamp, DateTime.parse('2024-01-15T10:00:00Z'));
      });
    });

    group('Conversation.fromJson', () {
      test('parses full response correctly', () {
        final json = {
          'id': 'conv-123',
          'requester_id': 'user-001',
          'other_user_id': 'user-002',
          'other_username': 'alice',
          'status': 'established',
          'last_message': 'See you tomorrow!',
          'last_message_at': '2024-01-15T18:00:00Z',
          'unread_count': 3,
          'is_receiver': true,
        };

        final conversation = Conversation.fromJson(json);

        expect(conversation.id, 'conv-123');
        expect(conversation.requesterId, 'user-001');
        expect(conversation.otherUserId, 'user-002');
        expect(conversation.otherUsername, 'alice');
        expect(conversation.status, 'active');
        expect(conversation.lastMessage, 'See you tomorrow!');
        expect(
          conversation.lastMessageAt,
          DateTime.parse('2024-01-15T18:00:00Z'),
        );
        expect(conversation.unreadCount, 3);
        expect(conversation.isReceiver, true);
      });

      test('handles missing optional fields', () {
        final json = {
          'id': 'conv-minimal',
          'requester_id': 'user-1',
          'other_user_id': 'user-2',
          'other_username': 'bob',
          'status': 'pending',
        };

        final conversation = Conversation.fromJson(json);

        expect(conversation.id, 'conv-minimal');
        expect(conversation.lastMessage, isNull);
        expect(conversation.lastMessageAt, isNull);
        expect(conversation.unreadCount, 0); // default
        expect(conversation.isReceiver, false); // default
      });

      test('handles numeric IDs converted to strings', () {
        final json = {
          'id': 123,
          'requester_id': 456,
          'other_user_id': 789,
          'other_username': 'test',
          'status': 'connected',
        };

        final conversation = Conversation.fromJson(json);

        expect(conversation.id, '123');
        expect(conversation.requesterId, '456');
        expect(conversation.otherUserId, '789');
      });
    });
  });
}
