import 'dart:async';

import 'animation_priority.dart';
import 'companion_events.dart';
import 'motion_library.dart';

class ActivePlan {
  const ActivePlan({
    required this.tag,
    required this.priority,
    required this.startedAt,
  });

  final MotionTag tag;
  final AnimationPriority priority;
  final DateTime startedAt;
}

/// Arbitrates every animation the character plays (master goal §29–30).
///
/// Contract:
///  * A request of strictly higher priority instantly preempts whatever is
///    running — its first step is applied synchronously, so visual response
///    needs no timer tick.
///  * Equal or lower priority requests are rejected while busy.
///  * A cancelled plan's pending steps are discarded via a generation token,
///    so a stale `Future.delayed` can never resurrect an old gesture.
class AnimationScheduler {
  AnimationScheduler({
    required CompanionEventBus bus,
    this.onPlayClip,
    this.onGaze,
    this.onHeadTilt,
    this.onRelease,
  }) : _bus = bus;

  final CompanionEventBus _bus;

  /// Adapter hooks — wired to the real body (legacy sprite body) or the mock renderer.
  final void Function(String clip)? onPlayClip;
  final void Function(double x, double y)? onGaze;
  final void Function(double degrees)? onHeadTilt;

  /// Called when nothing is playing anymore; the idle director listens here.
  final void Function()? onRelease;

  ActivePlan? _active;
  int _generation = 0;

  ActivePlan? get active => _active;

  bool get isBusy => _active != null;

  /// Attempts to play [plan]. Returns false when rejected by arbitration.
  ///
  /// [preemptEqual] lets sequential owners of the same priority level
  /// (e.g. successive character states) replace each other instead of
  /// being silently dropped.
  bool request(MotionPlan plan, {bool preemptEqual = false}) {
    final current = _active;
    if (current != null) {
      final outranks = plan.priority.outranks(current.priority);
      if (!outranks && !(preemptEqual && plan.priority == current.priority)) {
        return false;
      }
    }
    _start(plan);
    return true;
  }

  /// Cancels whatever is running regardless of priority.
  void cancel({String reason = 'cancelled'}) {
    if (_active == null) return;
    _stop(reason);
  }

  void _start(MotionPlan plan) {
    _stop('preempted');
    final generation = ++_generation;
    _active = ActivePlan(
      tag: plan.tag,
      priority: plan.priority,
      startedAt: DateTime.now(),
    );
    _bus.emit(CompanionEventType.motionStarted, {
      'tag': plan.tag.name,
      'priority': plan.priority.value,
    });
    // Fire-and-forget: cancellation is handled by the generation token.
    unawaited(_run(plan, generation));
  }

  Future<void> _run(MotionPlan plan, int generation) async {
    do {
      for (final step in plan.steps) {
        if (generation != _generation) return; // preempted/cancelled mid-flight
        _applyStep(step);
        await Future<void>.delayed(step.duration);
      }
    } while (plan.loop && generation == _generation);
    if (generation == _generation) _stop('finished');
  }

  void _applyStep(MotionStep step) {
    if (step.clip != null) {
      onPlayClip?.call(step.clip!);
    } else if (step.gazeX != null || step.gazeY != null) {
      onGaze?.call(step.gazeX ?? gazeHoldX, step.gazeY ?? gazeHoldY);
      gazeHoldX = step.gazeX ?? gazeHoldX;
      gazeHoldY = step.gazeY ?? gazeHoldY;
    } else if (step.headTilt != null) {
      onHeadTilt?.call(step.headTilt!);
    }
  }

  /// Last commanded gaze, so partial gaze steps compose naturally.
  double gazeHoldX = 0;
  double gazeHoldY = 0;

  void _stop(String reason) {
    final finished = _active;
    _generation++; // invalidate any in-flight loop
    _active = null;
    if (finished != null) {
      _bus.emit(CompanionEventType.motionFinished, {
        'tag': finished.tag.name,
        'reason': reason,
      });
      onRelease?.call();
    }
  }

  Future<void> dispose() async {
    _stop('disposed');
  }
}
