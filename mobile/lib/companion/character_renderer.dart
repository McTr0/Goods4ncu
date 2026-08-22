import 'package:flutter/foundation.dart';

import 'attention.dart';
import 'companion_events.dart';
import 'emotion_engine.dart';
import 'state_machine.dart';

/// What the character's body can be told to do (master goal §71).
///
/// Everything above this line (director, planner, scheduler) speaks in
/// *semantics* — everything below renders. Swapping the OpenRig body for a
/// Cubism model, or any of it for the mock, must never touch runtime logic.
abstract class CharacterRenderer {
  Future<void> load();

  void setCharacterState(CompanionState state);

  void setExpression(String expression, {double weight = 1});

  /// Semantic motion tag (e.g. `greeting`, `thinking`), not an asset path.
  Future<void> playMotion(
    String motionTag, {
    int priority = 60,
    Duration? holdFor,
  });

  void setGaze(double x, double y);

  void setMouthOpen(double value);

  /// Raw parameter pass-through for body-specific knobs (e.g. `headTilt`).
  void setParameter(String name, double value);

  void stopMotion({int? priority});
}

/// Runtime snapshot consumed by the debug console and the mock renderer.
class CompanionRuntimeSnapshot {
  const CompanionRuntimeSnapshot({
    required this.state,
    required this.emotion,
    required this.attention,
    this.currentMotion,
    this.mouthOpen = 0,
  });

  final CompanionState state;
  final EmotionVector emotion;
  final AttentionState attention;
  final String? currentMotion;
  final double mouthOpen;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'emotion': emotion.toMap(),
    'attention': attention.toDebugMap(),
    if (currentMotion != null) 'motion': currentMotion,
    'mouth': mouthOpen,
  };
}

/// ChangeNotifier façade bundling the runtime pieces renderers consume.
class CompanionRuntime extends ChangeNotifier {
  CompanionRuntime({
    required this.bus,
    required this.machine,
    required this.emotions,
    required this.attention,
  }) {
    // Keep the snapshot fresh: any of the three sub-systems mutating should
    // refresh consumers.
    bus.stream.listen((event) {
      switch (event.type) {
        case CompanionEventType.characterStateChanged:
        case CompanionEventType.emotionChanged:
        case CompanionEventType.attentionChanged:
        case CompanionEventType.motionStarted:
        case CompanionEventType.motionFinished:
          notifyListeners();
        default:
          break;
      }
    });
  }

  final CompanionEventBus bus;
  final CompanionStateMachine machine;
  final EmotionEngine emotions;
  final AttentionController attention;

  String? currentMotion;
  double mouthOpen = 0;

  CompanionRuntimeSnapshot snapshot() => CompanionRuntimeSnapshot(
    state: machine.state,
    emotion: emotions.state,
    attention: attention.state,
    currentMotion: currentMotion,
    mouthOpen: mouthOpen,
  );
}
