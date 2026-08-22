import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/animation_priority.dart';
import 'package:goods4ncu_mobile/companion/animation_scheduler.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/motion_library.dart';

MotionPlan _plan(
  MotionTag tag,
  AnimationPriority priority, {
  bool loop = false,
  List<MotionStep>? steps,
}) => MotionPlan(
  tag: tag,
  priority: priority,
  steps:
      steps ??
      const [
        MotionStep.clip('wave', duration: Duration(milliseconds: 20)),
        MotionStep.gaze(x: 0.4, y: 0.1, duration: Duration(milliseconds: 20)),
      ],
  loop: loop,
);

void main() {
  late CompanionEventBus bus;
  late AnimationScheduler scheduler;
  final clips = <String>[];
  final gazes = <(double, double)>[];

  setUp(() {
    bus = CompanionEventBus();
    clips.clear();
    gazes.clear();
    scheduler = AnimationScheduler(
      bus: bus,
      onPlayClip: clips.add,
      onGaze: (x, y) => gazes.add((x, y)),
    );
  });

  tearDown(() => scheduler.dispose());

  test('idle request plays and finishes, releasing the scheduler', () async {
    expect(
      scheduler.request(_plan(MotionTag.agree, AnimationPriority.emotion)),
      isTrue,
    );
    expect(scheduler.isBusy, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(scheduler.isBusy, isFalse);
    expect(clips, contains('wave'));
  });

  test('lower or equal priority is rejected while busy', () async {
    scheduler.request(
      _plan(MotionTag.thinking, AnimationPriority.speechGesture),
    );
    final before = clips.length;

    expect(
      scheduler.request(_plan(MotionTag.idleShift, AnimationPriority.idle)),
      isFalse,
    );
    expect(
      scheduler.request(
        _plan(MotionTag.agree, AnimationPriority.speechGesture),
      ),
      isFalse,
      reason: 'equal priority does not preempt',
    );
    expect(clips.length, before);
  });

  test(
    'higher priority preempts instantly with its first step applied',
    () async {
      // Long-running low-priority stretch.
      scheduler.request(
        _plan(
          MotionTag.stretch,
          AnimationPriority.idle,
          steps: [
            const MotionStep.clip('poke', duration: Duration(seconds: 5)),
            const MotionStep.clip('wave', duration: Duration(milliseconds: 10)),
          ],
        ),
      );

      final ok = scheduler.request(
        _plan(MotionTag.smallGreeting, AnimationPriority.userInteraction),
      );
      expect(ok, isTrue);

      // First step of the new plan applied synchronously — no timer tick.
      expect(scheduler.active!.tag, MotionTag.smallGreeting);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(scheduler.isBusy, isFalse);
    },
  );

  test('cancelled looping plan stops stepping (generation guard)', () async {
    var gazeCount = 0;
    gazes.clear();
    scheduler.request(
      _plan(
        MotionTag.toolWorking,
        AnimationPriority.emotion,
        loop: true,
        steps: [
          MotionStep.gaze(x: 0.5, y: 0, duration: Duration(milliseconds: 15)),
          MotionStep.headTilt(degrees: 4, duration: Duration(milliseconds: 15)),
        ],
      ),
    );
    void count() => gazeCount = gazes.length;
    count();

    await Future<void>.delayed(const Duration(milliseconds: 60));
    scheduler.cancel(reason: 'user spoke');
    final frozen = gazes.length;

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(gazes.length, frozen);
    expect(gazeCount, greaterThanOrEqualTo(1));
    expect(scheduler.isBusy, isFalse);
  });

  test('emits motionStarted then motionFinished with reasons', () async {
    final events = <CompanionEvent>[];
    bus.stream.listen(events.add);

    scheduler.request(_plan(MotionTag.agree, AnimationPriority.emotion));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(
      events.whereType<CompanionEvent>().map((e) => e.type).toList(),
      containsAllInOrder([
        CompanionEventType.motionStarted,
        CompanionEventType.motionFinished,
      ]),
    );
    final finished = events.firstWhere(
      (e) => e.type == CompanionEventType.motionFinished,
    );
    expect(finished.data['reason'], 'finished');
  });

  test('partial gaze steps compose from the last commanded position', () async {
    scheduler.request(
      _plan(
        MotionTag.pointRight,
        AnimationPriority.emotion,
        steps: [
          const MotionStep.gaze(
            x: 0.6,
            y: 0,
            duration: Duration(milliseconds: 15),
          ),
          // Only y provided — x must hold at 0.6.
          const MotionStep.gaze(
            x: null,
            y: -0.2,
            duration: Duration(milliseconds: 15),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(gazes.last, (0.6, -0.2));
  });
}
