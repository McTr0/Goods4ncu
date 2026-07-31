import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../utils/platform_utils.dart';
import 'admin_role_cache.dart';
import 'token_storage.dart';
import 'ws_service.dart';

/// Thrown when API returns 401 Unauthorized
class AuthException implements Exception {
  final String message;
  AuthException([this.message = 'Session expired. Please login again.']);
  @override
  String toString() => message;
}

/// Thrown when a sensitive operation needs a fresh password verification.
class RecentAuthenticationException implements Exception {
  final String message;
  final bool verificationFailed;

  /// The account has a confirmed MFA factor: the step-up additionally needs a
  /// one-time code from the authenticator app.
  final bool mfaRequired;

  RecentAuthenticationException(
    this.message, {
    this.verificationFailed = false,
    this.mfaRequired = false,
  });

  @override
  String toString() => message;
}

/// Thrown when API returns 409 Conflict
class ConflictException implements Exception {
  final String message;
  final String? serverCode;

  ConflictException([this.message = 'Resource conflict.', this.serverCode]);

  @override
  String toString() => message;
}

/// 网络不可达 / 超时
class NetworkException implements Exception {
  final String message;
  NetworkException([this.message = '网络连接失败，请检查网络设置']);
  @override
  String toString() => message;
}

/// 服务器错误（5xx）
class ServerException implements Exception {
  final String message;
  final int statusCode;
  ServerException(this.statusCode, [this.message = '服务器异常，请稍后再试']);
  @override
  String toString() => message;
}

/// Base class for all services — holds shared HTTP client and auth logic.
///
/// Subclasses can call the protected HTTP methods (get, post, put, patch, delete,
/// authHeaders, handleResponse, clearAuthAndRedirect).
class BaseService {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final http.Client _sharedClient = http.Client();
  static Future<bool>? _refreshInFlight;

  String get baseUrl => getApiBaseUrl();

  http.Client get _client => _sharedClient;
  final TokenStorage _tokenStorage = TokenStorage.instance;

  @protected
  Future<Map<String, String>> authHeaders() async {
    final token = await _tokenStorage.getAccessToken();
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  @protected
  T handleResponse<T>(http.Response response, T Function(dynamic) parse) {
    if (response.statusCode == 200) {
      try {
        return parse(jsonDecode(response.body));
      } catch (e) {
        throw ServerException(response.statusCode, '服务器返回数据格式错误');
      }
    }

    // --- Non-200: extract backend error message ---
    String serverMsg = '';
    String serverCode = '';
    try {
      final body = jsonDecode(response.body);
      serverMsg = (body['error'] ?? body['message'])?.toString() ?? '';
      serverCode = body['code']?.toString() ?? '';
    } catch (_) {}

    if (serverCode == 'recent_authentication_required' ||
        serverCode == 'recent_authentication_failed' ||
        serverCode == 'mfa_required') {
      // Intercepted before the generic 401 branch: an MFA prompt must not be
      // treated as an expired login and wipe the session.
      throw RecentAuthenticationException(
        serverMsg.isNotEmpty ? serverMsg : '请重新验证密码',
        verificationFailed: serverCode == 'recent_authentication_failed',
        mfaRequired: serverCode == 'mfa_required',
      );
    }

    if (response.statusCode == 401) {
      _clearAuthAndRedirect();
      throw AuthException(serverMsg.isNotEmpty ? serverMsg : '登录已过期，请重新登录');
    }
    if (response.statusCode == 403) {
      throw AuthException(serverMsg.isNotEmpty ? serverMsg : '您没有权限执行此操作');
    }
    if (response.statusCode == 409) {
      throw ConflictException(
        serverMsg.isNotEmpty ? serverMsg : '资源冲突',
        serverCode.isEmpty ? null : serverCode,
      );
    }
    if (response.statusCode >= 500) {
      throw ServerException(
        response.statusCode,
        serverMsg.isNotEmpty ? serverMsg : '服务器异常，请稍后再试',
      );
    }
    throw NetworkException(
      serverMsg.isNotEmpty ? serverMsg : '请求失败 (${response.statusCode})',
    );
  }

  Future<void> _clearAuthAndRedirect() async {
    AdminRoleCache.instance.invalidate();
    await _tokenStorage.clearTokens();
    await WsService.instance.disconnect();
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) {
      GoRouter.of(context).go('/login');
    }
  }

  bool _canAttemptRefresh(Uri url, Map<String, String> headers) {
    if (!headers.containsKey('Authorization')) {
      return false;
    }

    final path = url.path;
    return path != '/api/auth/refresh' &&
        path != '/api/auth/login' &&
        path != '/api/auth/register';
  }

  Future<bool> _refreshAccessTokenSingleFlight() async {
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }

    final future = _performRefresh();
    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    }
  }

  /// Shared token refresh entrypoint for services that need single-flight refresh
  /// semantics without subclassing BaseService request helpers.
  Future<bool> refreshAccessTokenIfNeeded() {
    return _refreshAccessTokenSingleFlight();
  }

  Future<bool> _performRefresh() async {
    final refreshToken = await _tokenStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }

    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/auth/refresh'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (response.statusCode != 200) {
      return false;
    }

    final dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      return false;
    }

    final token = (data['token'] ?? '').toString();
    if (token.isEmpty) {
      return false;
    }
    await _tokenStorage.setAccessToken(token);
    AdminRoleCache.instance.invalidate();

    final nextRefreshToken = data['refresh_token']?.toString();
    if (nextRefreshToken != null && nextRefreshToken.isNotEmpty) {
      await _tokenStorage.setRefreshToken(nextRefreshToken);
    }

    return true;
  }

  Future<Map<String, String>> _headersAfterRefresh(
    Map<String, String> original,
  ) async {
    final token = await _tokenStorage.getAccessToken();
    final updated = Map<String, String>.from(original);
    if (token != null && token.isNotEmpty) {
      updated['Authorization'] = 'Bearer $token';
    }
    return updated;
  }

  @protected
  Future<http.Response> get(Uri url, Map<String, String> headers) async {
    final response = await _client
        .get(url, headers: headers)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (response.statusCode == 401 && _canAttemptRefresh(url, headers)) {
      final refreshed = await _refreshAccessTokenSingleFlight();
      if (refreshed) {
        final retryHeaders = await _headersAfterRefresh(headers);
        return _client
            .get(url, headers: retryHeaders)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
            );
      }
    }

    return response;
  }

  @protected
  Future<http.Response> post(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    final response = await _client
        .post(url, headers: headers, body: body)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (allowAuthRetry &&
        response.statusCode == 401 &&
        _canAttemptRefresh(url, headers)) {
      final refreshed = await _refreshAccessTokenSingleFlight();
      if (refreshed) {
        final retryHeaders = await _headersAfterRefresh(headers);
        return _client
            .post(url, headers: retryHeaders, body: body)
            .timeout(
              const Duration(seconds: 30),
              onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
            );
      }
    }

    return response;
  }

  @protected
  Future<http.Response> put(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    final response = await _client
        .put(url, headers: headers, body: body)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (allowAuthRetry &&
        response.statusCode == 401 &&
        _canAttemptRefresh(url, headers)) {
      final refreshed = await _refreshAccessTokenSingleFlight();
      if (refreshed) {
        final retryHeaders = await _headersAfterRefresh(headers);
        return _client
            .put(url, headers: retryHeaders, body: body)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
            );
      }
    }

    return response;
  }

  @protected
  Future<http.Response> patch(
    Uri url,
    Map<String, String> headers,
    String body, {
    bool allowAuthRetry = true,
  }) async {
    final response = await _client
        .patch(url, headers: headers, body: body)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (allowAuthRetry &&
        response.statusCode == 401 &&
        _canAttemptRefresh(url, headers)) {
      final refreshed = await _refreshAccessTokenSingleFlight();
      if (refreshed) {
        final retryHeaders = await _headersAfterRefresh(headers);
        return _client
            .patch(url, headers: retryHeaders, body: body)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
            );
      }
    }

    return response;
  }

  @protected
  Future<http.Response> delete(
    Uri url,
    Map<String, String> headers, {
    bool allowAuthRetry = true,
  }) async {
    final response = await _client
        .delete(url, headers: headers)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
        );

    if (allowAuthRetry &&
        response.statusCode == 401 &&
        _canAttemptRefresh(url, headers)) {
      final refreshed = await _refreshAccessTokenSingleFlight();
      if (refreshed) {
        final retryHeaders = await _headersAfterRefresh(headers);
        return _client
            .delete(url, headers: retryHeaders)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw NetworkException('请求超时，请稍后重试'),
            );
      }
    }

    return response;
  }

  // Token storage helpers (used by AuthService and ApiService)
  Future<String?> getToken() async {
    return _tokenStorage.getAccessToken();
  }

  Future<void> setToken(String token) async {
    await _tokenStorage.setAccessToken(token);
  }

  Future<String?> getRefreshToken() async {
    return _tokenStorage.getRefreshToken();
  }

  Future<void> setRefreshToken(String token) async {
    await _tokenStorage.setRefreshToken(token);
  }

  Future<void> clearRefreshToken() async {
    await _tokenStorage.removeRefreshToken();
  }

  Future<void> clearToken() async {
    await _tokenStorage.clearTokens();
  }
}
