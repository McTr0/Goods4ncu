// Stub implementation for unsupported platforms.
// This file is used as fallback when neither dart:io nor dart:html is available.
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

String getApiBaseUrl() => _configuredApiBaseUrl.isNotEmpty
    ? _trimTrailingSlash(_configuredApiBaseUrl)
    : 'http://localhost:3000';

String getWsUrl() => _configuredWsBaseUrl.isNotEmpty
    ? _trimTrailingSlash(_configuredWsBaseUrl)
    : _webSocketUrlFromApiBaseUrl(getApiBaseUrl());

String resolveDisplayUrl(String url) => url.trim();
