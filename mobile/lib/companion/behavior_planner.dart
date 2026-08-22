import 'animation_priority.dart';
import 'emotion_engine.dart';
import 'motion_library.dart';

/// Translates *why* the character should move into *what* it plays (§26).
///
/// Inputs are semantic — machine intents, tool names, emotion vector — never
/// motion files. Output is a [MotionPlan] the scheduler can arbitrate.
class BehaviorPlanner {
  const BehaviorPlanner();

  /// Plans a reaction to a character-state entry.
  MotionPlan planForState(
    String stateName, {
    EmotionVector? emotion,
    required AnimationPriority priority,
  }) {
    switch (stateName) {
      case 'listening':
        return planForTag(MotionTag.smallGreeting, priority);
      case 'thinking':
        return planForTag(MotionTag.thinking, priority);
      case 'toolUsing':
        return planForTag(MotionTag.toolWorking, priority);
      case 'speaking':
      case 'idle':
        break;
      case 'surprised':
        return planForTag(MotionTag.surprised, priority);
      case 'confused':
        return planForTag(MotionTag.confused, priority);
      case 'shy':
        return planForTag(MotionTag.shy, priority);
      case 'happy':
        return _byArousal(emotion, priority);
      case 'excited':
        return planForTag(MotionTag.veryHappy, priority);
      case 'bored':
        return planForTag(MotionTag.stretch, priority);
      case 'interrupted':
        return planForTag(MotionTag.lookAway, AnimationPriority.interrupt);
    }
    return MotionPlan.none;
  }

  /// Plans a reaction to an agent/tool signal (tool name, ui action…).
  MotionPlan planForSignal(
    String signal, {
    required AnimationPriority priority,
  }) {
    switch (signal) {
      case 'tool_using_search_inventory':
      case 'tool_using_find_related_posts':
      case 'tool_using_get_user_posts':
        return planForTag(MotionTag.toolWorking, priority);
      case 'SHOW_POSTS':
      case 'SHOW_RELATED_POSTS':
        return planForTag(MotionTag.pointRight, priority);
      case 'HIGHLIGHT_POST':
      case 'SCROLL_TO_POST':
        return planForTag(MotionTag.pointRight, priority);
      case 'OPEN_MESSAGE_DRAFT':
      case 'OPEN_COMMENT_DRAFT':
        return planForTag(MotionTag.acknowledge, priority);
      case 'greet_user':
        return planForTag(MotionTag.greeting, priority);
      case 'no_results':
        return planForTag(MotionTag.disagree, priority);
      case 'nod':
        return planForTag(MotionTag.agree, priority);
      default:
        return MotionPlan.none;
    }
  }

  /// Excited characters gesture bigger; calm ones stay subtle.
  MotionPlan _byArousal(EmotionVector? emotion, AnimationPriority priority) {
    final arousal = emotion?.arousal ?? 0.2;
    if (arousal > 0.65) return planForTag(MotionTag.veryHappy, priority);
    if (arousal > 0.35) return planForTag(MotionTag.happy, priority);
    return planForTag(MotionTag.smallGreeting, priority);
  }
}
