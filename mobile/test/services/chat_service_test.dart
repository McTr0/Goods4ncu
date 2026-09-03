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
          'status': 'delivered',
          'edited_at': '2024-01-15T11:00:00Z',
        };

        final message = ConversationMessage.fromJson(json);

        expect(message.id, 'msg-123');
        expect(message.conversationId, 'conv-456');
        expect(message.senderId, 'user-789');
        expect(message.content, 'Hello, how are you?');
        expect(message.sentAt, DateTime.parse('2024-01-15T10:30:00Z'));
        expect(message.status, 'sent');
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
          expect(
            message.status,
            status == 'delivered' || status == 'read' ? 'sent' : status,
          );
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

      test('handles image_base64', () {
        final jsonWithBase64 = {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'image_url': 'https://example.com/img.jpg',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithBase64).imageUrl,
          'https://example.com/img.jpg',
        );
      });

      test('handles audio_url', () {
        final jsonWithBase64 = {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'sender': 'user-1',
          'content': 'Test',
          'audio_url': 'https://example.com/aud.mp3',
          'sent_at': '2024-01-15T10:00:00Z',
        };

        expect(
          ConversationMessage.fromJson(jsonWithBase64).audioUrl,
          'https://example.com/aud.mp3',
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
          imageUrl: 'https://example.com/img123.jpg',
          audioUrl: 'https://example.com/aud456.mp3',
          timestamp: timestamp,
          isPartial: false,
        );

        expect(message.sender, 'user-123');
        expect(message.content, 'Hello!');
        expect(message.imageUrl, 'https://example.com/img123.jpg');
        expect(message.audioUrl, 'https://example.com/aud456.mp3');
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
          imageUrl: 'https://example.com/img.jpg',
          audioUrl: 'https://example.com/aud.mp3',
          timestamp: DateTime.now(),
        );

        final json = message.toJson();

        expect(json['message'], 'Test message');
        expect(json['image_url'], 'https://example.com/img.jpg');
        expect(json['audio_url'], 'https://example.com/aud.mp3');
      });

      test('toJson with null optionals', () {
        final message = ChatMessage(
          sender: 'user-123',
          content: 'Text only',
          timestamp: DateTime.now(),
        );

        final json = message.toJson();

        expect(json['message'], 'Text only');
        expect(json['image_url'], isNull);
        expect(json['audio_url'], isNull);
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
        expect(conversation.unreadCount, 0);
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
