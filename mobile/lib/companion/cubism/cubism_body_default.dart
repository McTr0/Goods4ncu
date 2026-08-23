import 'package:flutter/widgets.dart';

import '../character_renderer.dart';

/// Whether the current platform can render the real Cubism body.
bool cubismRuntimeSupported() => false;

/// Platform-selected Cubism renderer (null ⇒ caller keeps fallback body).
CharacterRenderer? createCubismRendererOrNull() => null;

/// Never called on non-web (the OrNull wrapper guards it).
CharacterRenderer createCubismRenderer() =>
    throw UnsupportedError('Cubism body is web-only');

/// Platform-selected stage widget with graceful fallback (§74).
Widget? createCubismStage({
  required WidgetBuilder fallback,
  String? modelUrl,
  double width = 300,
  double height = 360,
}) => null;
