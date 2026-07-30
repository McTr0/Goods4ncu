import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:http/http.dart' as http;

class _FakeListingService extends ListingService {
  http.Response response = http.Response('{}', 200);
  Uri? lastUri;
  String? lastBody;
  String? lastMethod;

  @override
  String get baseUrl => 'https://api.test';

  @override
  Future<Map<String, String>> authHeaders() async => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer test-token',
  };

  @override
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    lastMethod = 'GET';
    lastUri = url;
    return response;
  }

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
    'wanted response list sends every supported filter and parses envelope',
    () async {
      final service = _FakeListingService()
        ..response = http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'response-1',
                'wanted_listing_id': 'wanted-1',
                'wanted_title': '想收教材',
                'wanted_status': 'active',
                'offer_listing_id': 'offer-1',
                'offer_title': '高数教材',
                'offer_status': 'active',
                'status': 'pending',
              },
            ],
            'total': 6,
            'limit': 5,
            'offset': 5,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

      final result = await service.getWantedResponses(
        role: 'requester',
        wantedListingId: ' wanted-1 ',
        status: 'pending',
        limit: 5,
        offset: 5,
      );

      expect(service.lastMethod, 'GET');
      expect(service.lastUri?.path, '/api/wanted-responses');
      expect(service.lastUri?.queryParameters, {
        'role': 'requester',
        'limit': '5',
        'offset': '5',
        'wanted_listing_id': 'wanted-1',
        'status': 'pending',
      });
      expect(result.items.single.offerTitle, '高数教材');
      expect(result.total, 6);
      expect(result.limit, 5);
      expect(result.offset, 5);
    },
  );

  test(
    'wanted response actions use stable endpoints and parse result',
    () async {
      final service = _FakeListingService()
        ..response = http.Response(
          jsonEncode({'id': 'response-1', 'status': 'accepted'}),
          200,
        );

      final accepted = await service.acceptWantedResponse('response-1');
      expect(service.lastUri?.path, '/api/wanted-responses/response-1/accept');
      expect(service.lastBody, '{}');
      expect(accepted.status, 'accepted');

      service.response = http.Response(
        jsonEncode({'id': 'response-1', 'status': 'dismissed'}),
        200,
      );
      final dismissed = await service.dismissWantedResponse('response-1');
      expect(service.lastUri?.path, '/api/wanted-responses/response-1/dismiss');
      expect(dismissed.status, 'dismissed');

      service.response = http.Response(
        jsonEncode({'id': 'response-1', 'status': 'withdrawn'}),
        200,
      );
      final withdrawn = await service.withdrawWantedResponse('response-1');
      expect(
        service.lastUri?.path,
        '/api/wanted-responses/response-1/withdraw',
      );
      expect(withdrawn.status, 'withdrawn');
    },
  );
}
