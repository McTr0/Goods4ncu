// Implementation for native platforms (iOS/Android) using dart:io.
import 'dart:io';

const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
const _configuredWsBaseUrl = String.fromEnvironment('WS_BASE_URL');

String _trimTrailingSlash(String value) =>
    value.endsWith('/') ? value.substring(0, value.length - 1) : value;

String _webSocketUrlFromApiBaseUrl(String apiBaseUrl) {
  final base = _trimTrailingSlash(apiBaseUrl);
  if (base.startsWith('https://')) {
    return 'wss://${base.substring('https://'.length)}/api/ws';
  }
  if (base.startsWith('http://')) {
    return 'ws://${base.substring('http://'.length)}/api/ws';
  }
  return '$base/api/ws';
}

String getApiBaseUrl() {
  if (_configuredApiBaseUrl.isNotEmpty) {
    return _trimTrailingSlash(_configuredApiBaseUrl);
  }
  // Use localhost for iOS simulator, 10.0.2.2 for Android emulator
  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3000';
  }
  // iOS simulator and other platforms use localhost
  return 'http://localhost:3000';
}

String getWsUrl() {
  if (_configuredWsBaseUrl.isNotEmpty) {
    return _trimTrailingSlash(_configuredWsBaseUrl);
  }
  if (_configuredApiBaseUrl.isNotEmpty) {
    return _webSocketUrlFromApiBaseUrl(_configuredApiBaseUrl);
  }
  if (Platform.isAndroid) {
    return 'ws://10.0.2.2:3000/api/ws';
  }
  return 'ws://localhost:3000/api/ws';
}

String resolveDisplayUrl(String url) => url.trim();
