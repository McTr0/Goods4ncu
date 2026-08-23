import '../components/live2d/live2d_controller.dart';
import 'character_renderer.dart';
import 'state_machine.dart';

/// Maps companion semantic states onto the body's overlay expressions.
const Map<CompanionState, Live2DExpression> _stateExpressions = {
  CompanionState.thinking: Live2DExpression.thinking,
  CompanionState.happy: Live2DExpression.happy,
  CompanionState.excited: Live2DExpression.happy,
  CompanionState.shy: Live2DExpression.shy,
  CompanionState.surprised: Live2DExpression.surprised,
  CompanionState.error: Live2DExpression.thinking,
  CompanionState.sleeping: Live2DExpression.idle,
};

/// `CharacterRenderer` implementation over the legacy sprite body
/// (`Live2DController` + `Live2DCharacterWidget`).
///
/// Semantic commands in, controller calls out. The scheduler's clip steps
/// arrive through [playMotionClip]; procedural gaze/tilt land on the
/// controller/tilt field; micro-motion (blink/sway) keeps running in the
/// controller underneath everything.
class FallbackBodyRenderer implements CharacterRenderer {
  FallbackBodyRenderer(this.controller);

  final Live2DController controller;

  /// Persistent head tilt in degrees, applied by the widget as a rotation
  /// offset. Procedural tilt steps write here between clip playbacks.
  double headTilt = 0;

  @override
  Future<void> load() async {
    // The widget owns asset loading; nothing to prime here.
  }

  @override
  void setCharacterState(CompanionState state) {
    final expression = _stateExpressions[state];
    if (expression != null) setExpression(expression.name);
  }

  @override
  void setExpression(String expression, {double weight = 1}) {
    final match = Live2DExpression.values.where((e) => e.name == expression);
    if (match.isEmpty) return;
    controller.setExpression(match.first);
  }

  @override
  Future<void> playMotion(
    String motionTag, {
    int priority = 60,
    Duration? holdFor,
  }) async {
    controller.playMotion(motionTag);
  }

  /// Clip step entry point used by the animation scheduler.
  void playMotionClip(String clip) => controller.playMotion(clip);

  @override
  void setGaze(double x, double y) {
    controller.lookAt(x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0));
  }

  @override
  void setMouthOpen(double value) {
    controller.setMouthOpen(value);
  }

  @override
  void setParameter(String name, double value) {
    if (name == 'headTilt') headTilt = value;
  }

  @override
  void stopMotion({int? priority}) {
    controller.stopTalking();
  }
}
