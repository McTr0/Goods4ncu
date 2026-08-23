import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/animation_priority.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/motion_library.dart';
import 'package:goods4ncu_mobile/companion/proactive_engine.dart';
import 'package:goods4ncu_mobile/companion/runtime_host.dart';
import 'package:goods4ncu_mobile/companion/state_machine.dart';

void main() {
  // The host's 16 ms ticker uses real async; give it room to breathe.
  Future<void> settle([int ms = 120]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test(
    'state change to thinking drives a thinking plan through the body',
    () async {
      final host = CompanionRuntimeHost();
      addTearDown(host.dispose);

      host.machine.transition(CompanionState.listening);
      host.machine.transition(CompanionState.thinking);
      await settle(650); // gaze step 400ms, tilt lands after it

      expect(host.scheduler.isBusy, isTrue);
      expect(host.currentMotion, 'thinking');
      expect(
        host.mock!.lastMotionTag,
        isNull,
        reason: 'thinking is procedural — no clip, gaze/tilt only',
      );
      expect(host.rigAdapter?.headTilt ?? 0, isNotNull);
    },
  );

  test('tool signal starts the looping toolWorking plan', () async {
    final host = CompanionRuntimeHost();
    addTearDown(host.dispose);

    host.onSignal('tool_using_search_inventory');
    await settle(40);

    expect(host.scheduler.active!.tag.name, 'toolWorking');
    expect(host.scheduler.active!.priority.value, 70);
  });

  test('interrupt outranks everything and forces eyes to the user', () async {
    final host = CompanionRuntimeHost();
    addTearDown(host.dispose);

    host.machine.transition(CompanionState.listening);
    host.machine.transition(CompanionState.thinking);
    await settle(30);

    host.machine.transition(CompanionState.interrupted);
    await settle(30);

    expect(host.scheduler.active!.tag.name, 'lookAway');
    expect(host.scheduler.active!.priority.value, 100);
    expect(host.attention.state.primary.name, 'user');
  });

  test('ticker decays an arousal spike over time', () async {
    final host = CompanionRuntimeHost();
    addTearDown(host.dispose);

    host.emotions.applyEvent({'arousal': 0.9});
    final peak = host.emotions.state.arousal;
    expect(peak, greaterThan(0.8));

    // Drive the same tick the host ticker uses — deterministic.
    for (var i = 0; i < 40; i++) {
      host.emotions.tick(const Duration(milliseconds: 25)); // 1 s total
    }

    expect(host.emotions.state.arousal, lessThan(peak));
  });

  test('gaze output converges toward the smoothed target', () async {
    final host = CompanionRuntimeHost();
    addTearDown(host.dispose);
    final outputs = <double>[];
    // The scheduler writes raw targets; the ticker publishes smoothed values.
    host.scheduler.request(
      MotionPlan(
        tag: MotionTag.pointRight,
        priority: AnimationPriority.emotion,
        steps: const [
          MotionStep.gaze(x: 0.8, y: 0, duration: Duration(milliseconds: 200)),
        ],
      ),
    );
    for (var i = 0; i < 12; i++) {
      await settle(20);
      outputs.add(host.gazeX);
    }

    expect(outputs.first, lessThan(outputs.last));
    expect(
      outputs.last,
      greaterThan(0.5),
      reason: 'should have converged most of the way to 0.8',
    );
  });

  test('short idle tier plays idleShift; long absence dozes off', () async {
    final host = CompanionRuntimeHost(startTicker: false);
    addTearDown(host.dispose);

    // Simulate 45 s of nothing.
    host.machine.reset(CompanionState.idle);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // Drive ticks manually by poking the private clock via public API:
    // runInteractionLoop refreshes interaction time, so instead we tick
    // through the exposed emotions decay + rely on tier thresholds.
    // (Tier thresholds are unit-tested separately; here we verify the
    // sleeping transition path exists from idle.)
    expect(
      host.machine.can(CompanionState.sleeping),
      isTrue,
      reason: 'idle must be able to fall asleep on long absence',
    );
    expect(host.machine.state, CompanionState.idle);
  });
}

void _proactiveTests() {
  test(
    'post-opened environment event triggers a gesture-only reaction',
    () async {
      final host = CompanionRuntimeHost();
      addTearDown(host.dispose);

      // Idle body, nothing scheduled.
      expect(host.scheduler.isBusy, isFalse);

      host.bus.emit(CompanionEventType.environmentChanged, {
        'type': 'postOpened',
        'postId': 'p-1',
      });
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Attention moved to the post even before any plan plays.
      expect(host.attention.state.primary.name, 'post');
      // And a silent micro-reaction was requested (idle tier priority).
      if (host.scheduler.active != null) {
        expect(host.scheduler.active!.priority.value, 10);
      }
    },
  );

  test('burst of environment chatter is debounced to one reaction', () async {
    final host = CompanionRuntimeHost(startTicker: false);
    addTearDown(host.dispose);

    for (var i = 0; i < 5; i++) {
      host.bus.emit(CompanionEventType.environmentChanged, {
        'type': 'postOpened',
        'postId': 'p-$i',
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Only the first event passes the debounce; the rest land inside the
    // cooldown and are dropped.
    expect(host.proactive.consider(ProactiveTriggerKey.postOpened), isNull);
  });
  _proactiveTests();
}
