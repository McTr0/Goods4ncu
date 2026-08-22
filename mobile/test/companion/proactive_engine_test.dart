import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/attention.dart';
import 'package:goods4ncu_mobile/companion/motion_library.dart';
import 'package:goods4ncu_mobile/companion/proactive_engine.dart';

void main() {
  late DateTime now;
  late ProactiveEngine engine;

  setUp(() {
    now = DateTime(2026, 8, 22, 12);
    engine = ProactiveEngine(now: () => now);
  });

  test('first post-open reacts at micro level and looks at the post', () {
    final decision = engine.consider(ProactiveTriggerKey.postOpened);

    expect(decision, isNotNull);
    expect(decision!.level, ProactiveLevel.microReaction);
    // §100: an opened post draws the eyes to the post itself.
    expect(
      engine.gazeTargetFor(ProactiveTriggerKey.postOpened),
      AttentionTarget.post,
    );
  });

  test('cooldown suppresses repeat reactions for the same trigger', () {
    expect(engine.consider(ProactiveTriggerKey.postOpened), isNotNull);

    // 10 s later — inside the 45 s cooldown.
    now = now.add(const Duration(seconds: 10));
    expect(engine.consider(ProactiveTriggerKey.postOpened), isNull);

    // After the cooldown it fires again.
    now = now.add(const Duration(seconds: 40));
    expect(engine.consider(ProactiveTriggerKey.postOpened), isNotNull);
  });

  test('busy user is capped at gesture-only even for big triggers', () {
    final decision = engine.consider(
      ProactiveTriggerKey.messageReceived,
      requested: ProactiveLevel.briefComment,
      userIsBusy: true,
    );

    expect(
      decision!.level,
      ProactiveLevel.gestureOnly,
      reason: 'never interrupt a focused user with speech',
    );
  });

  test('spoken cooldown degrades a comment into a silent micro reaction', () {
    // First message reaction speaks (briefComment allowed).
    final first = engine.consider(
      ProactiveTriggerKey.messageReceived,
      requested: ProactiveLevel.briefComment,
    );
    expect(first!.level, ProactiveLevel.briefComment);

    // 70 s later the trigger cooldown has passed but the global spoken
    // cooldown (90 s) is still active — degrade instead of staying silent.
    now = now.add(const Duration(seconds: 70));
    final second = engine.consider(
      ProactiveTriggerKey.messageReceived,
      requested: ProactiveLevel.briefComment,
    );
    expect(second!.level, ProactiveLevel.microReaction);
    expect(second.reason, 'spoken_cooldown');
    expect(second.tag, MotionTag.idleShift);
  });

  test('different triggers have independent cooldowns', () {
    expect(engine.consider(ProactiveTriggerKey.searchResults), isNotNull);
    expect(
      engine.consider(ProactiveTriggerKey.toolCompleted),
      isNotNull,
      reason: 'search firing must not block tool completion reactions',
    );
  });

  test('unknown trigger yields null', () {
    expect(engine.consider('nonsense'), isNull);
  });
}
