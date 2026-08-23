import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_body_default.dart'
    if (dart.library.js_interop) 'cubism_body_web.dart'
    as impl;

export 'cubism_params.dart'
    show CubismBridge, CubismParams, gestureForTag, paramsForState;

/// Whether the Cubism4 runtime is actually usable on this platform
/// (scripts loaded AND runtime libs present). Degrades to false on any error.
bool cubismRuntimeSupported() {
  try {
    return impl.cubismRuntimeSupported();
  } catch (_) {
    return false;
  }
}

/// Platform-selected Cubism renderer (null ⇒ caller keeps fallback body).
CharacterRenderer? createCubismRendererOrNull() {
  try {
    return impl.createCubismRenderer();
  } catch (_) {
    return null;
  }
}

/// Platform-selected stage widget with graceful fallback.
Widget? createCubismStage({
  required WidgetBuilder fallback,
  double width = 300,
  double height = 360,
}) {
  try {
    return impl.createCubismStage(
      fallback: fallback,
      width: width,
      height: height,
    );
  } catch (_) {
    return null;
  }
}
