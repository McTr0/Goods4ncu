import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:http/http.dart' as http;

class _RecordingUserService extends UserService {
  Uri? lastUri;
  String? lastBody;

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
    if (url.path == '/api/user/persona/assets') {
      return http.Response('{"assets":[]}', 200);
    }
    return http.Response('{"items":[],"total":0}', 200);
  }

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    lastUri = url;
    lastBody = body;
    if (url.path.endsWith('/upload-target')) {
      return http.Response(
        '{"asset_id":"asset-1","upload_key":"persona/campus/persona/asset-1","upload_url":"https://oss.example.test/put","expires_in_seconds":300}',
        200,
      );
    }
    if (url.path.endsWith('/select')) {
      return http.Response(
        '{"persona":{"representation_mode":"role_character","style_version":"v1","appearance_config":{},"self_descriptions":[],"contact_posture":"leave_message","status":"draft"}}',
        200,
      );
    }
    return http.Response(
      '{"asset":{"id":"asset-1","asset_type":"illustration","declared_mime_type":"image/png","declared_size_bytes":1024,"moderation_status":"not_required","status":"pending_upload"}}',
      200,
    );
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

  group('persona assets', () {
    test('lists private candidates without inventing public URLs', () async {
      final service = _RecordingUserService();

      final assets = await service.getSocialPersonaAssets();

      expect(assets, isEmpty);
      expect(service.lastUri?.path, '/api/user/persona/assets');
    });

    test('uses server-keyed create/complete/select/revoke routes', () async {
      final service = _RecordingUserService();

      final created = await service.createSocialPersonaAsset(
        assetType: 'illustration',
        declaredMimeType: 'image/png',
        declaredSizeBytes: 1024,
      );
      expect(created.id, 'asset-1');
      expect(service.lastUri?.path, '/api/user/persona/assets');
      expect(service.lastBody, contains('"declared_size_bytes":1024'));

      final target = await service.getSocialPersonaAssetUploadTarget(created.id);
      expect(target.assetId, created.id);
      expect(target.uploadKey, 'persona/campus/persona/asset-1');
      expect(target.uploadUrl, 'https://oss.example.test/put');
      expect(target.expiresInSeconds, 300);
      expect(
        service.lastUri?.path,
        '/api/user/persona/assets/asset-1/upload-target',
      );

      await service.completeSocialPersonaAsset('asset/1');
      expect(
        service.lastUri?.path,
        '/api/user/persona/assets/asset%2F1/complete',
      );
      await service.selectSocialPersonaAsset('asset/1');
      expect(
        service.lastUri?.path,
        '/api/user/persona/assets/asset%2F1/select',
      );
      await service.revokeSocialPersonaAsset('asset/1');
      expect(
        service.lastUri?.path,
        '/api/user/persona/assets/asset%2F1/revoke',
      );
    });
  });
}
