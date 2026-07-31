import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/models.dart';

void main() {
  group('WantedResponse', () {
    test('parses the flat API representation and lifecycle state', () {
      final response = WantedResponse.fromJson({
        'id': 'response-1',
        'wanted_listing_id': 'wanted-1',
        'wanted_title': '想收高数教材',
        'wanted_status': 'active',
        'offer_listing_id': 'offer-1',
        'offer_title': '高数教材第七版',
        'offer_status': 'active',
        'responder_id': 'seller-1',
        'requester_id': 'buyer-1',
        'message': '上下册都在，可以看看',
        'status': 'accepted',
        'created_at': '2026-07-30T10:00:00Z',
        'responded_at': '2026-07-30T10:05:00Z',
        'lifecycle_epoch': '3',
        'current_lifecycle_epoch': 3,
        'round_state': 'current',
        'available_actions': <String>[],
      });

      expect(response.id, 'response-1');
      expect(response.wantedListingId, 'wanted-1');
      expect(response.wantedTitle, '想收高数教材');
      expect(response.wantedStatus, 'active');
      expect(response.offerListingId, 'offer-1');
      expect(response.offerTitle, '高数教材第七版');
      expect(response.offerStatus, 'active');
      expect(response.responderId, 'seller-1');
      expect(response.requesterId, 'buyer-1');
      expect(response.message, '上下册都在，可以看看');
      expect(response.createdAt, DateTime.parse('2026-07-30T10:00:00Z'));
      expect(response.respondedAt, DateTime.parse('2026-07-30T10:05:00Z'));
      expect(response.isAccepted, isTrue);
      expect(response.isPending, isFalse);
      expect(response.lifecycleEpoch, 3);
      expect(response.currentLifecycleEpoch, 3);
      expect(response.roundState, 'current');
      expect(response.availableActions, isEmpty);
      expect(response.isClosedRound, isFalse);
    });

    test(
      'accepts nested listing context and safely defaults malformed fields',
      () {
        final response = WantedResponse.fromJson({
          'id': 42,
          'wanted_listing': {
            'id': 'wanted-nested',
            'title': '想收计算器',
            'status': 'fulfilled',
          },
          'offer_listing': {
            'id': 'offer-nested',
            'title': '卡西欧计算器',
            'status': 'sold',
          },
          'message': '   ',
          'created_at': 'not-a-date',
        });

        expect(response.id, '42');
        expect(response.wantedListingId, 'wanted-nested');
        expect(response.wantedStatus, 'fulfilled');
        expect(response.offerListingId, 'offer-nested');
        expect(response.offerStatus, 'sold');
        expect(response.message, isNull);
        expect(response.status, 'pending');
        expect(response.isPending, isTrue);
        expect(response.createdAt, isNull);
        expect(response.respondedAt, isNull);
        expect(response.lifecycleEpoch, isNull);
        expect(response.currentLifecycleEpoch, isNull);
        expect(response.availableActions, isNull);
        expect(response.isClosedRound, isTrue);
        expect(response.canAccept, isFalse);
        expect(response.canDismiss, isFalse);
        expect(response.canWithdraw, isFalse);
      },
    );

    test('server actions take priority and closed rounds are read-only', () {
      final current = WantedResponse.fromJson({
        'id': 'response-current',
        'wanted_listing_id': 'wanted-1',
        'offer_listing_id': 'offer-1',
        'status': 'pending',
        'lifecycle_epoch': 4,
        'current_lifecycle_epoch': '4',
        'round_state': 'CURRENT',
        'available_actions': ['dismiss', ' dismiss ', 'unknown'],
      });

      expect(current.isClosedRound, isFalse);
      expect(current.canAccept, isFalse);
      expect(current.canDismiss, isTrue);
      expect(current.canWithdraw, isFalse);
      expect(current.availableActions, {'dismiss', 'unknown'});

      final explicitCurrent = WantedResponse.fromJson({
        'id': 'response-current-state-wins',
        'wanted_listing_id': 'wanted-1',
        'offer_listing_id': 'offer-1',
        'status': 'pending',
        'lifecycle_epoch': 1,
        'current_lifecycle_epoch': 2,
        'round_state': 'current',
        'available_actions': <String>[],
      });
      expect(explicitCurrent.isClosedRound, isTrue);
      expect(explicitCurrent.canAccept, isFalse);

      final closed = WantedResponse.fromJson({
        'id': 'response-closed',
        'wanted_listing_id': 'wanted-1',
        'offer_listing_id': 'offer-1',
        'status': 'pending',
        'lifecycle_epoch': 3,
        'current_lifecycle_epoch': 4,
        'available_actions': ['accept', 'dismiss', 'withdraw'],
      });

      expect(closed.isClosedRound, isTrue);
      expect(closed.canAccept, isFalse);
      expect(closed.canDismiss, isFalse);
      expect(closed.canWithdraw, isFalse);

      final copied = closed.copyWith(status: 'accepted');
      expect(copied.lifecycleEpoch, 3);
      expect(copied.currentLifecycleEpoch, 4);
      expect(copied.availableActions, closed.availableActions);
      expect(copied.isClosedRound, isTrue);
    });

    test('present malformed action metadata fails closed', () {
      for (final malformed in <dynamic>[null, 'accept', 42, const {}]) {
        final response = WantedResponse.fromJson({
          'id': 'response-malformed',
          'wanted_listing_id': 'wanted-1',
          'offer_listing_id': 'offer-1',
          'status': 'pending',
          'available_actions': malformed,
        });

        expect(response.availableActions, isEmpty);
        expect(response.canAccept, isFalse);
        expect(response.canDismiss, isFalse);
        expect(response.canWithdraw, isFalse);
      }
    });
  });

  group('WantedResponsesResponse', () {
    test('parses pagination strings and ignores non-object rows', () {
      final envelope = WantedResponsesResponse.fromJson({
        'items': [
          {
            'id': 'response-1',
            'wanted_listing_id': 'wanted-1',
            'offer_listing_id': 'offer-1',
            'status': 'withdrawn',
          },
          'bad-row',
        ],
        'total': '27',
        'limit': '10',
        'offset': '20',
      });

      expect(envelope.items, hasLength(1));
      expect(envelope.items.single.isWithdrawn, isTrue);
      expect(envelope.total, 27);
      expect(envelope.limit, 10);
      expect(envelope.offset, 20);
    });

    test('supports the legacy items-only envelope', () {
      final envelope = WantedResponsesResponse.fromJson({
        'items': [
          {
            'id': 'response-1',
            'wanted_listing_id': 'wanted-1',
            'offer_listing_id': 'offer-1',
          },
        ],
      });

      expect(envelope.total, 1);
      expect(envelope.limit, 20);
      expect(envelope.offset, 0);
    });
  });

  test('action result and role wire values are stable', () {
    final result = WantedResponseActionResult.fromJson({
      'id': 'response-1',
      'status': 'dismissed',
    });

    expect(result.id, 'response-1');
    expect(result.status, 'dismissed');
    expect(WantedResponseRole.requester.wireValue, 'requester');
    expect(WantedResponseRole.responder.wireValue, 'responder');
  });
}
