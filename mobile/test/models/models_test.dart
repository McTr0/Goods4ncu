import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';

void main() {
  group('ChatThread', () {
    test('reads the server relationship key without attention fields', () {
      final thread = ChatThread.fromJson({
        'peer_user_id': 'user-b',
        'peer_username': 'Bob',
        'latest_activity_at': '2026-08-12T10:00:00Z',
        'relationship_key': 'relationship:v1:campus:user-a:user-b',
        'has_active_realtime': true,
      });

      expect(thread.relationshipKey, 'relationship:v1:campus:user-a:user-b');
      expect(thread.unreadCount, 0);
    });

    test('keeps the key absent for a legacy server response', () {
      final thread = ChatThread.fromJson({
        'peer_user_id': 'user-b',
        'peer_username': 'Bob',
        'latest_activity_at': '2026-08-12T10:00:00Z',
      });

      expect(thread.relationshipKey, isNull);
    });

    test(
      'parses only the published peer role token when supplied by a campus thread',
      () {
        final thread = ChatThread.fromJson({
          'peer_user_id': 'user-b',
          'peer_username': 'Bob',
          'latest_activity_at': '2026-08-12T10:00:00Z',
          'persona': {
            'representation_mode': 'role_character',
            'style_version': 'v1',
            'appearance_config': {
              'palette': 'plum',
              'silhouette': 'round',
              'accessory': 'leaf',
              'outfit': 'campus',
            },
            'self_descriptions': ['slow_to_warm'],
            'contact_posture': 'leave_message',
            'published_at': '2026-08-12T10:00:00Z',
          },
        });

        expect(thread.peerPersona?.isPublished, isTrue);
        expect(thread.peerPersona?.appearance.palette, 'plum');
      },
    );
  });

  group('AgentRun', () {
    test('parses the safe operational envelope without message content', () {
      final run = AgentRun.fromJson({
        'id': 'run-1',
        'trace_id': 'trace-1',
        'conversation_id': 'conversation-1',
        'route': 'search',
        'route_confidence': 0.85,
        'provider': 'gemini',
        'model': 'gemini-test',
        'prompt_template_version': 'marketplace-prompt-v1',
        'tool_schema_version': 'marketplace-tools-v1',
        'status': 'completed',
        'outcome_code': 'llm_completed',
        'retrieval_count': 2,
        'retrieval_filtered_count': 1,
        'tool_call_count': 1,
        'final_resource_ids': ['listing-a', 'listing-b'],
        'duration_ms': 25,
        'created_at': '2026-08-12T10:00:00Z',
        'completed_at': '2026-08-12T10:00:01Z',
      });

      expect(run.traceId, 'trace-1');
      expect(run.routeConfidence, 0.85);
      expect(run.provider, 'gemini');
      expect(run.retrievalCount, 2);
      expect(run.finalResourceIds, ['listing-a', 'listing-b']);
      expect(run.completed, isTrue);
      expect(run.createdAt, DateTime.parse('2026-08-12T10:00:00Z'));
    });

    test('uses safe defaults for a legacy or partial envelope', () {
      final run = AgentRun.fromJson({
        'id': 'run-2',
        'trace_id': 'trace-2',
        'conversation_id': 'conversation-2',
      });

      expect(run.route, 'chat');
      expect(run.status, 'started');
      expect(run.toolCallCount, 0);
      expect(run.finalResourceIds, isEmpty);
      expect(run.completed, isFalse);
    });
  });

  group('RelationshipSpace', () {
    test('parses a deterministic event rail and cursor', () {
      final space = RelationshipSpace.fromJson({
        'relationship_key': 'relationship:v1:campus:user-a:user-b',
        'events': [
          {
            'id': 'message:42',
            'source_type': 'message',
            'source_id': '42',
            'event_type': 'message.sent',
            'conversation_id': 'conversation-1',
            'actor_id': 'user-a',
            'occurred_at': '2026-08-12T10:00:00Z',
          },
        ],
        'next_cursor': '2026-08-12T10:00:00Z|message|42',
      });

      expect(space.relationshipKey, 'relationship:v1:campus:user-a:user-b');
      expect(space.events, hasLength(1));
      expect(space.events.single.eventType, 'message.sent');
      expect(
        space.events.single.occurredAt,
        DateTime.parse('2026-08-12T10:00:00Z'),
      );
      expect(space.nextCursor, '2026-08-12T10:00:00Z|message|42');
    });

    test(
      'parses explicit pins, quote projections, and connection recovery',
      () {
        final space = RelationshipSpace.fromJson({
          'relationship_key': 'relationship:v1:campus:user-a:user-b',
          'events': const [],
          'pins': [
            {
              'id': 'pin-1',
              'message_id': 42,
              'conversation_id': 'conversation-1',
              'actor_id': 'user-b',
              'created_at': '2026-08-12T10:01:00Z',
            },
          ],
          'shared_objects': [
            {
              'key': 'listing:item-1',
              'kind': 'listing',
              'ref_id': 'item-1',
              'snapshot': {'title': '教材'},
              'source_message_id': 42,
              'conversation_id': 'conversation-1',
              'actor_id': 'user-a',
              'created_at': '2026-08-12T10:00:00Z',
            },
          ],
          'recent_connection': {
            'conversation_id': 'conversation-1',
            'started_at': '2026-08-12T09:00:00Z',
            'ended_at': '2026-08-12T09:30:00Z',
          },
        });

        expect(space.pins.single.messageId, 42);
        expect(space.pins.single.actorId, 'user-b');
        expect(space.sharedObjects.single.snapshot['title'], '教材');
        expect(space.recentConnection?.endedAt, isNotNull);
      },
    );

    test('keeps older responses compatible', () {
      final space = RelationshipSpace.fromJson({
        'relationship_key': 'legacy',
        'events': const [],
      });

      expect(space.pins, isEmpty);
      expect(space.sharedObjects, isEmpty);
      expect(space.recentConnection, isNull);
    });
  });

  group('SocialPersona', () {
    test(
      'parses the published token presentation without attention fields',
      () {
        final persona = SocialPersona.fromJson({
          'id': 'persona-1',
          'user_id': 'user-a',
          'campus_id': 'campus-a',
          'representation_mode': 'role_character',
          'style_version': 'v1',
          'appearance_config': {
            'palette': 'plum',
            'silhouette': 'round',
            'accessory': 'leaf',
            'outfit': 'campus',
          },
          'self_descriptions': ['slow_to_warm', 'meetup_friendly'],
          'contact_posture': 'leave_message',
          'status': 'published',
          'published_at': '2026-08-12T10:00:00Z',
        });

        expect(persona.isPublished, isTrue);
        expect(persona.appearance.palette, 'plum');
        expect(persona.appearance.character, 'doro');
        expect(persona.selfDescriptions, ['slow_to_warm', 'meetup_friendly']);
        expect(persona.contactPosture, 'leave_message');
      },
    );

    test(
      'fills safe defaults when a public response omits optional fields',
      () {
        final persona = SocialPersona.fromJson({
          'representation_mode': 'trait_mapped',
          'appearance_config': <String, dynamic>{},
          'self_descriptions': <dynamic>[],
          'contact_posture': 'later',
        });

        expect(persona.status, 'draft');
        expect(persona.appearance.toJson(), {
          'palette': 'teal',
          'silhouette': 'soft',
          'accessory': 'none',
          'outfit': 'campus',
          'character': 'doro',
        });
      },
    );

    test('recognizes a public response from its published timestamp', () {
      final persona = SocialPersona.fromJson({
        'representation_mode': 'role_character',
        'style_version': 'v1',
        'appearance_config': <String, dynamic>{},
        'self_descriptions': <dynamic>[],
        'contact_posture': 'leave_message',
        'published_at': '2026-08-12T10:00:00Z',
      });

      expect(persona.isPublished, isTrue);
    });

    test('parses only an approved platform asset for public projection', () {
      final persona = SocialPersona.fromJson({
        'representation_mode': 'role_character',
        'style_version': 'v1',
        'appearance_config': <String, dynamic>{},
        'self_descriptions': <dynamic>[],
        'contact_posture': 'leave_message',
        'published_at': '2026-08-12T10:00:00Z',
        'asset': {
          'id': 'asset-1',
          'asset_type': 'illustration',
          'url': 'https://media.example.test/signed',
          'storage_key': 'persona/campus/persona/asset',
        },
      });

      expect(persona.asset, isNotNull);
      expect(persona.asset!.isReady, isTrue);
      expect(persona.asset!.url, 'https://media.example.test/signed');
    });
  });

  group('ChatSharedObject', () {
    test('parses an active file reference without treating it as a URL', () {
      final object = ChatSharedObject.fromJson({
        'id': 'object-1',
        'campus_id': 'campus-1',
        'conversation_id': 'conversation-1',
        'created_by': 'user-a',
        'kind': 'file',
        'title': '讲义.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 4096,
        'status': 'active',
        'moderation_status': 'approved',
        'storage_verified_at': '2026-08-12T10:00:01Z',
        'uploaded_size_bytes': 4096,
        'uploaded_mime_type': 'application/pdf',
        'upload_key': 'chat/campus-1/object-1',
        'download_path': '/api/chat/shared-objects/object-1/media',
        'created_at': '2026-08-12T10:00:00Z',
        'updated_at': '2026-08-12T10:00:00Z',
      });

      expect(object.isActive, isTrue);
      expect(object.uploadKey, 'chat/campus-1/object-1');
      expect(object.downloadPath, contains('/media'));
      expect(object.canonicalUrl, isNull);
      expect(object.moderationStatus, 'approved');
      expect(object.storageVerifiedAt, DateTime.parse('2026-08-12T10:00:01Z'));
      expect(object.uploadedSizeBytes, 4096);
      expect(object.uploadedMimeType, 'application/pdf');
    });

    test('keeps an unverified upload inactive', () {
      final object = ChatSharedObject.fromJson({
        'id': 'object-pending',
        'campus_id': 'campus-1',
        'conversation_id': 'conversation-1',
        'created_by': 'user-a',
        'kind': 'file',
        'title': '待上传.pdf',
        'mime_type': 'application/pdf',
        'size_bytes': 4096,
        'status': 'pending_upload',
        'moderation_status': 'not_required',
        'upload_key': 'chat/campus-1/object-pending',
        'created_at': '2026-08-12T10:00:00Z',
        'updated_at': '2026-08-12T10:00:00Z',
      });

      expect(object.isActive, isFalse);
      expect(object.moderationStatus, 'not_required');
      expect(object.storageVerifiedAt, isNull);
      expect(object.uploadedSizeBytes, isNull);
    });

    test('keeps revoked links visible as history but inactive', () {
      final object = ChatSharedObject.fromJson({
        'id': 'object-2',
        'campus_id': 'campus-1',
        'conversation_id': 'conversation-1',
        'created_by': 'user-a',
        'kind': 'link',
        'title': '课程主页',
        'canonical_url': 'https://example.com/course',
        'status': 'revoked',
        'created_at': '2026-08-12T10:00:00Z',
        'updated_at': '2026-08-12T10:01:00Z',
      });

      expect(object.isActive, isFalse);
      expect(object.canonicalUrl, 'https://example.com/course');
    });
  });

  group('ConversationMessage', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Hello, World!',
        'image_base64': 'abc123',
        'audio_base64': 'def456',
        'sent_at': '2024-01-15T10:30:00Z',
        'status': 'read',
        'edited_at': '2024-01-15T10:40:00Z',
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.id, '123');
      expect(message.conversationId, 'conv-456');
      expect(message.senderId, 'user-789');
      expect(message.content, 'Hello, World!');
      expect(message.imageBase64, 'abc123');
      expect(message.audioBase64, 'def456');
      expect(message.sentAt, DateTime.parse('2024-01-15T10:30:00Z'));
      expect(message.status, 'sent');
      expect(message.editedAt, DateTime.parse('2024-01-15T10:40:00Z'));
    });

    test(
      'parses explicit acknowledgements without treating them as read state',
      () {
        final message = ConversationMessage.fromJson({
          'id': '123',
          'conversation_id': 'conv-456',
          'sender': 'user-789',
          'content': 'Hello',
          'timestamp': '2024-01-15T10:30:00Z',
          'acknowledgements': [
            {
              'user_id': 'user-789',
              'kind': 'will_review',
              'created_at': '2024-01-15T10:40:00Z',
              'updated_at': '2024-01-15T10:41:00Z',
            },
          ],
        });

        expect(message.acknowledgements, hasLength(1));
        expect(
          message.acknowledgements.single.kind,
          MessageAcknowledgementKind.willReview,
        );
        expect(message.acknowledgementFor('user-789'), isNotNull);
      },
    );

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Hello!',
        'sent_at': '2024-01-15T10:30:00Z',
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.id, '123');
      expect(message.conversationId, 'conv-456');
      expect(message.senderId, 'user-789');
      expect(message.content, 'Hello!');
      expect(message.imageBase64, isNull);
      expect(message.audioBase64, isNull);
      expect(message.status, 'sent'); // default
      expect(message.editedAt, isNull);
    });

    test('fromJson keeps message status vocabulary closed', () {
      final message = ConversationMessage.fromJson({
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Hello!',
        'sent_at': '2024-01-15T10:30:00Z',
        'status': 'pending',
      });

      expect(message.status, 'sent');
    });

    test('fromJson falls back to timestamp field when sent_at is missing', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Hello!',
        'timestamp': '2024-01-15T10:30:00Z',
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.sentAt, DateTime.parse('2024-01-15T10:30:00Z'));
    });

    test('fromJson handles image_base64', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Image message',
        'image_base64': 'img-data-123',
        'sent_at': '2024-01-15T10:30:00Z',
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.imageBase64, 'img-data-123');
    });

    test('fromJson handles audio_base64', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': 'Audio message',
        'audio_base64': 'audio-data-123',
        'sent_at': '2024-01-15T10:30:00Z',
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.audioBase64, 'audio-data-123');
    });

    test('fromJson parses structured quote snapshots', () {
      final json = {
        'id': '123',
        'conversation_id': 'conv-456',
        'sender': 'user-789',
        'content': '看这个',
        'sent_at': '2024-01-15T10:30:00Z',
        'quote': {
          'kind': 'listing',
          'ref_id': 'listing-1',
          'snapshot': {
            'title': '二手自行车',
            'price_cny': 188,
            'status': 'active',
            'image_url': 'https://cdn.example/bike.jpg',
          },
        },
      };

      final message = ConversationMessage.fromJson(json);

      expect(message.quote, isNotNull);
      expect(message.quote!.kind, 'listing');
      expect(message.quote!.refId, 'listing-1');
      expect(message.quote!.title, '二手自行车');
      expect(message.quote!.primaryPrice, 188);
      expect(message.quote!.status, 'active');
    });

    test('copyWith preserves unchanged fields', () {
      final original = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Original content',
        imageBase64: 'img',
        audioBase64: 'aud',
        sentAt: DateTime.parse('2024-01-15T10:30:00Z'),
        status: 'sent',
        editedAt: DateTime.parse('2024-01-15T10:40:00Z'),
      );

      final modified = original.copyWith(content: 'Modified content');

      expect(modified.id, '123');
      expect(modified.conversationId, 'conv-456');
      expect(modified.senderId, 'user-789');
      expect(modified.content, 'Modified content');
      expect(modified.imageBase64, 'img');
      expect(modified.audioBase64, 'aud');
      expect(modified.sentAt, DateTime.parse('2024-01-15T10:30:00Z'));
      expect(modified.status, 'sent');
      expect(modified.editedAt, DateTime.parse('2024-01-15T10:40:00Z'));
    });

    test('copyWith with null optional fields', () {
      final original = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Original content',
        imageBase64: 'img',
        audioBase64: 'aud',
        sentAt: DateTime.parse('2024-01-15T10:30:00Z'),
      );

      // Note: copyWith uses ?? which means we can't set optional fields to null
      // This is expected behavior for immutable patterns
      final modified = original.copyWith(content: 'Modified');

      expect(modified.imageBase64, 'img');
      expect(modified.audioBase64, 'aud');
    });

    test('canEdit returns true within 15 minutes', () {
      final recentMessage = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Recent message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );

      expect(recentMessage.canEdit, isTrue);
    });

    test('canEdit returns false after 15 minutes', () {
      final oldMessage = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Old message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 20)),
      );

      expect(oldMessage.canEdit, isFalse);
    });

    test('canEdit returns false when editedAt is set', () {
      final editedMessage = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Edited message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        editedAt: DateTime.now(),
      );

      expect(editedMessage.canEdit, isFalse);
    });

    test('tombstone state when deletedAt (editedAt) is set', () {
      final tombstoneMessage = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'This message was deleted',
        sentAt: DateTime.now().subtract(const Duration(hours: 1)),
        editedAt: DateTime.now(),
      );

      // editedAt being non-null signals tombstone/deleted state
      expect(tombstoneMessage.editedAt, isNotNull);
      expect(tombstoneMessage.canEdit, isFalse);
    });

    test('isFrom returns true for matching userId', () {
      final message = ConversationMessage(
        id: '123',
        conversationId: 'conv-456',
        senderId: 'user-789',
        content: 'Test message',
        sentAt: DateTime.now(),
      );

      expect(message.isFrom('user-789'), isTrue);
      expect(message.isFrom('user-999'), isFalse);
    });
  });

  group('Listing', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'listing-123',
        'title': 'iPhone 14 Pro',
        'category': 'Electronics',
        'brand': 'Apple',
        'condition_score': 9,
        'suggested_price_cny': 5999.00,
        'description': 'Almost new',
        'status': 'active',
        'thumbnail_hint': 'iphone.jpg',
        'image_url': 'http://127.0.0.1:3001/test_product_images/iphone.jpg',
        'defects': ['Scratch on back'],
        'owner_id': 'user-456',
        'owner_username': 'johndoe',
        'created_at': '2024-01-15T10:00:00Z',
        'rank_reason': 'within_budget',
        'match_summary': ['within_budget', 'condition_match'],
        'source': 'wanted_match',
        'ranking_version': '2026.07-wanted-feedback-v1',
      };

      final listing = Listing.fromJson(json);

      expect(listing.id, 'listing-123');
      expect(listing.title, 'iPhone 14 Pro');
      expect(listing.category, 'Electronics');
      expect(listing.brand, 'Apple');
      expect(listing.conditionScore, 9);
      expect(listing.suggestedPriceCny, 5999.00);
      expect(listing.description, 'Almost new');
      expect(listing.status, 'active');
      expect(listing.thumbnailHint, 'iphone.jpg');
      expect(
        listing.imageUrl,
        'http://127.0.0.1:3001/test_product_images/iphone.jpg',
      );
      expect(listing.defects, ['Scratch on back']);
      expect(listing.ownerId, 'user-456');
      expect(listing.ownerUsername, 'johndoe');
      expect(listing.createdAt, '2024-01-15T10:00:00Z');
      expect(listing.rankReason, 'within_budget');
      expect(listing.matchSummary, ['within_budget', 'condition_match']);
      expect(listing.source, 'wanted_match');
      expect(listing.rankingVersion, '2026.07-wanted-feedback-v1');
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'listing-123',
        'title': 'iPhone 14 Pro',
        'category': 'Electronics',
        'brand': 'Apple',
        'condition_score': 9,
        'suggested_price_cny': 5999.00,
        'status': 'active',
      };

      final listing = Listing.fromJson(json);

      expect(listing.id, 'listing-123');
      expect(listing.description, isNull);
      expect(listing.thumbnailHint, isNull);
      expect(listing.imageUrl, isNull);
      expect(listing.defects, isNull);
      expect(listing.ownerId, isNull);
      expect(listing.ownerUsername, isNull);
      expect(listing.createdAt, isNull);
    });

    test('parses authoritative lifecycle and restriction actions', () {
      final listing = Listing.fromJson({
        'id': 'listing-restricted',
        'title': 'Restricted item',
        'category': 'other',
        'brand': 'NCU',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'active',
        'restriction_state': 'restricted',
        'restriction': {
          'public_reason': 'Needs review',
          'moderation_case_id': 'case-1',
          'can_appeal': true,
        },
        'available_actions': ['delete', 'buy'],
        'available_admin_actions': ['restore'],
      });

      expect(listing.isRestricted, isTrue);
      expect(listing.restriction?.reason, 'Needs review');
      expect(listing.restriction?.moderationCaseId, 'case-1');
      expect(listing.restriction?.canAppeal, isTrue);
      expect(listing.allowsAction(Listing.actionDelete), isTrue);
      expect(listing.allowsAction(Listing.actionBuy), isFalse);
      expect(listing.allowsAdminAction(Listing.adminActionRestore), isTrue);
      expect(listing.allowsAdminAction(Listing.adminActionTakedown), isFalse);
    });

    test('malformed enforcement metadata fails closed', () {
      final listing = Listing.fromJson({
        'id': 'listing-unknown-policy',
        'title': 'Unknown policy',
        'category': 'other',
        'brand': 'NCU',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'active',
        'restriction_state': 42,
        'available_actions': 'delete',
        'available_admin_actions': {'restore': true},
      });

      expect(listing.restrictionState, 'unknown');
      expect(listing.isRestricted, isTrue);
      expect(listing.availableActions, isEmpty);
      expect(listing.availableAdminActions, isEmpty);
      expect(listing.allowsAction(Listing.actionDelete), isFalse);
      expect(listing.allowsAdminAction(Listing.adminActionRestore), isFalse);
    });

    test('parses deployed flat restriction fields and action aliases', () {
      final listing = Listing.fromJson({
        'id': 'listing-flat-policy',
        'title': 'Flat policy',
        'category': 'other',
        'brand': 'NCU',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'active',
        'restricted': false,
        'restriction_reason': null,
        'available_actions': ['contact', 'create_order'],
      });

      expect(listing.restrictionState, 'clear');
      expect(listing.isRestricted, isFalse);
      expect(listing.allowsAction(Listing.actionContact), isTrue);
      expect(listing.allowsAction(Listing.actionBuy), isTrue);
      expect(listing.allowsAction(Listing.actionDelete), isFalse);
    });

    test('legacy action fallback is lifecycle-safe', () {
      final wanted = Listing.fromJson({
        'id': 'wanted-deleted',
        'title': 'Deleted request',
        'category': 'other',
        'brand': 'NCU',
        'direction': 'wanted',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'deleted',
      });
      final offer = Listing.fromJson({
        'id': 'offer-deleted',
        'title': 'Deleted offer',
        'category': 'other',
        'brand': 'NCU',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'deleted',
      });

      expect(wanted.allowsAction(Listing.actionRelist), isTrue);
      expect(wanted.allowsAction(Listing.actionFulfill), isFalse);
      expect(wanted.allowsAction(Listing.actionRecommendOffer), isFalse);
      expect(offer.allowsAction(Listing.actionBuy), isFalse);
      expect(offer.allowsAction(Listing.actionContact), isFalse);
    });

    test('fromJson handles integer price', () {
      final json = {
        'id': 'listing-123',
        'title': 'Item',
        'category': 'Cat',
        'brand': 'Brand',
        'condition_score': 5,
        'suggested_price_cny': 100,
        'status': 'active',
      };

      final listing = Listing.fromJson(json);

      expect(listing.suggestedPriceCny, 100.0);
    });

    test('fromJson stringifies non-string ranking metadata safely', () {
      final listing = Listing.fromJson({
        'id': 'listing-ranked',
        'title': 'Ranked item',
        'category': 'books',
        'brand': 'NCU',
        'condition_score': 8,
        'suggested_price_cny': 20,
        'status': 'active',
        'rank_reason': 42,
      });

      expect(listing.rankReason, '42');
    });

    test('conditionLabel returns correct Chinese labels', () {
      expect(
        Listing.fromJson({
          'id': '1',
          'title': 't',
          'category': 'c',
          'brand': 'b',
          'condition_score': 9,
          'suggested_price_cny': 0,
          'status': 's',
        }).conditionLabel,
        '几乎全新',
      );
      expect(
        Listing.fromJson({
          'id': '1',
          'title': 't',
          'category': 'c',
          'brand': 'b',
          'condition_score': 7,
          'suggested_price_cny': 0,
          'status': 's',
        }).conditionLabel,
        '较好',
      );
      expect(
        Listing.fromJson({
          'id': '1',
          'title': 't',
          'category': 'c',
          'brand': 'b',
          'condition_score': 5,
          'suggested_price_cny': 0,
          'status': 's',
        }).conditionLabel,
        '一般',
      );
      expect(
        Listing.fromJson({
          'id': '1',
          'title': 't',
          'category': 'c',
          'brand': 'b',
          'condition_score': 3,
          'suggested_price_cny': 0,
          'status': 's',
        }).conditionLabel,
        '较差',
      );
    });

    test('roundtrip: fromJson -> to logic -> equivalent', () {
      final original = {
        'id': 'listing-123',
        'title': 'Test Item',
        'category': 'Test Category',
        'brand': 'Test Brand',
        'condition_score': 8,
        'suggested_price_cny': 2999.50,
        'description': 'Test description',
        'status': 'active',
        'thumbnail_hint': 'test.jpg',
        'image_url': 'http://127.0.0.1:3001/test_product_images/test.jpg',
        'defects': ['None'],
        'owner_id': 'user-123',
        'owner_username': 'testuser',
        'created_at': '2024-01-15T10:00:00Z',
      };

      final listing = Listing.fromJson(original);

      expect(listing.id, original['id']);
      expect(listing.title, original['title']);
      expect(listing.category, original['category']);
      expect(listing.brand, original['brand']);
      expect(listing.conditionScore, original['condition_score']);
      expect(listing.suggestedPriceCny, original['suggested_price_cny']);
      expect(listing.description, original['description']);
      expect(listing.status, original['status']);
      expect(listing.thumbnailHint, original['thumbnail_hint']);
      expect(listing.imageUrl, original['image_url']);
      expect(listing.defects, original['defects']);
      expect(listing.ownerId, original['owner_id']);
      expect(listing.ownerUsername, original['owner_username']);
      expect(listing.createdAt, original['created_at']);
    });
  });

  group('Conversation', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'conv-123',
        'requester_id': 'user-001',
        'other_user_id': 'user-002',
        'other_username': 'alice',
        'status': 'connected',
        'last_message': 'Hello!',
        'last_message_at': '2024-01-15T10:30:00Z',
        'unread_count': 5,
        'is_receiver': false,
      };

      final conversation = Conversation.fromJson(json);

      expect(conversation.id, 'conv-123');
      expect(conversation.requesterId, 'user-001');
      expect(conversation.otherUserId, 'user-002');
      expect(conversation.otherUsername, 'alice');
      expect(conversation.status, 'active');
      expect(conversation.lastMessage, 'Hello!');
      expect(
        conversation.lastMessageAt,
        DateTime.parse('2024-01-15T10:30:00Z'),
      );
      expect(conversation.unreadCount, 0);
      expect(conversation.isReceiver, false);
    });

    test('ignores removed read preference fields', () {
      final conversation = Conversation.fromJson({
        'id': 'conv-read',
        'mode': 'realtime',
        'state': 'active',
        'initiator_id': 'user-001',
        'recipient_id': 'user-002',
        'other_user_id': 'user-002',
        'other_username': 'alice',
        'read_receipt_mode': 'manual',
        'effective_read_receipt_mode': 'manual',
      });

      expect(conversation.unreadCount, 0);
    });

    test(
      'parses sender-declared mail expectation without attention fields',
      () {
        final conversation = Conversation.fromJson({
          'id': 'conv-mail',
          'mode': 'mail',
          'state': 'open',
          'initiator_id': 'user-001',
          'recipient_id': 'user-002',
          'other_user_id': 'user-001',
          'other_username': 'alice',
          'mail_expectation': 'today',
        });

        expect(conversation.mailExpectation, MailExpectation.today);
        expect(conversation.unreadCount, 0);
      },
    );

    test(
      'parses connection privacy controls without online presence fields',
      () {
        final preferences = ConnectionPreferences.fromJson({
          'allow_strangers': false,
          'busy_until': '2026-08-11T18:00:00Z',
        });
        final permission = ContactPermission.fromJson({
          'peer_user_id': 'peer-1',
          'allow_connection': true,
          'muted_until': null,
        });

        expect(preferences.allowStrangers, isFalse);
        expect(preferences.busyUntil, DateTime.parse('2026-08-11T18:00:00Z'));
        expect(permission.peerUserId, 'peer-1');
        expect(permission.allowConnection, isTrue);
        expect(permission.mutedUntil, isNull);
      },
    );

    test('canRespond is true only for pending incoming requests', () {
      final pendingAsReceiver = Conversation(
        id: '1',
        requesterId: 'user-001',
        otherUserId: 'user-002',
        otherUsername: 'bob',
        status: 'pending',
        isReceiver: true,
      );
      expect(pendingAsReceiver.canRespond, isTrue);

      final pendingAsRequester = Conversation(
        id: '2',
        requesterId: 'user-001',
        otherUserId: 'user-002',
        otherUsername: 'bob',
        status: 'pending',
        isReceiver: false,
      );
      expect(pendingAsRequester.canRespond, isFalse);

      final connectedConversation = Conversation(
        id: '3',
        requesterId: 'user-001',
        otherUserId: 'user-002',
        otherUsername: 'bob',
        status: 'connected',
        isReceiver: true,
      );
      expect(connectedConversation.canRespond, isFalse);
    });

    test('connectionStatus returns correct type', () {
      expect(
        Conversation(
          id: '1',
          requesterId: 'a',
          otherUserId: 'b',
          otherUsername: 'x',
          status: 'pending',
        ).connectionStatus,
        ConnectionStatusType.pending,
      );
      expect(
        Conversation(
          id: '1',
          requesterId: 'a',
          otherUserId: 'b',
          otherUsername: 'x',
          status: 'connected',
        ).connectionStatus,
        ConnectionStatusType.connected,
      );
      expect(
        Conversation(
          id: '1',
          requesterId: 'a',
          otherUserId: 'b',
          otherUsername: 'x',
          status: 'established',
        ).connectionStatus,
        ConnectionStatusType.connected,
      );
      expect(
        Conversation(
          id: '1',
          requesterId: 'a',
          otherUserId: 'b',
          otherUsername: 'x',
          status: 'rejected',
        ).connectionStatus,
        ConnectionStatusType.offline,
      );
    });

    test('fromJson parses restart capability', () {
      final conversation = Conversation.fromJson({
        'id': 'conv-restart',
        'mode': 'realtime',
        'state': 'closed',
        'initiator_id': 'user-001',
        'recipient_id': 'user-002',
        'other_user_id': 'user-002',
        'other_username': 'bob',
        'capabilities': {'can_restart': true},
      });

      expect(conversation.state, ConversationState.closed);
      expect(conversation.capabilities.canRestart, isTrue);
      expect(conversation.capabilities.canSend, isFalse);
    });
  });

  group('ChatMessage', () {
    test('copyWith preserves unchanged fields', () {
      final original = ChatMessage(
        sender: 'user-1',
        content: 'Hello',
        imageBase64: 'img',
        audioBase64: 'aud',
        timestamp: DateTime.parse('2024-01-15T10:00:00Z'),
        isPartial: false,
      );

      final modified = original.copyWith(content: 'Hi there');

      expect(modified.sender, 'user-1');
      expect(modified.content, 'Hi there');
      expect(modified.imageBase64, 'img');
      expect(modified.audioBase64, 'aud');
      expect(modified.timestamp, DateTime.parse('2024-01-15T10:00:00Z'));
      expect(modified.isPartial, false);
    });

    test('toJson produces correct output', () {
      final message = ChatMessage(
        sender: 'user-1',
        content: 'Test message',
        imageBase64: 'abc',
        audioBase64: 'def',
        timestamp: DateTime.now(),
      );

      final json = message.toJson();

      expect(json['message'], 'Test message');
      expect(json['image'], 'abc');
      expect(json['audio'], 'def');
    });

    test('toJson handles null optional fields', () {
      final message = ChatMessage(
        sender: 'user-1',
        content: 'Test message',
        timestamp: DateTime.now(),
      );

      final json = message.toJson();

      expect(json['message'], 'Test message');
      expect(json['image'], isNull);
      expect(json['audio'], isNull);
    });
  });

  group('Order', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'order-123',
        'listing_id': 'listing-456',
        'listing_title': 'iPhone 14',
        'buyer_id': 'buyer-001',
        'seller_id': 'seller-002',
        'buyer_username': 'buyer_john',
        'seller_username': 'seller_jane',
        'final_price_cny': 5999.00,
        'status': 'completed',
        'created_at': '2024-01-15T10:00:00Z',
        'role': 'buyer',
      };

      final order = Order.fromJson(json);

      expect(order.id, 'order-123');
      expect(order.listingId, 'listing-456');
      expect(order.listingTitle, 'iPhone 14');
      expect(order.buyerId, 'buyer-001');
      expect(order.sellerId, 'seller-002');
      expect(order.buyerUsername, 'buyer_john');
      expect(order.sellerUsername, 'seller_jane');
      expect(order.finalPriceCny, 5999.00);
      expect(order.status, 'completed');
      expect(order.createdAt, '2024-01-15T10:00:00Z');
      expect(order.role, 'buyer');
    });

    test('statusLabel returns correct Chinese labels', () {
      final testCases = [
        ('pending', '待卖家确认'),
        ('intent_pending', '待卖家确认'),
        ('paid', '已确认成交'),
        ('shipped', '已确认成交'),
        ('completed', '已确认成交'),
        ('confirmed', '已确认成交'),
        ('cancelled', '已取消'),
        ('unknown', 'unknown'),
      ];

      for (final (status, expectedLabel) in testCases) {
        expect(
          Order.fromJson({
            'id': '1',
            'listing_id': 'l',
            'listing_title': 't',
            'buyer_id': 'b',
            'seller_id': 's',
            'buyer_username': 'bu',
            'seller_username': 'su',
            'final_price_cny': 0,
            'status': status,
            'created_at': '2024-01-15T10:00:00Z',
            'role': 'buyer',
          }).statusLabel,
          expectedLabel,
        );
      }
    });
  });

  group('HitlRequest', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'hitl-123',
        'listing_id': 'listing-456',
        'buyer_id': 'buyer-001',
        'seller_id': 'seller-002',
        'proposed_price': 5500.00,
        'reason': 'Negotiating price',
        'status': 'countered',
        'counter_price': 5700.00,
        'created_at': '2024-01-15T10:00:00Z',
        'expires_at': '2024-01-16T10:00:00Z',
      };

      final request = HitlRequest.fromJson(json);

      expect(request.id, 'hitl-123');
      expect(request.listingId, 'listing-456');
      expect(request.buyerId, 'buyer-001');
      expect(request.sellerId, 'seller-002');
      expect(request.proposedPrice, 5500.00);
      expect(request.reason, 'Negotiating price');
      expect(request.status, 'countered');
      expect(request.counterPrice, 5700.00);
      expect(request.createdAt, '2024-01-15T10:00:00Z');
      expect(request.expiresAt, '2024-01-16T10:00:00Z');
    });

    test('isPending returns correct value', () {
      expect(
        HitlRequest.fromJson({
          'id': '1',
          'listing_id': 'l',
          'buyer_id': 'b',
          'seller_id': 's',
          'proposed_price': 100,
          'reason': 'r',
          'status': 'pending',
          'created_at': '2024-01-15T10:00:00Z',
        }).isPending,
        isTrue,
      );
      expect(
        HitlRequest.fromJson({
          'id': '1',
          'listing_id': 'l',
          'buyer_id': 'b',
          'seller_id': 's',
          'proposed_price': 100,
          'reason': 'r',
          'status': 'approved',
          'created_at': '2024-01-15T10:00:00Z',
        }).isPending,
        isFalse,
      );
    });
  });

  group('ListingsResponse', () {
    test('fromJson parses items correctly', () {
      final json = {
        'items': [
          {
            'id': '1',
            'title': 'Item 1',
            'category': 'Cat',
            'brand': 'B',
            'condition_score': 5,
            'suggested_price_cny': 100,
            'status': 'a',
          },
          {
            'id': '2',
            'title': 'Item 2',
            'category': 'Cat',
            'brand': 'B',
            'condition_score': 7,
            'suggested_price_cny': 200,
            'status': 'a',
          },
        ],
        'total': 50,
        'limit': 20,
        'offset': 0,
        'ranking_version': '2026.07-wanted-feedback-v1',
      };

      final response = ListingsResponse.fromJson(json);

      expect(response.items.length, 2);
      expect(response.items[0].id, '1');
      expect(response.items[1].id, '2');
      expect(response.total, 50);
      expect(response.limit, 20);
      expect(response.offset, 0);
      expect(response.rankingVersion, '2026.07-wanted-feedback-v1');
      expect(
        response.items.first.rankingVersion,
        '2026.07-wanted-feedback-v1',
        reason: 'envelope ranking metadata follows each item into the UI',
      );
    });

    test('fromJson handles empty items', () {
      final json = {'items': [], 'total': 0, 'limit': 20, 'offset': 0};

      final response = ListingsResponse.fromJson(json);

      expect(response.items, isEmpty);
      expect(response.total, 0);
    });
  });

  group('WatchlistResponse', () {
    test('fromJson parses watchlist envelope and item fields', () {
      final json = {
        'items': [
          {
            'listing_id': 'listing-1',
            'title': 'MacBook Air',
            'category': 'electronics',
            'brand': 'Apple',
            'condition_score': 8,
            'suggested_price_cny': 5999.0,
            'status': 'active',
            'owner_id': 'owner-1',
            'created_at': '2026-03-01T08:00:00Z',
          },
        ],
        'total': 1,
        'limit': 20,
        'offset': 0,
      };

      final response = WatchlistResponse.fromJson(json);

      expect(response.total, 1);
      expect(response.limit, 20);
      expect(response.offset, 0);
      expect(response.items.length, 1);

      final item = response.items.first;
      expect(item.listingId, 'listing-1');
      expect(item.title, 'MacBook Air');
      expect(item.category, 'electronics');
      expect(item.brand, 'Apple');
      expect(item.conditionScore, 8);
      expect(item.suggestedPriceCny, 5999.0);
      expect(item.status, 'active');
      expect(item.ownerId, 'owner-1');
      expect(item.createdAt, '2026-03-01T08:00:00Z');
    });

    test('fromJson handles missing optional fields safely', () {
      final json = {
        'items': [
          {
            'listing_id': 'listing-1',
            'title': 'Item',
            'category': 'other',
            'condition_score': 6,
            'suggested_price_cny': 100.0,
            'status': 'active',
            'owner_id': 'owner-1',
            'created_at': '2026-03-01T08:00:00Z',
          },
        ],
      };

      final response = WatchlistResponse.fromJson(json);
      expect(response.items.first.brand, '');
      expect(response.total, 0);
      expect(response.limit, 20);
      expect(response.offset, 0);
    });
  });

  group('NotificationsResponse', () {
    test('fromJson parses notifications envelope and unread count', () {
      final json = {
        'items': [
          {
            'id': 'n1',
            'event_type': 'new_message',
            'title': 'New message',
            'body': 'You have a new message',
            'related_order_id': null,
            'related_listing_id': 'listing-1',
            'is_read': false,
            'created_at': '2026-03-01T09:00:00Z',
          },
        ],
        'total': 1,
        'unread_count': 1,
        'limit': 20,
        'offset': 0,
      };

      final response = NotificationsResponse.fromJson(json);

      expect(response.total, 1);
      expect(response.unreadCount, 1);
      expect(response.items.length, 1);

      final item = response.items.first;
      expect(item.id, 'n1');
      expect(item.eventType, 'new_message');
      expect(item.title, 'New message');
      expect(item.body, 'You have a new message');
      expect(item.relatedListingId, 'listing-1');
      expect(item.isRead, isFalse);
      expect(item.createdAt, '2026-03-01T09:00:00Z');
    });

    test('fromJson applies defaults for missing fields', () {
      final json = {
        'items': [
          {'id': 'n2'},
        ],
      };

      final response = NotificationsResponse.fromJson(json);
      final item = response.items.first;

      expect(item.eventType, '');
      expect(item.title, '');
      expect(item.body, '');
      expect(item.isRead, isFalse);
      expect(response.unreadCount, 0);
      expect(response.limit, 20);
      expect(response.offset, 0);
    });
  });

  group('UserIntent feed explanation', () {
    test('parses rank reason, match summary, and source', () {
      final intent = UserIntent.fromJson({
        'id': 'intent-1',
        'kind': 'goods_offer',
        'raw_input': '出一台显示器',
        'slots': {'subject': '显示器'},
        'status': 'active',
        'rank_reason': 'within_budget',
        'match_summary': ['within_budget', 'condition_match'],
        'source': 'intent_match',
      });

      expect(intent.rankReason, 'within_budget');
      expect(intent.matchSummary, ['within_budget', 'condition_match']);
      expect(intent.source, 'intent_match');
    });
  });

  group('AgentPlan confirmation protocol', () {
    test(
      'parses an armed plan so reloads preserve the second-confirmation gate',
      () {
        final plan = AgentPlan.fromJson({
          'id': 'plan-1',
          'action': 'purchase_item',
          'risk_level': 'L3',
          'summary': '购买二手教材',
          'status': 'confirmed_once',
          'confirmation_token': 'second-token',
          'expires_at': '2026-08-01T12:00:00Z',
          'result_code': null,
        });

        expect(plan.isHighRisk, isTrue);
        expect(plan.isArmed, isTrue);
        expect(plan.confirmationToken, 'second-token');
      },
    );

    test('defaults legacy plans to pending', () {
      final plan = AgentPlan.fromJson({
        'id': 'plan-legacy',
        'action': 'update_listing',
        'risk_level': 'L2',
        'summary': '更新商品',
        'confirmation_token': 'primary-token',
      });

      expect(plan.status, 'pending');
      expect(plan.isArmed, isFalse);
    });

    test('parses the rotated token returned by the primary confirmation', () {
      final outcome = AgentPlanConfirmResult.fromJson({
        'status': 'needs_second_confirmation',
        'outcome_code': 'needs_second_confirmation',
        'confirmation_token': 'rotated-second-token',
      });

      expect(outcome.needsSecondConfirmation, isTrue);
      expect(outcome.confirmationToken, 'rotated-second-token');
      expect(outcome.outcomeCode, 'needs_second_confirmation');
      expect(outcome.executed, isFalse);
    });
  });
}
