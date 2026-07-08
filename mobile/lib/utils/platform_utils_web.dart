// Implementation for web platform.

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
  final page = Uri.base;
  final host = page.host.isEmpty ? 'localhost' : page.host;
  final scheme = page.scheme == 'https' ? 'https' : 'http';
  return '$scheme://$host:3000';
}

String getWsUrl() {
  if (_configuredWsBaseUrl.isNotEmpty) {
    return _trimTrailingSlash(_configuredWsBaseUrl);
  }
  return _webSocketUrlFromApiBaseUrl(getApiBaseUrl());
}

String resolveDisplayUrl(String url) {
  final value = url.trim();
  if (value.isEmpty) return value;

  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) return value;
  if (uri.scheme != 'http' && uri.scheme != 'https') return value;

  final isLoopback = uri.host == '127.0.0.1' || uri.host == 'localhost';
  if (!isLoopback) return value;

  final page = Uri.base;
  if (!page.hasScheme || page.host.isEmpty) return value;

  // Keep the media service port intact. Replacing it with the Flutter web
  // dev-server port makes image requests return index.html instead of bytes.
  return uri.replace(scheme: page.scheme, host: page.host).toString();
}
