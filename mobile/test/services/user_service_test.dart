import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

void main() {
  group('UserLookupMatch', () {
    test('fromJson parses privacy-aware lookup result', () {
      final match = UserLookupMatch.fromJson({
        'user_id': 'user-123',
        'username': 'alice',
        'matched_by': 'student_id',
        'masked_identifier': '2024****',
        'listing_count': 3,
        'can_start_conversation': true,
      });

      expect(match.userId, 'user-123');
      expect(match.username, 'alice');
      expect(match.matchedBy, 'student_id');
      expect(match.maskedIdentifier, '2024****');
      expect(match.listingCount, 3);
      expect(match.canStartConversation, isTrue);
    });
  });
}
