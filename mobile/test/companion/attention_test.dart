import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/attention.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';

void main() {
  late CompanionEventBus bus;
  late AttentionController controller;

  setUp(() {
    bus = CompanionEventBus();
    controller = AttentionController(bus: bus);
  });

  tearDown(() {
    controller.dispose();
    bus.dispose();
  });

  test('starts on the user and emits attentionChanged on moves', () async {
    final seen = <CompanionEventType>[];
    bus.stream.listen((e) => seen.add(e.type));

    controller.lookAt(AttentionTarget.postList);

    expect(controller.state.primary, AttentionTarget.postList);
    await Future<void>.delayed(Duration.zero);
    expect(seen, contains(CompanionEventType.attentionChanged));
  });

  test('locked target cannot be stolen by weaker stimuli', () {
    controller.lookAt(
      AttentionTarget.chat,
      lockFor: const Duration(seconds: 5),
    );
    expect(controller.state.isLocked, isTrue);

    // A passing post-list event must not steal focus mid-lock.
    controller.lookAt(AttentionTarget.postList);

    expect(controller.state.primary, AttentionTarget.chat);
  });

  test('focusUser overrides any lock (barge-in contract)', () {
    controller.lookAt(
      AttentionTarget.postList,
      lockFor: const Duration(seconds: 30),
    );

    controller.focusUser();

    expect(controller.state.primary, AttentionTarget.user);
    expect(controller.state.isLocked, isTrue);
  });

  test('lock expires naturally', () async {
    controller.lookAt(
      AttentionTarget.postList,
      lockFor: const Duration(milliseconds: 20),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(controller.state.isLocked, isFalse);
    controller.lookAt(AttentionTarget.notification);
    expect(controller.state.primary, AttentionTarget.notification);
  });

  test('no duplicate emissions for the same target', () async {
    var changes = 0;
    bus.on(CompanionEventType.attentionChanged, (_) => changes++);

    controller.lookAt(AttentionTarget.post);
    controller.lookAt(AttentionTarget.post);
    await Future<void>.delayed(Duration.zero);

    expect(changes, 1);
  });
}
