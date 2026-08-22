import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/animation_priority.dart';
import 'package:goods4ncu_mobile/companion/behavior_planner.dart';
import 'package:goods4ncu_mobile/companion/emotion_engine.dart';
import 'package:goods4ncu_mobile/companion/gaze.dart';
import 'package:goods4ncu_mobile/companion/motion_library.dart';

void main() {
  group('BehaviorPlanner', () {
    const planner = BehaviorPlanner();

    test('tool intents map to toolWorking at speech-gesture priority', () {
      final plan = planner.planForSignal(
        'tool_using_search_inventory',
        priority: AnimationPriority.speechGesture,
      );
      expect(plan.tag, MotionTag.toolWorking);
      expect(plan.loop, isTrue, reason: 'tools can take a while');
    });

    test('result UI actions point toward the list', () {
      expect(
        planner
            .planForSignal('SHOW_POSTS', priority: AnimationPriority.emotion)
            .tag,
        MotionTag.pointRight,
      );
    });

    test('state entries pick affect-appropriate tags', () {
      expect(
        planner
            .planForState('thinking', priority: AnimationPriority.emotion)
            .tag,
        MotionTag.thinking,
      );
      expect(
        planner.planForState('shy', priority: AnimationPriority.emotion).tag,
        MotionTag.shy,
      );
      // Interrupted always plays at interrupt priority regardless of input.
      final plan = planner.planForState(
        'interrupted',
        emotion: null,
        priority: AnimationPriority.emotion,
      );
      expect(plan.priority, AnimationPriority.interrupt);
    });

    test(
      'happy scales with arousal (§113 — energy reads as bigger gesture)',
      () {
        final calm = planner.planForState(
          'happy',
          emotion: const EmotionVector(arousal: 0.2),
          priority: AnimationPriority.emotion,
        );
        final hyped = planner.planForState(
          'happy',
          emotion: const EmotionVector(arousal: 0.8),
          priority: AnimationPriority.emotion,
        );
        expect(calm.tag, MotionTag.smallGreeting);
        expect(hyped.tag, MotionTag.veryHappy);
      },
    );

    test('unknown signals degrade to no-op plan', () {
      final plan = planner.planForSignal(
        'totally_unknown',
        priority: AnimationPriority.emotion,
      );
      expect(plan.steps, isEmpty);
    });
  });

  group('GazeSmoother', () {
    test('approaches target exponentially without overshoot', () {
      final gaze = GazeSmoother();
      gaze.setTarget(1, -1);

      var previous = 0.0;
      var monotonic = true;
      for (var i = 0; i < 60; i++) {
        gaze.tick(const Duration(milliseconds: 16));
        if (gaze.x < previous - 1e-9) monotonic = false;
        previous = gaze.x;
      }

      expect(gaze.x, closeTo(1, 0.01));
      expect(gaze.y, closeTo(-1, 0.01));
      expect(monotonic, isTrue, reason: 'no jitter/overshoot on the way there');
    });

    test('settles exactly and reports settled', () {
      final gaze = GazeSmoother();
      gaze.setTarget(-0.7, 0.3);
      for (var i = 0; i < 200; i++) {
        gaze.tick(const Duration(milliseconds: 16));
      }
      expect(gaze.settled, isTrue);
    });
  });

  group('idle tiers', () {
    test('thresholds match §32–35', () {
      expect(idleTierFor(Duration.zero), IdleTier.micro);
      expect(idleTierFor(const Duration(seconds: 10)), IdleTier.micro);
      expect(idleTierFor(const Duration(seconds: 45)), IdleTier.shortIdle);
      expect(idleTierFor(const Duration(seconds: 90)), IdleTier.shortIdle);
      expect(idleTierFor(const Duration(minutes: 3)), IdleTier.longIdle);
    });
  });
}
