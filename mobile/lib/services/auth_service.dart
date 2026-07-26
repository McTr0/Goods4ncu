import 'dart:convert';
import 'base_service.dart';
import 'ws_service.dart';

/// Authentication service — handles login, register, password change, token refresh, logout.
class AuthService extends BaseService {
  /// Login with username and password.
  /// POST /api/auth/login
  Future<String> login(String username, String password) async {
    final response = await post(
      Uri.parse('$baseUrl/api/auth/login'),
      {'Content-Type': 'application/json'},
      jsonEncode({'username': username, 'password': password}),
    );

    if (response.statusCode == 200) {
      final dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        throw ServerException(response.statusCode, '登录响应解析失败');
      }
      final token = (data['token'] ?? '').toString();
      if (token.isEmpty) {
        throw Exception(data['message']?.toString() ?? '登录失败');
      }
      await setToken(token);
      final refreshToken = data['refresh_token']?.toString();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await setRefreshToken(refreshToken);
      }
      return token;
    } else {
      // Parse backend error message so the user sees "用户名或密码错误" etc.
      String msg = '登录失败 (${response.statusCode})';
      try {
        final body = jsonDecode(response.body);
        msg = body['error']?.toString() ?? body['message']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
  }

  /// Register new account.
  /// POST /api/auth/register
  Future<String> register(
    String username,
    String password, {
    String? email,
  }) async {
    final response = await post(
      Uri.parse('$baseUrl/api/auth/register'),
      {'Content-Type': 'application/json'},
      jsonEncode({
        'username': username,
        'password': password,
        if (email != null && email.isNotEmpty) 'email': email,
      }),
    );

    if (response.statusCode == 200) {
      final dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        throw ServerException(response.statusCode, '注册响应解析失败');
      }
      final token = (data['token'] ?? '').toString();
      if (token.isEmpty) {
        throw Exception(data['message']?.toString() ?? '注册失败');
      }
      await setToken(token);
      final refreshToken = data['refresh_token']?.toString();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await setRefreshToken(refreshToken);
      }
      return token;
    } else {
      String msg = '注册失败 (${response.statusCode})';
      try {
        final body = jsonDecode(response.body);
        msg = body['error']?.toString() ?? body['message']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
  }

  /// Verify the current password and replace the access token with a
  /// ten-minute recently-authenticated token for sensitive operations.
  Future<DateTime?> reauthenticate(String password, {String? totpCode}) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/auth/reauth'),
      headers,
      jsonEncode({
        'password': password,
        if (totpCode != null && totpCode.isNotEmpty) 'totp_code': totpCode,
      }),
      allowAuthRetry: false,
    );
    final data = handleResponse(
      response,
      (value) => value as Map<String, dynamic>,
    );
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw ServerException(response.statusCode, '重新认证响应不完整');
    }
    await setToken(token);
    return DateTime.tryParse(data['recent_auth_expires_at']?.toString() ?? '');
  }

  /// Change password for authenticated user.
  /// POST /api/auth/change-password
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/auth/change-password'),
      headers,
      jsonEncode({
        'current_password': currentPassword,
        'new_password': newPassword,
      }),
    );
    handleResponse(response, (_) {});
  }

  /// Refresh access token.
  /// POST /api/auth/refresh
  Future<String> refreshToken(String refreshToken) async {
    final response = await post(
      Uri.parse('$baseUrl/api/auth/refresh'),
      {'Content-Type': 'application/json'},
      jsonEncode({'refresh_token': refreshToken}),
    );

    if (response.statusCode == 200) {
      final dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        throw ServerException(response.statusCode, 'Token刷新响应解析失败');
      }
      final token = (data['token'] ?? '').toString();
      final newRefreshToken = data['refresh_token']?.toString();
      if (token.isEmpty) {
        throw Exception(data['message']?.toString() ?? 'Token刷新失败');
      }
      await setToken(token);
      if (newRefreshToken != null && newRefreshToken.isNotEmpty) {
        await setRefreshToken(newRefreshToken);
      }
      return token;
    } else {
      String msg = 'Token刷新失败 (${response.statusCode})';
      try {
        final body = jsonDecode(response.body);
        msg = body['error']?.toString() ?? body['message']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
  }

  /// Switch this device session to another verified campus.
  Future<String> switchActiveCampus(String campusId) async {
    final refreshToken = await getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw Exception('当前登录会话无法切换校园，请重新登录');
    }
    final headers = await authHeaders();
    final response = await post(
      Uri.parse('$baseUrl/api/user/active-campus'),
      headers,
      jsonEncode({'campus_id': campusId, 'refresh_token': refreshToken}),
    );
    if (response.statusCode != 200) {
      String message = '切换校园失败 (${response.statusCode})';
      try {
        final body = jsonDecode(response.body);
        message =
            body['error']?.toString() ?? body['message']?.toString() ?? message;
      } catch (_) {}
      throw Exception(message);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['token']?.toString() ?? '';
    final newRefreshToken = data['refresh_token']?.toString() ?? '';
    if (token.isEmpty || newRefreshToken.isEmpty) {
      throw Exception('切换校园响应不完整');
    }

    await WsService.instance.disconnect();
    await setToken(token);
    await setRefreshToken(newRefreshToken);
    return token;
  }

  /// Logout authenticated user.
  /// POST /api/auth/logout
  Future<void> logout() async {
    try {
      final headers = await authHeaders();
      final refreshToken = await getRefreshToken();
      final body = refreshToken == null || refreshToken.isEmpty
          ? '{}'
          : jsonEncode({'refresh_token': refreshToken});

      final response = await post(
        Uri.parse('$baseUrl/api/auth/logout'),
        headers,
        body,
      );
      handleResponse(response, (_) {});
    } finally {
      await WsService.instance.disconnect();
      await clearToken();
    }
  }
}
