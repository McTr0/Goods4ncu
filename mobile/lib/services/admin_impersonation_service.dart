import 'admin_service.dart';
import 'admin_role_cache.dart';
import 'token_storage.dart';
import 'ws_service.dart';

abstract class AdminImpersonationGateway {
  Future<String> fetchImpersonationToken(String userId);
}

class ApiAdminImpersonationGateway implements AdminImpersonationGateway {
  ApiAdminImpersonationGateway(this._adminService);

  final AdminService _adminService;

  @override
  Future<String> fetchImpersonationToken(String userId) {
    return _adminService.impersonateUserToken(userId);
  }
}

abstract class RealtimeConnectionController {
  Future<void> disconnect();

  Future<void> connect();
}

class WsRealtimeConnectionController implements RealtimeConnectionController {
  @override
  Future<void> connect() {
    return WsService.instance.connect();
  }

  @override
  Future<void> disconnect() {
    return WsService.instance.disconnect();
  }
}

abstract class AuthTokenStore {
  Future<String?> getAccessToken();

  Future<String?> getRefreshToken();

  Future<void> setAccessToken(String token);

  Future<void> setRefreshToken(String token);

  Future<void> clearTokens();

  Future<void> removeRefreshToken();
}

class SecureAuthTokenStore implements AuthTokenStore {
  @override
  Future<void> clearTokens() {
    return TokenStorage.instance.clearTokens();
  }

  @override
  Future<String?> getAccessToken() {
    return TokenStorage.instance.getAccessToken();
  }

  @override
  Future<String?> getRefreshToken() {
    return TokenStorage.instance.getRefreshToken();
  }

  @override
  Future<void> removeRefreshToken() {
    return TokenStorage.instance.removeRefreshToken();
  }

  @override
  Future<void> setAccessToken(String token) {
    return TokenStorage.instance.setAccessToken(token);
  }

  @override
  Future<void> setRefreshToken(String token) {
    return TokenStorage.instance.setRefreshToken(token);
  }
}

class AdminImpersonationService {
  AdminImpersonationService({
    AdminService? adminService,
    AdminImpersonationGateway? gateway,
    RealtimeConnectionController? realtime,
    AuthTokenStore? tokenStore,
  }) : assert(
         adminService == null || gateway == null,
         'Provide adminService or gateway, not both.',
       ),
       assert(
         adminService != null || gateway != null,
         'Provide adminService or gateway.',
       ),
       _gateway = gateway ?? ApiAdminImpersonationGateway(adminService!),
       _realtime = realtime ?? WsRealtimeConnectionController(),
       _tokenStore = tokenStore ?? SecureAuthTokenStore();

  final AdminImpersonationGateway _gateway;
  final RealtimeConnectionController _realtime;
  final AuthTokenStore _tokenStore;

  Future<void> impersonate(String userId) async {
    final token = await _gateway.fetchImpersonationToken(userId);
    final previousAccessToken = await _tokenStore.getAccessToken();
    final previousRefreshToken = await _tokenStore.getRefreshToken();
    await _realtime.disconnect();

    try {
      await _tokenStore.setAccessToken(token);
      AdminRoleCache.instance.invalidate();
      await _tokenStore.removeRefreshToken();
      await _realtime.connect();
    } catch (originalError, originalStackTrace) {
      try {
        await _tokenStore.clearTokens();
        if (previousAccessToken != null && previousAccessToken.isNotEmpty) {
          await _tokenStore.setAccessToken(previousAccessToken);
        }
        if (previousRefreshToken != null && previousRefreshToken.isNotEmpty) {
          await _tokenStore.setRefreshToken(previousRefreshToken);
        }
        await _realtime.connect();
      } catch (rollbackError) {
        try {
          await _tokenStore.clearTokens();
        } catch (_) {
          // Best-effort fail-closed.
        }
        throw Exception(
          'impersonation failed and rollback failed: $rollbackError',
        );
      }
      Error.throwWithStackTrace(originalError, originalStackTrace);
    }
  }
}
