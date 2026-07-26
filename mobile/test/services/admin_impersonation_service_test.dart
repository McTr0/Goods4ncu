import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/admin_impersonation_service.dart';

class _FakeGateway implements AdminImpersonationGateway {
  _FakeGateway({
    required this.calls,
    this.token = 'token-123',
    this.shouldThrow = false,
  });

  final List<String> calls;
  final String token;
  final bool shouldThrow;

  @override
  Future<String> fetchImpersonationToken(String userId) async {
    calls.add('fetch:$userId');
    if (shouldThrow) {
      throw Exception('fetch failed');
    }
    return token;
  }
}

class _FakeRealtimeController implements RealtimeConnectionController {
  _FakeRealtimeController({
    required this.calls,
    this.throwOnDisconnect = false,
    int connectFailures = 0,
  }) : _connectFailuresRemaining = connectFailures;

  final List<String> calls;
  final bool throwOnDisconnect;
  int _connectFailuresRemaining;

  @override
  Future<void> connect() async {
    calls.add('connect');
    if (_connectFailuresRemaining > 0) {
      _connectFailuresRemaining -= 1;
      throw Exception('connect failed');
    }
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    if (throwOnDisconnect) {
      throw Exception('disconnect failed');
    }
  }
}

class _FakeTokenStore implements AuthTokenStore {
  _FakeTokenStore({
    required this.calls,
    int setAccessFailures = 0,
    this.throwOnRemoveRefresh = false,
    this.throwOnSetRefresh = false,
    String? initialAccessToken = 'old-access',
    String? initialRefreshToken = 'old-refresh',
  }) : _accessToken = initialAccessToken,
       _refreshToken = initialRefreshToken,
       _setAccessFailuresRemaining = setAccessFailures;

  final List<String> calls;
  final bool throwOnRemoveRefresh;
  final bool throwOnSetRefresh;
  int _setAccessFailuresRemaining;
  String? _accessToken;
  String? _refreshToken;

  String? get currentAccessToken => _accessToken;
  String? get currentRefreshToken => _refreshToken;

  @override
  Future<void> clearTokens() async {
    calls.add('clearTokens');
    _accessToken = null;
    _refreshToken = null;
  }

  @override
  Future<String?> getAccessToken() async {
    calls.add('getAccess');
    return _accessToken;
  }

  @override
  Future<String?> getRefreshToken() async {
    calls.add('getRefresh');
    return _refreshToken;
  }

  @override
  Future<void> removeRefreshToken() async {
    calls.add('removeRefresh');
    if (throwOnRemoveRefresh) {
      throw Exception('remove refresh failed');
    }
    _refreshToken = null;
  }

  @override
  Future<void> setAccessToken(String token) async {
    calls.add('setAccess:$token');
    if (_setAccessFailuresRemaining > 0) {
      _setAccessFailuresRemaining -= 1;
      throw Exception('set access failed');
    }
    _accessToken = token;
  }

  @override
  Future<void> setRefreshToken(String token) async {
    calls.add('setRefresh:$token');
    if (throwOnSetRefresh) {
      throw Exception('set refresh failed');
    }
    _refreshToken = token;
  }
}

void main() {
  group('AdminImpersonationService', () {
    test('rejects mixed apiService and gateway injection', () {
      expect(
        () => AdminImpersonationService(
          apiService: ApiService(),
          gateway: _FakeGateway(calls: <String>[]),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects missing apiService and gateway injection', () {
      expect(() => AdminImpersonationService(), throwsA(isA<AssertionError>()));
    });

    test('runs impersonation steps in strict order', () async {
      final calls = <String>[];
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls, token: 'new-token'),
        realtime: _FakeRealtimeController(calls: calls),
        tokenStore: _FakeTokenStore(calls: calls),
      );

      await service.impersonate('user-1');

      expect(calls, [
        'fetch:user-1',
        'getAccess',
        'getRefresh',
        'disconnect',
        'setAccess:new-token',
        'removeRefresh',
        'connect',
      ]);
    });

    test('stops immediately when token fetch fails', () async {
      final calls = <String>[];
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls, shouldThrow: true),
        realtime: _FakeRealtimeController(calls: calls),
        tokenStore: _FakeTokenStore(calls: calls),
      );

      await expectLater(
        () => service.impersonate('user-2'),
        throwsA(isA<Exception>()),
      );

      expect(calls, ['fetch:user-2']);
    });

    test('does not mutate tokens when disconnect fails', () async {
      final calls = <String>[];
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls),
        realtime: _FakeRealtimeController(
          calls: calls,
          throwOnDisconnect: true,
        ),
        tokenStore: _FakeTokenStore(calls: calls),
      );

      await expectLater(
        () => service.impersonate('user-3'),
        throwsA(isA<Exception>()),
      );

      expect(calls, ['fetch:user-3', 'getAccess', 'getRefresh', 'disconnect']);
    });

    test(
      'tries reconnect when setAccessToken fails after disconnect',
      () async {
        final calls = <String>[];
        final service = AdminImpersonationService(
          gateway: _FakeGateway(calls: calls),
          realtime: _FakeRealtimeController(calls: calls),
          tokenStore: _FakeTokenStore(calls: calls, setAccessFailures: 1),
        );

        await expectLater(
          () => service.impersonate('user-4'),
          throwsA(isA<Exception>()),
        );

        expect(calls, [
          'fetch:user-4',
          'getAccess',
          'getRefresh',
          'disconnect',
          'setAccess:token-123',
          'clearTokens',
          'setAccess:old-access',
          'setRefresh:old-refresh',
          'connect',
        ]);
      },
    );

    test('tries reconnect when removeRefreshToken fails', () async {
      final calls = <String>[];
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls),
        realtime: _FakeRealtimeController(calls: calls),
        tokenStore: _FakeTokenStore(calls: calls, throwOnRemoveRefresh: true),
      );

      await expectLater(
        () => service.impersonate('user-5'),
        throwsA(isA<Exception>()),
      );

      expect(calls, [
        'fetch:user-5',
        'getAccess',
        'getRefresh',
        'disconnect',
        'setAccess:token-123',
        'removeRefresh',
        'clearTokens',
        'setAccess:old-access',
        'setRefresh:old-refresh',
        'connect',
      ]);
    });

    test('rolls back tokens when final reconnect fails', () async {
      final calls = <String>[];
      final realtime = _FakeRealtimeController(
        calls: calls,
        connectFailures: 1,
      );
      final tokenStore = _FakeTokenStore(calls: calls);
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls),
        realtime: realtime,
        tokenStore: tokenStore,
      );

      await expectLater(
        () => service.impersonate('user-6'),
        throwsA(isA<Exception>()),
      );

      expect(calls, [
        'fetch:user-6',
        'getAccess',
        'getRefresh',
        'disconnect',
        'setAccess:token-123',
        'removeRefresh',
        'connect',
        'clearTokens',
        'setAccess:old-access',
        'setRefresh:old-refresh',
        'connect',
      ]);
      expect(tokenStore.currentAccessToken, 'old-access');
      expect(tokenStore.currentRefreshToken, 'old-refresh');
    });

    test('fails closed when rollback itself fails', () async {
      final calls = <String>[];
      final realtime = _FakeRealtimeController(
        calls: calls,
        connectFailures: 1,
      );
      final tokenStore = _FakeTokenStore(calls: calls, throwOnSetRefresh: true);
      final service = AdminImpersonationService(
        gateway: _FakeGateway(calls: calls),
        realtime: realtime,
        tokenStore: tokenStore,
      );

      await expectLater(
        () => service.impersonate('user-7'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('rollback failed'),
          ),
        ),
      );

      expect(calls, [
        'fetch:user-7',
        'getAccess',
        'getRefresh',
        'disconnect',
        'setAccess:token-123',
        'removeRefresh',
        'connect',
        'clearTokens',
        'setAccess:old-access',
        'setRefresh:old-refresh',
        'clearTokens',
      ]);
      expect(tokenStore.currentAccessToken, isNull);
      expect(tokenStore.currentRefreshToken, isNull);
    });
  });
}
