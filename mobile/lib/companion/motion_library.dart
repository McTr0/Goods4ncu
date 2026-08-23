import 'dart:math';

import 'animation_priority.dart';

/// Semantic motion tags (master goal §27). Bodies map these to real clips;
/// runtime logic only ever speaks in tags.
enum MotionTag {
  greeting,
  smallGreeting,
  happy,
  veryHappy,
  thinking,
  confused,
  surprised,
  shy,
  agree,
  disagree,
  pointLeft,
  pointRight,
  lookAway,
  stretch,
  idleShift,
  toolWorking,
  acknowledge,
}

/// One executable beat of a [MotionPlan].
///
/// A step is either a body-clip playback (`clip`), or a *procedural* gesture —
/// gaze shifts / head tilts the adapter can synthesise without any asset.
class MotionStep {
  const MotionStep.clip(
    this.clip, {
    this.duration = const Duration(milliseconds: 900),
  }) : gazeX = null,
       gazeY = null,
       headTilt = null;

  const MotionStep.gaze({
    double? x,
    double? y,
    this.duration = const Duration(milliseconds: 400),
  }) : clip = null,
       gazeX = x,
       gazeY = y,
       headTilt = null;

  const MotionStep.headTilt({
    required double degrees,
    this.duration = const Duration(milliseconds: 500),
  }) : clip = null,
       gazeX = null,
       gazeY = null,
       headTilt = degrees;

  const MotionStep.hold(this.duration)
    : clip = null,
      gazeX = null,
      gazeY = null,
      headTilt = null;

  final String? clip;
  final double? gazeX;
  final double? gazeY;
  final double? headTilt;
  final Duration duration;
}

/// A scheduled sequence of steps played at one priority level.
class MotionPlan {
  const MotionPlan({
    required this.tag,
    required this.priority,
    required this.steps,
    this.loop = false,
  });

  final MotionTag tag;
  final AnimationPriority priority;
  final List<MotionStep> steps;

  /// Idle plans loop until cancelled.
  final bool loop;

  static const MotionPlan none = MotionPlan(
    tag: MotionTag.idleShift,
    priority: AnimationPriority.idle,
    steps: [],
  );
}

/// Built-in mapping from semantic tags to concrete steps for the current
/// legacy sprite body body (8 clips + procedural gestures).
///
/// Replacing the body later means swapping THIS table (or loading it from an
/// asset) — nothing above the library may reference clip names directly (§28).
MotionPlan planForTag(MotionTag tag, AnimationPriority priority) {
  switch (tag) {
    case MotionTag.greeting:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.clip('wave')],
      );
    case MotionTag.smallGreeting:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.gaze(x: 0, y: -0.1),
          MotionStep.clip('acknowledge', duration: Duration(milliseconds: 600)),
        ],
      );
    case MotionTag.happy:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.clip('encourage')],
      );
    case MotionTag.veryHappy:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.clip('high_five')],
      );
    case MotionTag.thinking:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.gaze(x: 0.35, y: 0.1),
          MotionStep.headTilt(degrees: 6),
          MotionStep.hold(Duration(milliseconds: 700)),
        ],
      );
    case MotionTag.confused:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.headTilt(degrees: -10),
          MotionStep.hold(Duration(milliseconds: 500)),
        ],
      );
    case MotionTag.surprised:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.gaze(x: 0, y: 0.15),
          MotionStep.hold(Duration(milliseconds: 300)),
        ],
      );
    case MotionTag.shy:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.gaze(x: -0.3, y: 0.2),
          MotionStep.hold(Duration(milliseconds: 800)),
        ],
      );
    case MotionTag.agree:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.clip('acknowledge', duration: Duration(milliseconds: 550)),
        ],
      );
    case MotionTag.disagree:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.headTilt(degrees: -8),
          MotionStep.headTilt(degrees: 8),
        ],
      );
    case MotionTag.pointLeft:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.gaze(x: -0.55, y: 0)],
      );
    case MotionTag.pointRight:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.gaze(x: 0.55, y: 0)],
      );
    case MotionTag.lookAway:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [MotionStep.gaze(x: -0.4, y: 0.25)],
      );
    case MotionTag.stretch:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.clip('poke', duration: Duration(milliseconds: 1200)),
          MotionStep.hold(Duration(milliseconds: 300)),
        ],
      );
    case MotionTag.idleShift:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.gaze(x: 0.2, y: 0.05),
          MotionStep.hold(Duration(milliseconds: 900)),
          MotionStep.gaze(x: -0.15, y: -0.05),
        ],
      );
    case MotionTag.toolWorking:
      return MotionPlan(
        tag: tag,
        priority: priority,
        loop: true,
        steps: const [
          MotionStep.gaze(x: 0.45, y: 0),
          MotionStep.hold(Duration(milliseconds: 1200)),
          MotionStep.headTilt(degrees: 4),
        ],
      );
    case MotionTag.acknowledge:
      return MotionPlan(
        tag: tag,
        priority: priority,
        steps: const [
          MotionStep.clip('acknowledge', duration: Duration(milliseconds: 600)),
        ],
      );
  }
}

/// Deterministic RNG helper for idle variation in tests.
MotionStep randomIdleShift(Random rng) => MotionStep.gaze(
  x: (rng.nextDouble() * 2 - 1) * 0.5,
  y: (rng.nextDouble() * 2 - 1) * 0.2,
  duration: Duration(milliseconds: 600 + rng.nextInt(800)),
);
