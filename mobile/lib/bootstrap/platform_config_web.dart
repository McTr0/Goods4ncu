import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web: clean path-based URLs (`/agent`, not `/#/agent`). Requires the
/// dev server to fall back unknown paths to index.html (scripts/serve_web.py).
void configurePlatform() => usePathUrlStrategy();
