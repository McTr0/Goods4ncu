/// Semantic choreography tables for the Cubism body (master goal §27).
///
/// Pure Dart — unit-testable without any JS. The web bridge executes these
/// as raw Cubism parameter writes.
library;

class CubismParams {
  static const angleX = 'ParamAngleX';
  static const angleY = 'ParamAngleY';
  static const angleZ = 'ParamAngleZ';
  static const bodyY = 'ParamBodyAngleY';
  static const bodyZ = 'ParamBodyAngleZ';
  static const breath = 'ParamBreath';
  static const eyeLOpen = 'ParamEyeLOpen';
  static const eyeROpen = 'ParamEyeROpen';
  static const eyeSmile = 'ParamEyeSmile';
  static const browLY = 'ParamBrowLY';
  static const browRY = 'ParamBrowRY';
  static const mouthOpenY = 'ParamMouthOpenY';
  static const mouthForm = 'ParamMouthForm';
}

/// Abstract over the JS stage so mapping logic is testable headless.
abstract class CubismBridge {
  void setParam(String id, double value);
  void focus(double x, double y);
  void nod();
  void shake();
}

class NoopCubismBridge implements CubismBridge {
  @override
  void setParam(String id, double value) {}

  @override
  void focus(double x, double y) {}

  @override
  void nod() {}

  @override
  void shake() {}
}

/// Behavioural state → parameter choreography.
Map<String, double> paramsForState(
  String stateName, {
  required double gazeX,
  required double gazeY,
}) {
  final map = <String, double>{
    // Head follows the smoothed gaze; body leans with it (§41).
    CubismParams.angleX: gazeX * 30,
    CubismParams.angleY: -gazeY * 30,
    CubismParams.bodyZ: gazeX * 10,
  };
  switch (stateName) {
    case 'thinking':
      map[CubismParams.browLY] = -0.5;
      map[CubismParams.browRY] = -0.5;
      map[CubismParams.eyeSmile] = 0;
      map[CubismParams.mouthForm] = -0.3;
      map[CubismParams.angleZ] = 6;
      break;
    case 'happy':
      map[CubismParams.eyeSmile] = 0.7;
      map[CubismParams.mouthForm] = 0.6;
      break;
    case 'excited':
      map[CubismParams.eyeSmile] = 0.85;
      map[CubismParams.mouthForm] = 0.8;
      map[CubismParams.bodyZ] = gazeX * 14 + 4;
      break;
    case 'shy':
      map[CubismParams.browLY] = 0.35;
      map[CubismParams.browRY] = 0.35;
      map[CubismParams.eyeSmile] = 0.4;
      map[CubismParams.angleY] = -12;
      break;
    case 'surprised':
      map[CubismParams.browLY] = 0.6;
      map[CubismParams.browRY] = 0.6;
      map[CubismParams.mouthOpenY] = 0.45;
      break;
    case 'concerned':
      map[CubismParams.browLY] = 0.55;
      map[CubismParams.browRY] = 0.55;
      map[CubismParams.mouthForm] = -0.4;
      break;
    case 'sleeping':
      map[CubismParams.eyeLOpen] = 0;
      map[CubismParams.eyeROpen] = 0;
      break;
    default:
      break;
  }
  return map;
}

/// Motion tag → one-shot gesture on the bridge.
void gestureForTag(CubismBridge bridge, String tagOrClip) {
  switch (tagOrClip) {
    case 'wave':
    case 'acknowledge':
    case 'encourage':
    case 'high_five':
      bridge.nod();
    case 'poke':
      bridge.shake();
    default:
      // Procedural tags are already expressed via setGaze/setParameter.
      break;
  }
}
