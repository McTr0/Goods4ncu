import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_body_default.dart'
    if (dart.library.js_interop) 'cubism_body_web.dart'
    as impl;

export 'cubism_params.dart'
    show CubismBridge, CubismParams, gestureForTag, paramsForState;

/// Whether the current platform can render the real Cubism body.
bool get cubismAvailable {
  try {
    return impl.createCubismRenderer() != null;
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

/// Platform-selected stage widget (null ⇒ caller hides the slot).
Widget? createCubismStage({double width = 300, double height = 360}) =>
    impl.createCubismStage(width: width, height: height);
