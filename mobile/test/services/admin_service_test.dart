import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/admin_service.dart';
import 'package:http/http.dart' as http;

class _FakeAdminService extends AdminService {
  Uri? lastUri;
  String? lastBody;
  String? lastMethod;
  http.Response response = http.Response('{}', 200);

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    lastMethod = 'POST';
    lastUri = url;
    lastBody = body;
    return response;
  }
}

void main() {
  test(
    'listing enforcement uses dedicated takedown and restore endpoints',
    () async {
      final service = _FakeAdminService();

      await service.takedownListing('listing-1');
      expect(service.lastMethod, 'POST');
      expect(service.lastUri?.path, '/api/admin/listings/listing-1/takedown');
      expect(service.lastBody, '{}');

      await service.restoreListing('listing-1', reason: ' appeal approved ');
      expect(service.lastMethod, 'POST');
      expect(service.lastUri?.path, '/api/admin/listings/listing-1/restore');
      expect(service.lastUri?.queryParameters, {'reason': 'appeal approved'});
      expect(service.lastBody, '{}');
    },
  );
}
