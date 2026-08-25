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

/// Native expression names shipped in Doro.model3.json.
const List<String> kDoroExpressions = [
  'Exp1',
  'Exp2',
  'Exp3',
  'Exp4',
  'Exp5',
  'Exp6',
  'Exp7',
  'Exp8',
  'Highlight OFF',
  'Running OFF',
  'TongueOut',
];

/// Abstract over the JS stage so mapping logic is testable headless.
abstract class CubismBridge {
  void setParam(String id, double value);
  void focus(double x, double y);
  void nod();
  void shake();
  void setExpressionByName(String name);
  void resetExpression();
  void startIdleMotion();
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

  @override
  void setExpressionByName(String name) {}

  @override
  void resetExpression() {}

  @override
  void startIdleMotion() {}
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
