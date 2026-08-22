import 'attention.dart';
import 'motion_library.dart';

/// How loudly the companion may react to an event (goal §38).
enum ProactiveLevel {
  /// Body language only — gaze/motion, never a word.
  gestureOnly(0),

  /// A subtle "hm?" — micro motion plus expression.
  microReaction(1),

  /// One short remark. Rare by design.
  briefComment(2),

  /// A full proactive suggestion. Only when clearly useful.
  suggestion(3);

  const ProactiveLevel(this.value);
  final int value;
}

class ProactiveTriggerKey {
  static const postOpened = 'post_opened';
  static const searchResults = 'search_results';
  static const messageReceived = 'message_received';
  static const toolCompleted = 'tool_completed';
}

class ProactiveDecision {
  const ProactiveDecision({
    required this.level,
    required this.tag,
    required this.trigger,
    this.reason,
  });

  final ProactiveLevel level;

  /// Motion tag the director should play for the reaction.
  final MotionTag tag;
  final String trigger;
  final String? reason;
}

/// Per-trigger tuning: cooldown and the loudest level it may reach.
class TriggerPolicy {
  const TriggerPolicy({
    required this.cooldown,
    this.maxLevel = ProactiveLevel.gestureOnly,
  });

  final Duration cooldown;
  final ProactiveLevel maxLevel;
}

/// Decides *whether* to react — never what to say (goal §36–39).
///
/// Deterministic: same event history ⇒ same decisions. Speech-grade reactions
/// (level ≥ 2) additionally respect a global spoken-cooldown so the companion
/// stays present without being chatty.
class ProactiveEngine {
  ProactiveEngine({
    this.globalSpokenCooldown = const Duration(seconds: 90),
    Map<String, TriggerPolicy>? policies,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _policies =
        policies ??
        {
          ProactiveTriggerKey.postOpened: const TriggerPolicy(
            cooldown: Duration(seconds: 45),
            maxLevel: ProactiveLevel.microReaction,
          ),
          ProactiveTriggerKey.searchResults: const TriggerPolicy(
            cooldown: Duration(seconds: 30),
            maxLevel: ProactiveLevel.microReaction,
          ),
          ProactiveTriggerKey.messageReceived: const TriggerPolicy(
            cooldown: Duration(seconds: 60),
            maxLevel: ProactiveLevel.briefComment,
          ),
          ProactiveTriggerKey.toolCompleted: const TriggerPolicy(
            cooldown: Duration(seconds: 20),
            maxLevel: ProactiveLevel.gestureOnly,
          ),
        };
  }

  final Duration globalSpokenCooldown;
  late final Map<String, TriggerPolicy> _policies;
  final DateTime Function() _now;

  final Map<String, DateTime> _lastFired = {};
  DateTime? _lastSpokenAt;

  /// Desired body-language target for a trigger, independent of cooldowns —
  /// attention may always move even when speech is suppressed (§100).
  AttentionTarget gazeTargetFor(String trigger) => switch (trigger) {
    ProactiveTriggerKey.searchResults ||
    ProactiveTriggerKey.toolCompleted => AttentionTarget.postList,
    ProactiveTriggerKey.postOpened => AttentionTarget.post,
    ProactiveTriggerKey.messageReceived => AttentionTarget.notification,
    _ => AttentionTarget.none,
  };

  /// Consider reacting. Returns null when suppressed by cooldown or policy.
  ProactiveDecision? consider(
    String trigger, {
    ProactiveLevel requested = ProactiveLevel.microReaction,
    bool userIsBusy = false,
  }) {
    final policy = _policies[trigger];
    if (policy == null) return null;
    // When the user is mid-task, only silent gestures are allowed.
    final ceiling = userIsBusy ? ProactiveLevel.gestureOnly : policy.maxLevel;
    final level = requested.value <= ceiling.value ? requested : ceiling;
    final now = _now();

    final last = _lastFired[trigger];
    if (last != null && now.difference(last) < policy.cooldown) return null;
    if (level.value >= ProactiveLevel.briefComment.value &&
        _lastSpokenAt != null &&
        now.difference(_lastSpokenAt!) < globalSpokenCooldown) {
      // Speak-grade reaction suppressed → degrade to a micro reaction.
      return ProactiveDecision(
        level: ProactiveLevel.microReaction,
        tag: MotionTag.idleShift,
        trigger: trigger,
        reason: 'spoken_cooldown',
      );
    }

    _lastFired[trigger] = now;
    if (level.value >= ProactiveLevel.briefComment.value) {
      _lastSpokenAt = now;
    }
    final tag = switch (level) {
      ProactiveLevel.gestureOnly ||
      ProactiveLevel.microReaction => MotionTag.idleShift,
      ProactiveLevel.briefComment => MotionTag.thinking,
      ProactiveLevel.suggestion => MotionTag.pointRight,
    };
    return ProactiveDecision(level: level, tag: tag, trigger: trigger);
  }
}
