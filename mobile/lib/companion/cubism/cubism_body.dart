import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_body_default.dart'
    if (dart.library.js_interop) 'cubism_body_web.dart'
    as impl;

export 'cubism_params.dart' show CubismBridge, CubismParams, gestureForTag;

/// Compile-time default companion character (multi-character catalog).
const String kCompanionCharacter = String.fromEnvironment(
  'COMPANION_CHARACTER',
  defaultValue: 'doro',
);

/// Characters with a shipped Cubism model.
const List<String> availableCompanionCharacters = ['doro'];

String _runtimeCharacter = kCompanionCharacter;

/// Character the Cubism stage should render right now. Defaults to the
/// compile-time value; [setRuntimeCompanionCharacter] overrides it when the
/// user picks a different character in settings.
String get runtimeCompanionCharacter => _runtimeCharacter;

void setRuntimeCompanionCharacter(String character) {
  if (availableCompanionCharacters.contains(character)) {
    _runtimeCharacter = character;
  }
}

/// Portrait icon asset for a character (settings previews); null if the
/// character ships no icon.
String? companionCharacterIconAsset(String character) => switch (character) {
  'doro' => 'assets/live2d/doro/icon.png',
  _ => null,
};

/// Asset url for a character's model3.json (flutter web doubles the prefix).
String cubismModelUrlFor(String character) =>
    '/assets/assets/live2d/$character/$character.model3.json';

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
  String? modelUrl,
  double width = 300,
  double height = 360,
}) {
  try {
    return impl.createCubismStage(
      fallback: fallback,
      modelUrl: modelUrl ?? cubismModelUrlFor(runtimeCompanionCharacter),
      width: width,
      height: height,
    );
  } catch (_) {
    return null;
  }
}
