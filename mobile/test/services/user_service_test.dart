import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:http/http.dart' as http;

class _RecordingUserService extends UserService {
  Uri? lastUri;

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastUri = url;
    return http.Response('{"items":[],"total":0}', 200);
  }
}

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

  group('getUserListings', () {
    test('serializes pagination and optional all-status filter', () async {
      final service = _RecordingUserService();

      await service.getUserListings(limit: 100, offset: 7, status: 'all');

      expect(service.lastUri?.path, '/api/user/listings');
      expect(service.lastUri?.queryParameters, {
        'limit': '100',
        'offset': '7',
        'status': 'all',
      });
    });

    test('omits status when callers use the active-only default', () async {
      final service = _RecordingUserService();

      await service.getUserListings();

      expect(service.lastUri?.queryParameters['limit'], '20');
      expect(service.lastUri?.queryParameters['offset'], '0');
      expect(service.lastUri?.queryParameters.containsKey('status'), isFalse);
    });
  });
}
