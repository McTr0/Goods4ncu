import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/ws_service.dart';

void main() {
  group('WsNotification', () {
    test('parses new_message event correctly', () {
      final json = {
        'id': 'notif-123',
        'event': 'new_message',
        'event_type': 'new_message',
        'title': 'New message',
        'body': 'You have a new message from Alice',
        'related_order_id': null,
        'related_listing_id': null,
        'negotiation_id': null,
        'connection_id': null,
        'message_id': 'msg-456',
        'conversation_id': 'conv-789',
        'user_id': 'user-alice',
        'username': 'alice',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.id, 'notif-123');
      expect(notification.eventType, 'new_message');
      expect(notification.title, 'New message');
      expect(notification.body, 'You have a new message from Alice');
      expect(notification.messageId, 'msg-456');
      expect(notification.conversationId, 'conv-789');
      expect(notification.typingUserId, 'user-alice');
      expect(notification.typingUsername, 'alice');
    });

    test('parses typing event correctly', () {
      final json = {
        'event': 'typing',
        'event_type': 'typing',
        'title': 'Typing',
        'body': 'Alice is typing...',
        'conversation_id': 'conv-123',
        'user_id': 'user-alice',
        'username': 'alice',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'typing');
      expect(notification.conversationId, 'conv-123');
      expect(notification.typingUserId, 'user-alice');
      expect(notification.typingUsername, 'alice');
    });

    test('parses connection_request event correctly', () {
      final json = {
        'event': 'connection_request',
        'event_type': 'connection_request',
        'title': 'Connection Request',
        'body': 'Bob wants to connect with you',
        'connection_id': 'conn-456',
        'user_id': 'user-bob',
        'username': 'bob',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'connection_request');
      expect(notification.title, 'Connection Request');
      expect(notification.body, 'Bob wants to connect with you');
      expect(notification.connectionId, 'conn-456');
      expect(notification.typingUserId, 'user-bob');
      expect(notification.typingUsername, 'bob');
    });

    test('parses connection_established event correctly', () {
      final json = {
        'event': 'connection_established',
        'event_type': 'connection_established',
        'title': 'Connection Established',
        'body': 'You are now connected with Alice',
        'connection_id': 'conn-123',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'connection_established');
      expect(notification.connectionId, 'conn-123');
    });

    test('parses message_read event correctly', () {
      final json = {
        'event': 'message_read',
        'event_type': 'message_read',
        'title': 'Message Read',
        'body': 'Alice read your message',
        'message_id': 'msg-789',
        'conversation_id': 'conv-123',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'message_read');
      expect(notification.messageId, 'msg-789');
      expect(notification.conversationId, 'conv-123');
    });

    test('handles missing optional fields gracefully', () {
      final json = {
        'event': 'new_message',
        'title': 'Test',
        'body': 'Test body',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.id, isNull);
      expect(notification.eventType, 'new_message');
      expect(notification.title, 'Test');
      expect(notification.body, 'Test body');
      expect(notification.relatedOrderId, isNull);
      expect(notification.relatedListingId, isNull);
      expect(notification.negotiationId, isNull);
      expect(notification.connectionId, isNull);
      expect(notification.messageId, isNull);
      expect(notification.conversationId, isNull);
      expect(notification.typingUserId, isNull);
      expect(notification.typingUsername, isNull);
    });

    test('handles null values gracefully', () {
      final json = <String, dynamic>{
        'id': null,
        'event': null,
        'event_type': null,
        'title': null,
        'body': null,
        'related_order_id': null,
        'related_listing_id': null,
        'negotiation_id': null,
        'connection_id': null,
        'message_id': null,
        'conversation_id': null,
        'user_id': null,
        'username': null,
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.id, isNull);
      expect(notification.eventType, '');
      expect(notification.title, '');
      expect(notification.body, '');
      expect(notification.relatedOrderId, isNull);
      expect(notification.relatedListingId, isNull);
      expect(notification.negotiationId, isNull);
      expect(notification.connectionId, isNull);
      expect(notification.messageId, isNull);
      expect(notification.conversationId, isNull);
      expect(notification.typingUserId, isNull);
      expect(notification.typingUsername, isNull);
    });

    test('handles integer id values by converting to string', () {
      final json = {
        'id': 12345,
        'event': 'test',
        'event_type': 'test',
        'title': 'Test',
        'body': 'Body',
        'message_id': 67890,
        'connection_id': 11111,
        'conversation_id': 22222,
        'user_id': 33333,
        'username': 'testuser',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.id, '12345');
      expect(notification.messageId, '67890');
      expect(notification.connectionId, '11111');
      expect(notification.conversationId, '22222');
      expect(notification.typingUserId, '33333');
    });

    test('prefers event field over event_type when both present', () {
      final json = {
        'event': 'preferred_event',
        'event_type': 'fallback_event',
        'title': 'Test',
        'body': 'Body',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'preferred_event');
    });

    test('uses event_type when event field is missing', () {
      final json = {
        'event_type': 'type_only_event',
        'title': 'Test',
        'body': 'Body',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.eventType, 'type_only_event');
    });

    test('handles empty json gracefully', () {
      final json = <String, dynamic>{};

      final notification = WsNotification.fromJson(json);

      expect(notification.id, isNull);
      expect(notification.eventType, '');
      expect(notification.title, '');
      expect(notification.body, '');
    });

    test('parses order-related notification fields', () {
      final json = {
        'event': 'order_update',
        'title': 'Order Update',
        'body': 'Your order has been shipped',
        'related_order_id': 'order-123',
        'related_listing_id': 'listing-456',
        'negotiation_id': 'neg-789',
      };

      final notification = WsNotification.fromJson(json);

      expect(notification.relatedOrderId, 'order-123');
      expect(notification.relatedListingId, 'listing-456');
      expect(notification.negotiationId, 'neg-789');
    });
  });
}
