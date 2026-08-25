import '../character_renderer.dart';
import '../state_machine.dart';
import 'cubism_params.dart';

export 'cubism_params.dart' show CubismParams;

/// `CharacterRenderer` over the real Cubism model (web, pixi-live2d-display).
///
/// Every director output lands on the model as raw parameter writes: head/
/// body follow the smoothed gaze, behavioural states pick expression
/// choreography, mouth opening comes from the shared lip-sync pipeline.
class CubismCharacterRenderer implements CharacterRenderer {
  CubismCharacterRenderer({required this.bridge});

  final CubismBridge bridge;

  double gazeX = 0;
  double gazeY = 0;
  CompanionState? characterState;

  @override
  Future<void> load() async {}

  @override
  void setCharacterState(CompanionState state) {
    // Facial states are native Doro expressions now; the director's state
    // machine only tracks it for logging/attention purposes.
    characterState = state;
  }

  @override
  void setExpression(String expression, {double weight = 1}) {
    kDoroExpressions.contains(expression)
        ? bridge.setExpressionByName(expression)
        : bridge.resetExpression();
  }

  @override
  Future<void> playMotion(
    String motionTag, {
    int priority = 60,
    Duration? holdFor,
  }) async {
    gestureForTag(bridge, motionTag);
  }

  @override
  void setGaze(double x, double y) {
    gazeX = x.clamp(-1.0, 1.0);
    gazeY = y.clamp(-1.0, 1.0);
    bridge.focus(gazeX, gazeY);
  }

  @override
  void setMouthOpen(double value) =>
      bridge.setParam(CubismParams.mouthOpenY, value.clamp(0.0, 1.0));

  @override
  void setParameter(String name, double value) => bridge.setParam(name, value);

  @override
  void stopMotion({int? priority}) {}
}
