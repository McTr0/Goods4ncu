import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/base_service.dart';
import 'package:http/http.dart' as http;

class _ProbeService extends BaseService {
  T probe<T>(http.Response response) => handleResponse(response, (d) => d as T);
}

http.Response _forbidden(String code, String message) => http.Response(
  jsonEncode({'code': code, 'message': message}),
  403,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  final service = _ProbeService();

  test('campus_verification_required maps to a dedicated exception', () {
    expect(
      () => service.probe<void>(
        _forbidden('campus_verification_required', 'need verification'),
      ),
      throwsA(isA<CampusVerificationRequiredException>()),
    );
  });

  test('dedicated exception is still caught as AuthException', () {
    expect(
      () => service.probe<void>(
        _forbidden('campus_verification_required', 'need verification'),
      ),
      throwsA(isA<AuthException>()),
    );
  });

  test('other 403 codes stay a plain AuthException', () {
    expect(
      () => service.probe<void>(_forbidden('forbidden', 'no')),
      throwsA(
        allOf(
          isA<AuthException>(),
          isNot(isA<CampusVerificationRequiredException>()),
        ),
      ),
    );
  });
}
