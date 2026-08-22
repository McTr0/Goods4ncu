import 'character_renderer.dart';
import 'state_machine.dart';

/// A `CharacterRenderer` that draws nothing and remembers everything.
///
/// Two jobs per the master goal (§72):
///  1. Let the entire runtime be developed and tested with zero model assets.
///  2. Serve as the data source for the mock HUD (state/emotion/gaze/mouth).
class MockCharacterRenderer implements CharacterRenderer {
  final List<(String, int)> motionLog = [];
  final List<String> expressionLog = [];

  String? lastMotionTag;
  int? lastMotionPriority;
  String? lastExpression;
  double gazeX = 0;
  double gazeY = 0;
  double mouthOpen = 0;
  CompanionState? characterState;
  bool loaded = false;

  @override
  Future<void> load() async {
    loaded = true;
  }

  @override
  void setCharacterState(CompanionState state) {
    characterState = state;
  }

  @override
  void setExpression(String expression, {double weight = 1}) {
    expressionLog.add(expression);
    lastExpression = expression;
  }

  @override
  Future<void> playMotion(
    String motionTag, {
    int priority = 60,
    Duration? holdFor,
  }) async {
    motionLog.add((motionTag, priority));
    lastMotionTag = motionTag;
    lastMotionPriority = priority;
  }

  @override
  void setGaze(double x, double y) {
    gazeX = x;
    gazeY = y;
  }

  @override
  void setMouthOpen(double value) {
    mouthOpen = value.clamp(0.0, 1.0);
  }

  @override
  void stopMotion({int? priority}) {
    lastMotionTag = null;
  }
}
